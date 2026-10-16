open A2a_client

let run f = Eio_mock.Backend.run_full (fun env -> f env#mono_clock)
let endpoint = Uri.of_string "http://agent.test/a2a"

let task_json ?(ctx = "ctx-1") ?(extra = []) id state : Yojson.Safe.t =
  `Assoc
    ([ ("id", `String id); ("contextId", `String ctx);
       ("status", `Assoc [ ("state", `String ("TASK_STATE_" ^ state)) ]) ]
    @ extra)

let agent_message_json ?(ctx = "ctx-1") text : Yojson.Safe.t =
  `Assoc
    [ ("messageId", `String "agent-msg"); ("contextId", `String ctx);
      ("role", `String "ROLE_AGENT"); ("parts", `List [ `Assoc [ ("text", `String text) ] ]) ]

let params req =
  match Mock.request_json req with
  | `Assoc kvs -> List.assoc "params" kvs
  | _ -> assert false

let meth req =
  match Mock.request_json req with
  | `Assoc kvs -> (match List.assoc "method" kvs with `String m -> m | _ -> assert false)
  | _ -> assert false

let member path (j : Yojson.Safe.t) =
  List.fold_left (fun j k -> match j with `Assoc kvs -> List.assoc k kvs | _ -> raise Not_found) j path

let header name (req : Transport.request) = Transport.header name req.headers

let expect_error name pred = function
  | Ok _ -> Alcotest.failf "%s: expected an error" name
  | Error e -> if not (pred e) then Alcotest.failf "%s: unexpected error %s" name (Error.to_string e)

let ok name = function
  | Ok v -> v
  | Error e -> Alcotest.failf "%s: %s" name (Error.to_string e)

let test_send_message_message () =
  run @@ fun clock ->
  let transport, rec_ =
    Mock.transport ~clock (fun req ->
        Mock.json_reply
          (Mock.result_envelope ~id:(Mock.request_id req)
             (`Assoc [ ("message", agent_message_json "Hello back") ])))
  in
  let client = create ~clock ~transport ~auth:(Auth.bearer "tok") ~tenant:"acme" endpoint in
  (match send_text client ~context_id:"ctx-9" "Hello" with
   | Ok (Send_message_response.Message m) -> Alcotest.(check string) "reply" "Hello back" (Message.text m)
   | Ok (Task _) -> Alcotest.fail "expected message"
   | Error e -> Alcotest.fail (Error.to_string e));
  let req = List.hd rec_.requests in
  Alcotest.(check bool) "POST" true (req.meth = `POST);
  Alcotest.(check string) "uri" "http://agent.test/a2a" (Uri.to_string req.uri);
  Alcotest.(check string) "method" "SendMessage" (meth req);
  Alcotest.(check (option string)) "A2A-Version" (Some "1.0") (header "a2a-version" req);
  Alcotest.(check (option string)) "auth" (Some "Bearer tok") (header "authorization" req);
  Alcotest.(check (option string)) "content-type" (Some "application/json") (header "content-type" req);
  let p = params req in
  Alcotest.(check bool) "tenant" true (member [ "tenant" ] p = `String "acme");
  Alcotest.(check bool) "role" true (member [ "message"; "role" ] p = `String "ROLE_USER");
  Alcotest.(check bool) "context" true (member [ "message"; "contextId" ] p = `String "ctx-9");
  Alcotest.(check bool) "text part" true
    (member [ "message"; "parts" ] p = `List [ `Assoc [ ("text", `String "Hello") ] ]);
  (match member [ "message"; "messageId" ] p with
   | `String id -> Alcotest.(check int) "uuid message id" 36 (String.length id)
   | _ -> Alcotest.fail "messageId");
  Alcotest.(check int) "connection released" 1 rec_.released

let test_send_message_task () =
  run @@ fun clock ->
  let transport, _ =
    Mock.transport ~clock (fun req ->
        Mock.json_reply
          (Mock.result_envelope ~id:(Mock.request_id req) (`Assoc [ ("task", task_json "t-1" "WORKING") ])))
  in
  let client = create ~clock ~transport endpoint in
  match send_text client "do work" with
  | Ok (Send_message_response.Task t) ->
      Alcotest.(check string) "task id" "t-1" t.id;
      Alcotest.(check (option string)) "context id kept" (Some "ctx-1") t.context_id;
      Alcotest.(check bool) "in progress" true
        (match Outcome.of_task t with Outcome.In_progress _ -> true | _ -> false);
      let follow = Task.follow_up_text t "more input" in
      Alcotest.(check (option string)) "follow task" (Some "t-1") follow.task_id;
      Alcotest.(check (option string)) "follow ctx" (Some "ctx-1") follow.context_id
  | Ok (Message _) -> Alcotest.fail "expected task"
  | Error e -> Alcotest.fail (Error.to_string e)

let test_rpc_error () =
  run @@ fun clock ->
  let transport, _ =
    Mock.transport ~clock (fun req ->
        Mock.json_reply (Mock.error_envelope ~id:(`String (Mock.request_id req)) (-32001) "Task not found"))
  in
  let client = create ~clock ~transport endpoint in
  get_task client "nope"
  |> expect_error "task not found" (function
       | Error.Rpc_error { code = Task_not_found; message = "Task not found"; _ } -> true
       | _ -> false);
  cancel_task client "nope" |> expect_error "cancel" (function Error.Rpc_error _ -> true | _ -> false)

let test_http_error () =
  run @@ fun clock ->
  let transport, rec_ =
    Mock.transport ~clock (fun _ ->
        Mock.reply ~status:503 ~headers:[ ("content-type", "text/html") ] [ Mock.Chunk "<h1>Down</h1>" ])
  in
  let client = create ~clock ~transport endpoint in
  send_text client "x"
  |> expect_error "503" (function
       | Error.Http_error { status = 503; body = "<h1>Down</h1>" } -> true
       | _ -> false);
  Alcotest.(check int) "released" 1 rec_.released

let test_invalid_responses () =
  run @@ fun clock ->
  let body = ref "" in
  let transport, _ = Mock.transport ~clock (fun _ -> Mock.json_reply !body) in
  let client = create ~clock ~transport ~max_response_size:4096 endpoint in
  let invalid name b =
    body := b;
    send_text client "x" |> expect_error name (function Error.Invalid_response _ -> true | _ -> false)
  in
  invalid "not json" "<html>oops</html>";
  invalid "empty" "";
  invalid "wrong id" (Mock.result_envelope ~id:"someone-else" (`Assoc [ ("task", task_json "t" "WORKING") ]));
  invalid "schema" {|{"jsonrpc":"2.0","id":"x","result":{"task":{"id":"t"}}}|};
  invalid "too large" (String.make 5000 ' ');
  let transport, _ =
    Mock.transport ~clock (fun req ->
        Mock.json_reply
          (Mock.result_envelope ~id:(Mock.request_id req)
             (`Assoc [ ("task", `Assoc [ ("id", `String "t"); ("status", `Assoc [ ("state", `String "BOGUS") ]) ]) ])))
  in
  let client = create ~clock ~transport endpoint in
  match send_text client "x" with
  | Error (Error.Invalid_response msg) ->
      Alcotest.(check bool) "path in message" true
        (Test_codec.contains ~sub:"$.result.task.status.state" msg)
  | _ -> Alcotest.fail "expected Invalid_response"

let test_transport_failure () =
  run @@ fun clock ->
  let transport : Transport.t = fun ~sw:_ _ -> failwith "connection refused" in
  let client = create ~clock ~transport endpoint in
  send_text client "x" |> expect_error "refused" (function Error.Transport_error _ -> true | _ -> false);
  let transport, rec_ =
    Mock.transport ~clock (fun _ -> Mock.reply [ Mock.Chunk "{\"jsonrpc\""; Mock.Raise (Failure "reset") ])
  in
  let client = create ~clock ~transport endpoint in
  send_text client "x" |> expect_error "reset" (function Error.Transport_error _ -> true | _ -> false);
  Alcotest.(check int) "released" 1 rec_.released

let test_timeout () =
  run @@ fun clock ->
  let transport, rec_ = Mock.transport ~clock (fun _ -> { (Mock.json_reply "{}") with delay = 60. }) in
  let client = create ~clock ~transport ~timeout:5. endpoint in
  let t0 = Eio.Time.Mono.now clock in
  send_text client "x" |> expect_error "timeout" (function Error.Timeout _ -> true | _ -> false);
  let elapsed = Mtime.span t0 (Eio.Time.Mono.now clock) |> Mtime.Span.to_float_ns in
  Alcotest.(check (float 1e6)) "gave up after 5s" 5e9 elapsed;
  Alcotest.(check int) "released" 1 rec_.released;
  let transport, rec_ = Mock.transport ~clock (fun _ -> Mock.reply [ Mock.Chunk "{"; Mock.Block ]) in
  let client = create ~clock ~transport ~timeout:5. endpoint in
  get_task client "t" |> expect_error "body timeout" (function Error.Timeout _ -> true | _ -> false);
  Alcotest.(check int) "released" 1 rec_.released

let test_no_secrets_in_logs () =
  let buf = Buffer.create 1024 in
  let ppf = Format.formatter_of_buffer buf in
  let old_reporter = Logs.reporter () and old_level = Logs.Src.level A2a_client.src in
  Logs.set_reporter (Logs.format_reporter ~app:ppf ~dst:ppf ());
  Logs.Src.set_level A2a_client.src (Some Logs.Debug);
  Fun.protect
    ~finally:(fun () ->
      Logs.set_reporter old_reporter;
      Logs.Src.set_level A2a_client.src old_level)
    (fun () ->
      run @@ fun clock ->
      let transport, _ =
        Mock.transport ~clock (fun _ ->
            Mock.reply ~status:401 [ Mock.Chunk "unauthorized" ])
      in
      let client =
        create ~clock ~transport ~auth:(Auth.bearer "SECRET-TOKEN-123")
          ~headers:[ ("X-Api-Key", "SECRET-KEY-456") ]
          (Uri.of_string "http://user:SECRET-PW@agent.test/a2a?key=SECRET-Q")
      in
      ignore (send_text client "hello");
      Format.pp_print_flush ppf ();
      let logs = Buffer.contents buf in
      Alcotest.(check bool) "something was logged" true (Test_codec.contains ~sub:"SendMessage" logs);
      List.iter
        (fun secret ->
          if Test_codec.contains ~sub:secret logs then Alcotest.failf "log leaked %s:\n%s" secret logs)
        [ "SECRET-TOKEN-123"; "SECRET-KEY-456"; "SECRET-PW"; "SECRET-Q" ])

let scripted_tasks states =
  let remaining = ref states in
  fun req ->
    let state = match !remaining with [ s ] -> s | s :: rest -> remaining := rest; s | [] -> assert false in
    Mock.json_reply (Mock.result_envelope ~id:(Mock.request_id req) (task_json "t-1" state))

let test_get_task () =
  run @@ fun clock ->
  let transport, rec_ = Mock.transport ~clock (scripted_tasks [ "INPUT_REQUIRED" ]) in
  let client = create ~clock ~transport endpoint in
  let t = ok "get_task" (get_task client ~history_length:5 "t-1") in
  Alcotest.(check bool) "interrupted" true (Task.is_interrupted t);
  let req = List.hd rec_.requests in
  Alcotest.(check string) "method" "GetTask" (meth req);
  Alcotest.(check bool) "params" true
    (params req = `Assoc [ ("id", `String "t-1"); ("historyLength", `Int 5) ])

let test_cancel_task () =
  run @@ fun clock ->
  let transport, rec_ = Mock.transport ~clock (scripted_tasks [ "CANCELED" ]) in
  let client = create ~clock ~transport endpoint in
  let t = ok "cancel" (cancel_task client "t-1") in
  Alcotest.(check bool) "canceled" true (Task.state t = Task_state.Canceled);
  Alcotest.(check string) "method" "CancelTask" (meth (List.hd rec_.requests));
  let transport, _ =
    Mock.transport ~clock (fun req ->
        Mock.json_reply (Mock.error_envelope ~id:(`String (Mock.request_id req)) (-32002) "Task cannot be canceled"))
  in
  cancel_task (create ~clock ~transport endpoint) "t-1"
  |> expect_error "not cancelable" (function
       | Error.Rpc_error { code = Task_not_cancelable; _ } -> true
       | _ -> false)

let test_wait_for_task () =
  run @@ fun clock ->
  let transport, rec_ =
    Mock.transport ~clock (scripted_tasks [ "SUBMITTED"; "WORKING"; "WORKING"; "COMPLETED" ])
  in
  let client = create ~clock ~transport endpoint in
  let t0 = Eio.Time.Mono.now clock in
  let t = ok "wait" (wait_for_task client ~interval:1. ~backoff:2. ~max_interval:3. ~timeout:60. "t-1") in
  Alcotest.(check bool) "completed" true (Task.state t = Task_state.Completed);
  Alcotest.(check int) "4 polls" 4 (List.length rec_.requests);
  let elapsed = Mtime.span t0 (Eio.Time.Mono.now clock) |> Mtime.Span.to_float_ns in
  Alcotest.(check (float 1e6)) "backoff" 6e9 elapsed;
  Alcotest.(check int) "all released" 4 rec_.released

let test_wait_for_task_settles_on_each_state () =
  List.iter
    (fun (state, expect) ->
      run @@ fun clock ->
      let transport, _ = Mock.transport ~clock (scripted_tasks [ "WORKING"; state ]) in
      let client = create ~clock ~transport endpoint in
      let t = ok state (wait_for_task client ~timeout:60. "t-1") in
      Alcotest.(check bool) state true (Task.state t = expect))
    [ ("COMPLETED", Task_state.Completed); ("FAILED", Failed); ("CANCELED", Canceled);
      ("REJECTED", Rejected); ("INPUT_REQUIRED", Input_required); ("AUTH_REQUIRED", Auth_required) ]

let test_wait_for_task_timeout () =
  run @@ fun clock ->
  let transport, rec_ = Mock.transport ~clock (scripted_tasks [ "WORKING" ]) in
  let client = create ~clock ~transport endpoint in
  (match wait_for_task client ~interval:1. ~backoff:1. ~timeout:10.5 "t-1" with
   | Error (Error.Poll_timeout { last_task = Some t }) ->
       Alcotest.(check bool) "last state" true (Task.state t = Task_state.Working)
   | _ -> Alcotest.fail "expected Poll_timeout");
  Alcotest.(check int) "bounded polling" 11 (List.length rec_.requests);
  Alcotest.(check int) "no leak" rec_.opened rec_.released

let test_send_message_and_wait () =
  run @@ fun clock ->
  let calls = ref 0 in
  let transport, _ =
    Mock.transport ~clock (fun req ->
        incr calls;
        let id = Mock.request_id req in
        match meth req with
        | "SendMessage" ->
            Mock.json_reply (Mock.result_envelope ~id (`Assoc [ ("task", task_json "t-1" "SUBMITTED") ]))
        | "GetTask" ->
            let state = if !calls < 3 then "WORKING" else "INPUT_REQUIRED" in
            Mock.json_reply (Mock.result_envelope ~id (task_json "t-1" state))
        | m -> Alcotest.failf "unexpected %s" m)
  in
  let client = create ~clock ~transport endpoint in
  (match send_message_and_wait client ~timeout:60. (Message.user_text "book a flight") with
   | Ok (Outcome.Input_required t) -> Alcotest.(check string) "task" "t-1" t.id
   | Ok _ -> Alcotest.fail "expected Input_required"
   | Error e -> Alcotest.fail (Error.to_string e));
  let transport, rec_ =
    Mock.transport ~clock (fun req ->
        Mock.json_reply
          (Mock.result_envelope ~id:(Mock.request_id req) (`Assoc [ ("message", agent_message_json "hi") ])))
  in
  (match send_message_and_wait (create ~clock ~transport endpoint) ~timeout:60. (Message.user_text "hi") with
   | Ok (Outcome.Message _) -> ()
   | _ -> Alcotest.fail "expected Message");
  Alcotest.(check int) "single request" 1 (List.length rec_.requests)

let stream_events ~id =
  let ev j = Mock.sse_data (Mock.result_envelope ~id j) in
  [ ev (`Assoc [ ("task", task_json "t-1" "SUBMITTED") ]);
    ev
      (`Assoc
         [ ("statusUpdate",
             `Assoc
               [ ("taskId", `String "t-1"); ("contextId", `String "ctx-1");
                 ("status",
                   `Assoc
                     [ ("state", `String "TASK_STATE_WORKING");
                       ("message", agent_message_json "thinking") ]) ]) ]);
    ev
      (`Assoc
         [ ("artifactUpdate",
             `Assoc
               [ ("taskId", `String "t-1"); ("contextId", `String "ctx-1");
                 ("artifact", `Assoc [ ("artifactId", `String "a1"); ("name", `String "report");
                                       ("parts", `List [ `Assoc [ ("text", `String "Hello, ") ] ]) ]) ]) ]);
    ev
      (`Assoc
         [ ("artifactUpdate",
             `Assoc
               [ ("taskId", `String "t-1"); ("contextId", `String "ctx-1");
                 ("artifact", `Assoc [ ("artifactId", `String "a1");
                                       ("parts", `List [ `Assoc [ ("text", `String "world") ] ]) ]);
                 ("append", `Bool true); ("lastChunk", `Bool true) ]) ]);
    ev
      (`Assoc
         [ ("statusUpdate",
             `Assoc
               [ ("taskId", `String "t-1"); ("contextId", `String "ctx-1");
                 ("status", `Assoc [ ("state", `String "TASK_STATE_COMPLETED") ]) ]) ]) ]

let chunks n s =
  let rec go i acc =
    if i >= String.length s then List.rev acc
    else go (i + n) (String.sub s i (min n (String.length s - i)) :: acc)
  in
  go 0 []

let kind = function
  | Stream_response.Task _ -> "task"
  | Message _ -> "message"
  | Status_update e -> "status:" ^ Task_state.to_string e.status.state
  | Artifact_update _ -> "artifact"

let test_streaming_incremental () =
  run @@ fun clock ->
  let seen = ref [] in
  let transport, rec_ =
    Mock.transport ~clock (fun req ->
        let events = stream_events ~id:(Mock.request_id req) in
        Mock.sse_reply
          (List.concat
             (List.mapi
                (fun i e ->
                  Mock.Check (fun () -> Alcotest.(check int) "handled before next" i (List.length !seen))
                  :: Mock.Sleep 0.5
                  :: List.map (fun c -> Mock.Chunk c) (chunks 7 e))
                events)
          @ [ Mock.Block  ]))
  in
  let client = create ~clock ~transport endpoint in
  let outcome =
    ok "stream"
      (send_streaming_message client (Message.user_text "write")
         ~on_event:(fun ev -> seen := kind ev :: !seen))
  in
  Alcotest.(check (list string)) "events in order"
    [ "task"; "status:TASK_STATE_WORKING"; "artifact"; "artifact"; "status:TASK_STATE_COMPLETED" ]
    (List.rev !seen);
  (match outcome with
   | Outcome.Completed t ->
       Alcotest.(check int) "one artifact" 1 (List.length t.artifacts);
       Alcotest.(check string) "appended" "Hello, world" (Artifact.text (List.hd t.artifacts));
       Alcotest.(check (option string)) "name kept" (Some "report") (List.hd t.artifacts).name;
       Alcotest.(check int) "status message in history" 1 (List.length t.history)
   | _ -> Alcotest.fail "expected Completed");
  let req = List.hd rec_.requests in
  Alcotest.(check string) "method" "SendStreamingMessage" (meth req);
  Alcotest.(check (option string)) "accept" (Some "text/event-stream") (header "accept" req);
  Alcotest.(check int) "released" 1 rec_.released

let test_streaming_message_only () =
  run @@ fun clock ->
  let transport, _ =
    Mock.transport ~clock (fun req ->
        Mock.sse_reply
          [ Mock.Chunk (Mock.sse_data (Mock.result_envelope ~id:(Mock.request_id req)
                                         (`Assoc [ ("message", agent_message_json "quick answer") ])));
            Mock.Block ])
  in
  match send_streaming_message (create ~clock ~transport endpoint) (Message.user_text "q") with
  | Ok (Outcome.Message m) -> Alcotest.(check string) "text" "quick answer" (Message.text m)
  | _ -> Alcotest.fail "expected Message"

let test_streaming_disconnect () =
  run @@ fun clock ->
  let transport, rec_ =
    Mock.transport ~clock (fun req ->
        let events = stream_events ~id:(Mock.request_id req) in
        let third = List.nth events 2 in
        Mock.sse_reply
          [ Mock.Chunk (List.nth events 0); Mock.Chunk (List.nth events 1);
            Mock.Chunk (String.sub third 0 20) ])
  in
  let n = ref 0 in
  (match send_streaming_message (create ~clock ~transport endpoint) ~on_event:(fun _ -> incr n) (Message.user_text "x") with
   | Error (Error.Stream_ended { last_task = Some t }) ->
       Alcotest.(check bool) "last known state" true (Task.state t = Task_state.Working)
   | _ -> Alcotest.fail "expected Stream_ended");
  Alcotest.(check int) "partial event not delivered" 2 !n;
  Alcotest.(check int) "released" 1 rec_.released;
  let transport, rec_ =
    Mock.transport ~clock (fun req ->
        Mock.sse_reply [ Mock.Chunk (List.hd (stream_events ~id:(Mock.request_id req))); Mock.Raise (Failure "reset") ])
  in
  send_streaming_message (create ~clock ~transport endpoint) (Message.user_text "x")
  |> expect_error "reset" (function Error.Transport_error _ -> true | _ -> false);
  Alcotest.(check int) "released" 1 rec_.released

let test_streaming_interrupted_end () =
  run @@ fun clock ->
  let transport, _ =
    Mock.transport ~clock (fun req ->
        Mock.sse_reply
          [ Mock.Chunk (Mock.sse_data (Mock.result_envelope ~id:(Mock.request_id req)
                                         (`Assoc [ ("task", task_json "t-1" "AUTH_REQUIRED") ]))) ])
  in
  match send_streaming_message (create ~clock ~transport endpoint) (Message.user_text "x") with
  | Ok (Outcome.Auth_required _) -> ()
  | _ -> Alcotest.fail "server closing in an interrupted state is a normal end"

let test_streaming_rpc_error () =
  run @@ fun clock ->
  let transport, _ =
    Mock.transport ~clock (fun req ->
        let id = Mock.request_id req in
        Mock.sse_reply
          [ Mock.Chunk (List.hd (stream_events ~id));
            Mock.Chunk ("event: error\n" ^ Mock.sse_data (Mock.error_envelope ~id:(`String id) (-32603) "boom"));
            Mock.Block ])
  in
  send_streaming_message (create ~clock ~transport endpoint) (Message.user_text "x")
  |> expect_error "in-stream" (function Error.Rpc_error { code = Internal_error; _ } -> true | _ -> false);
  let transport, _ =
    Mock.transport ~clock (fun req ->
        Mock.json_reply (Mock.error_envelope ~id:(`String (Mock.request_id req)) (-32004) "Streaming is not supported"))
  in
  send_streaming_message (create ~clock ~transport endpoint) (Message.user_text "x")
  |> expect_error "upfront" (function Error.Rpc_error { code = Unsupported_operation; _ } -> true | _ -> false);
  let transport, rec_ = Mock.transport ~clock (fun _ -> Mock.sse_reply [ Mock.Chunk "data: {oops\n\n"; Mock.Block ]) in
  send_streaming_message (create ~clock ~transport endpoint) (Message.user_text "x")
  |> expect_error "garbage" (function Error.Invalid_response _ -> true | _ -> false);
  Alcotest.(check int) "released" 1 rec_.released;
  let transport, _ = Mock.transport ~clock (fun _ -> Mock.reply ~status:401 [ Mock.Chunk "no" ]) in
  send_streaming_message (create ~clock ~transport endpoint) (Message.user_text "x")
  |> expect_error "401" (function Error.Http_error { status = 401; _ } -> true | _ -> false)

let test_streaming_cancellation () =
  run @@ fun clock ->
  let transport, rec_ =
    Mock.transport ~clock (fun req ->
        Mock.sse_reply [ Mock.Chunk (List.hd (stream_events ~id:(Mock.request_id req))); Mock.Block ])
  in
  let client = create ~clock ~transport endpoint in
  let got = ref 0 in
  let winner =
    Eio.Fiber.first
      (fun () ->
        ignore (send_streaming_message client ~on_event:(fun _ -> incr got) (Message.user_text "x"));
        `Stream)
      (fun () ->
        Eio.Time.Mono.sleep clock 30.;
        `Cancelled)
  in
  Alcotest.(check bool) "cancelled by the other fiber" true (winner = `Cancelled);
  Alcotest.(check int) "first event was delivered" 1 !got;
  Alcotest.(check int) "connection released" 1 rec_.released

let test_streaming_callback_exception () =
  run @@ fun clock ->
  let transport, rec_ =
    Mock.transport ~clock (fun req ->
        Mock.sse_reply (List.map (fun e -> Mock.Chunk e) (stream_events ~id:(Mock.request_id req)) @ [ Mock.Block ]))
  in
  let client = create ~clock ~transport endpoint in
  (match send_streaming_message client ~on_event:(fun _ -> raise Exit) (Message.user_text "x") with
   | exception Exit -> ()
   | _ -> Alcotest.fail "callback exception must propagate");
  Alcotest.(check int) "released" 1 rec_.released

let test_streaming_idle_timeout () =
  run @@ fun clock ->
  let transport, rec_ =
    Mock.transport ~clock (fun req ->
        Mock.sse_reply
          [ Mock.Chunk (List.hd (stream_events ~id:(Mock.request_id req)));
            Mock.Sleep 5.; Mock.Chunk ": keepalive\n"; Mock.Sleep 5.; Mock.Chunk ": keepalive\n";
            Mock.Sleep 20.; Mock.Chunk "never" ])
  in
  send_streaming_message (create ~clock ~transport ~stream_idle_timeout:10. endpoint) (Message.user_text "x")
  |> expect_error "idle" (function Error.Timeout _ -> true | _ -> false);
  Alcotest.(check int) "released" 1 rec_.released

let test_streaming_stalled_error_body () =
  run @@ fun clock ->
  let transport, rec_ =
    Mock.transport ~clock (fun _ ->
        Mock.reply ~status:200 ~headers:[ ("content-type", "application/json") ] [ Mock.Chunk "{"; Mock.Block ])
  in
  send_streaming_message (create ~clock ~transport ~timeout:5. endpoint) (Message.user_text "x")
  |> expect_error "stalled" (function Error.Timeout _ -> true | _ -> false);
  Alcotest.(check int) "released" 1 rec_.released

let test_streaming_ignores_foreign_event_types () =
  run @@ fun clock ->
  let transport, _ =
    Mock.transport ~clock (fun req ->
        let events = stream_events ~id:(Mock.request_id req) in
        Mock.sse_reply
          (Mock.Chunk "event: ping\ndata: not json\n\n" :: List.map (fun e -> Mock.Chunk e) events))
  in
  match send_streaming_message (create ~clock ~transport endpoint) (Message.user_text "x") with
  | Ok (Outcome.Completed _) -> ()
  | Ok _ -> Alcotest.fail "expected Completed"
  | Error e -> Alcotest.fail (Error.to_string e)

let test_streaming_capability_check () =
  run @@ fun clock ->
  let card =
    match Codec.decode_string Codec.agent_card {|{"name":"a","capabilities":{"streaming":false}}|} with
    | Ok c -> c
    | Error e -> Alcotest.fail e
  in
  let transport, rec_ = Mock.transport ~clock (fun _ -> Alcotest.fail "must not send") in
  send_streaming_message (create ~clock ~transport ~card endpoint) (Message.user_text "x")
  |> expect_error "capability" (function Error.Unsupported_capability _ -> true | _ -> false);
  Alcotest.(check int) "nothing sent" 0 (List.length rec_.requests)

let test_subscribe_to_task () =
  run @@ fun clock ->
  let transport, rec_ =
    Mock.transport ~clock (fun req ->
        Mock.sse_reply (List.map (fun e -> Mock.Chunk e) (List.tl (stream_events ~id:(Mock.request_id req)))))
  in
  (match subscribe_to_task (create ~clock ~transport endpoint) "t-1" with
   | Ok (Outcome.Completed t) -> Alcotest.(check string) "task" "t-1" t.id
   | _ -> Alcotest.fail "expected Completed");
  let req = List.hd rec_.requests in
  Alcotest.(check string) "method" "SubscribeToTask" (meth req);
  Alcotest.(check bool) "params" true (params req = `Assoc [ ("id", `String "t-1") ])

let card_json =
  {|{"name":"Echo","description":"d","version":"1.0.0",
     "supportedInterfaces":[{"url":"http://agent.test/rpc","protocolBinding":"JSONRPC","protocolVersion":"1.0","tenant":"t9"}],
     "capabilities":{"streaming":true},"defaultInputModes":["text/plain"],"defaultOutputModes":["text/plain"],"skills":[]}|}

let test_connect () =
  run @@ fun clock ->
  let transport, rec_ =
    Mock.transport ~clock (fun req ->
        match req.meth with
        | `GET -> Mock.json_reply card_json
        | `POST | `DELETE ->
            Mock.json_reply
              (Mock.result_envelope ~id:(Mock.request_id req) (`Assoc [ ("message", agent_message_json "ok") ])))
  in
  let client = ok "connect" (connect ~clock ~transport (Uri.of_string "http://agent.test/")) in
  Alcotest.(check string) "endpoint from card" "http://agent.test/rpc" (Uri.to_string (A2a_client.endpoint client));
  ignore (ok "send" (send_text client "hi"));
  (match List.rev rec_.requests with
   | [ get; post ] ->
       Alcotest.(check string) "well-known" "http://agent.test/.well-known/agent-card.json" (Uri.to_string get.uri);
       Alcotest.(check bool) "tenant from interface" true (member [ "tenant" ] (params post) = `String "t9")
   | _ -> Alcotest.fail "two requests");
  Alcotest.(check string) "explicit card URL kept" "http://x/card.json"
    (Uri.to_string (agent_card_uri (Uri.of_string "http://x/card.json")));
  Alcotest.(check string) "base path" "http://x/agents/a/.well-known/agent-card.json"
    (Uri.to_string (agent_card_uri (Uri.of_string "http://x/agents/a")))

let test_fetch_agent_card_errors () =
  run @@ fun clock ->
  let reply = ref (Mock.json_reply "") in
  let transport, _ = Mock.transport ~clock (fun _ -> !reply) in
  let fetch () = fetch_agent_card ~clock ~transport (Uri.of_string "http://agent.test") in
  reply := Mock.reply ~status:404 [ Mock.Chunk "not found" ];
  fetch () |> expect_error "404" (function Error.Http_error { status = 404; _ } -> true | _ -> false);
  reply := Mock.json_reply "{\"name\": 42}";
  fetch () |> expect_error "bad card" (function Error.Invalid_response _ -> true | _ -> false);
  reply := Mock.json_reply {|{"name":"old","supportedInterfaces":[{"url":"http://a","protocolBinding":"JSONRPC","protocolVersion":"0.2"}]}|};
  connect ~clock ~transport (Uri.of_string "http://agent.test")
  |> expect_error "v0.2 only" (function Error.No_compatible_interface _ -> true | _ -> false)

let tests =
  [ ("SendMessage -> Message", `Quick, test_send_message_message);
    ("SendMessage -> Task", `Quick, test_send_message_task);
    ("JSON-RPC error", `Quick, test_rpc_error);
    ("HTTP error", `Quick, test_http_error);
    ("invalid responses", `Quick, test_invalid_responses);
    ("transport failure", `Quick, test_transport_failure);
    ("timeout", `Quick, test_timeout);
    ("no secrets in logs", `Quick, test_no_secrets_in_logs);
    ("GetTask", `Quick, test_get_task);
    ("CancelTask", `Quick, test_cancel_task);
    ("wait_for_task backoff", `Quick, test_wait_for_task);
    ("wait_for_task each state", `Quick, test_wait_for_task_settles_on_each_state);
    ("wait_for_task timeout", `Quick, test_wait_for_task_timeout);
    ("send_message_and_wait", `Quick, test_send_message_and_wait);
    ("streaming incremental", `Quick, test_streaming_incremental);
    ("streaming message only", `Quick, test_streaming_message_only);
    ("streaming disconnect", `Quick, test_streaming_disconnect);
    ("streaming interrupted end", `Quick, test_streaming_interrupted_end);
    ("streaming errors", `Quick, test_streaming_rpc_error);
    ("streaming cancellation", `Quick, test_streaming_cancellation);
    ("streaming callback exception", `Quick, test_streaming_callback_exception);
    ("streaming idle timeout", `Quick, test_streaming_idle_timeout);
    ("streaming stalled error body", `Quick, test_streaming_stalled_error_body);
    ("streaming ignores foreign event types", `Quick, test_streaming_ignores_foreign_event_types);
    ("streaming capability check", `Quick, test_streaming_capability_check);
    ("SubscribeToTask", `Quick, test_subscribe_to_task);
    ("connect via Agent Card", `Quick, test_connect);
    ("Agent Card errors", `Quick, test_fetch_agent_card_errors) ]
