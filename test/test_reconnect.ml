open A2a_client
open Test_client

let ev req j = Mock.sse_data (Mock.result_envelope ~id:(Mock.request_id req) j)
let task req state = ev req (`Assoc [ ("task", task_json "t-1" state) ])

let status req state =
  ev req
    (`Assoc
       [ ("statusUpdate",
           `Assoc
             [ ("taskId", `String "t-1"); ("contextId", `String "ctx-1");
               ("status", `Assoc [ ("state", `String ("TASK_STATE_" ^ state)) ]) ]) ])

let now clock = Mtime.to_uint64_ns (Eio.Time.Mono.now clock)
let seconds_since clock t0 = Int64.(to_float (sub (now clock) t0)) /. 1e9

let client ?(max_attempts = 3) ~clock transport =
  create ~clock ~transport ~reconnect:(Reconnect.make ~max_attempts ~delay:0.5 ()) endpoint

let methods (r : Mock.recorder) = List.rev_map meth r.requests

let test_resumes () =
  run @@ fun clock ->
  let transport, rec_ =
    Mock.transport ~clock (fun req ->
        match meth req with
        | "SendStreamingMessage" ->
            Mock.sse_reply [ Mock.Chunk ("id: 7\nretry: 2000\n" ^ task req "WORKING") ]
        | _ -> Mock.sse_reply [ Mock.Chunk (task req "WORKING"); Mock.Chunk (status req "COMPLETED") ])
  in
  let seen = ref [] in
  let t0 = now clock in
  (match
     send_streaming_message (client ~clock transport)
       ~on_event:(fun e -> seen := e :: !seen)
       (Message.user_text "go")
   with
   | Ok (Outcome.Completed t) -> Alcotest.(check string) "task" "t-1" t.id
   | Ok _ -> Alcotest.fail "expected Completed"
   | Error e -> Alcotest.fail (Error.to_string e));
  Alcotest.(check (list string)) "calls" [ "SendStreamingMessage"; "SubscribeToTask" ] (methods rec_);
  let resubscribe = List.hd rec_.requests in
  Alcotest.(check string) "same task" {|{"id":"t-1"}|} (Yojson.Safe.to_string (params resubscribe));
  Alcotest.(check (option string)) "Last-Event-ID" (Some "7") (header "last-event-id" resubscribe);
  Alcotest.(check int) "events" 3 (List.length !seen);
  Alcotest.(check bool) "honours the retry hint" true (seconds_since clock t0 >= 2.0)

let test_task_ended_meanwhile () =
  run @@ fun clock ->
  let subscribed = ref false in
  let transport, rec_ =
    Mock.transport ~clock (fun req ->
        match meth req with
        | "SubscribeToTask" when !subscribed ->
            Mock.json_reply (Mock.error_envelope ~id:(`String (Mock.request_id req)) (-32004) "terminal")
        | "GetTask" -> Mock.json_reply (Mock.result_envelope ~id:(Mock.request_id req) (task_json "t-1" "COMPLETED"))
        | _ ->
            subscribed := true;
            Mock.sse_reply [ Mock.Chunk (task req "WORKING") ])
  in
  let last = ref None in
  (match subscribe_to_task (client ~clock transport) ~on_event:(fun e -> last := Some e) "t-1" with
   | Ok (Outcome.Completed _) -> ()
   | _ -> Alcotest.fail "expected Completed");
  Alcotest.(check (list string)) "calls" [ "SubscribeToTask"; "SubscribeToTask"; "GetTask" ] (methods rec_);
  match !last with
  | Some (Stream_response.Task t) -> Alcotest.(check bool) "snapshot delivered" true (Task.is_terminal t)
  | _ -> Alcotest.fail "expected the fetched task as the last event"

let test_refused_while_active () =
  run @@ fun clock ->
  let transport, rec_ =
    Mock.transport ~clock (fun req ->
        match meth req with
        | "SendStreamingMessage" -> Mock.sse_reply [ Mock.Chunk (task req "WORKING") ]
        | "SubscribeToTask" ->
            Mock.json_reply (Mock.error_envelope ~id:(`String (Mock.request_id req)) (-32004) "no")
        | _ -> Mock.json_reply (Mock.result_envelope ~id:(Mock.request_id req) (task_json "t-1" "WORKING")))
  in
  send_streaming_message (client ~max_attempts:2 ~clock transport) (Message.user_text "go")
  |> expect_error "bounded" (function Error.Stream_ended _ -> true | _ -> false);
  Alcotest.(check (list string)) "calls"
    [ "SendStreamingMessage"; "SubscribeToTask"; "GetTask"; "GetTask" ]
    (methods rec_)

let test_gives_up () =
  run @@ fun clock ->
  let transport, rec_ =
    Mock.transport ~clock (fun req ->
        match meth req with
        | "SendStreamingMessage" -> Mock.sse_reply [ Mock.Chunk (task req "WORKING") ]
        | _ -> Mock.sse_reply [ Mock.Raise (Failure "reset") ])
  in
  let t0 = now clock in
  send_streaming_message (client ~max_attempts:2 ~clock transport) (Message.user_text "go")
  |> expect_error "exhausted" (function Error.Transport_error _ -> true | _ -> false);
  Alcotest.(check int) "1 + 2 attempts" 3 (List.length rec_.requests);
  Alcotest.(check (float 1e-6)) "backoff 0.5 then 1" 1.5 (seconds_since clock t0);
  Alcotest.(check int) "every connection released" 3 rec_.released

let test_productive_attempts_reset () =
  run @@ fun clock ->
  let calls = ref 0 in
  let transport, rec_ =
    Mock.transport ~clock (fun req ->
        incr calls;
        if !calls < 4 then Mock.sse_reply [ Mock.Chunk (task req "WORKING") ]
        else Mock.sse_reply [ Mock.Chunk (status req "COMPLETED") ])
  in
  (match send_streaming_message (client ~max_attempts:1 ~clock transport) (Message.user_text "go") with
   | Ok (Outcome.Completed _) -> ()
   | _ -> Alcotest.fail "expected Completed");
  Alcotest.(check int) "kept going while streams delivered events" 4 (List.length rec_.requests)

let test_not_resumed () =
  run @@ fun clock ->
  let transport, rec_ = Mock.transport ~clock (fun _ -> Mock.sse_reply []) in
  send_streaming_message (client ~clock transport) (Message.user_text "go")
  |> expect_error "no task yet" (function Error.Stream_ended { last_task = None } -> true | _ -> false);
  Alcotest.(check int) "no retry without a task" 1 (List.length rec_.requests);
  let transport, rec_ =
    Mock.transport ~clock (fun req ->
        match meth req with
        | "SendStreamingMessage" -> Mock.sse_reply [ Mock.Chunk (task req "WORKING") ]
        | _ -> Mock.json_reply (Mock.error_envelope ~id:(`String (Mock.request_id req)) (-32001) "gone"))
  in
  send_streaming_message (client ~clock transport) (Message.user_text "go")
  |> expect_error "agent error" (function
       | Error.Rpc_error { code = Task_not_found; _ } -> true
       | _ -> false);
  Alcotest.(check int) "agent errors end it" 2 (List.length rec_.requests);
  let transport, rec_ =
    Mock.transport ~clock (fun req -> Mock.sse_reply [ Mock.Chunk (task req "WORKING") ])
  in
  send_streaming_message (create ~clock ~transport endpoint) (Message.user_text "go")
  |> expect_error "default policy" (function Error.Stream_ended _ -> true | _ -> false);
  Alcotest.(check int) "off by default" 1 (List.length rec_.requests);
  match Reconnect.make ~backoff:0.5 () with
  | exception Invalid_argument _ -> ()
  | _ -> Alcotest.fail "expected Invalid_argument"

let tests =
  [ ("resumes with SubscribeToTask", `Quick, test_resumes);
    ("task ended while disconnected", `Quick, test_task_ended_meanwhile);
    ("refused while still active", `Quick, test_refused_while_active);
    ("gives up after max_attempts", `Quick, test_gives_up);
    ("productive attempts reset the count", `Quick, test_productive_attempts_reset);
    ("not resumed", `Quick, test_not_resumed) ]
