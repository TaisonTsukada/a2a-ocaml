open A2a_client
module T = A2a_client_testing
module Step = T.Step
module Reply = T.Reply

let run = Test_client.run
let endpoint = Test_client.endpoint
let ok = Test_client.ok

let agent_msg id text = Message.make ~message_id:id ~context_id:"ctx-1" ~role:Agent [ Part.text text ]

let task state = Task.make ~context_id:"ctx-1" ~id:"t-1" (Task_status.make state)

let status ?message state =
  Stream_response.Status_update
    { task_id = "t-1"; context_id = "ctx-1"; status = Task_status.make ?message state;
      metadata = None }

let ui n = status ~message:(agent_msg (Printf.sprintf "ui-%d" n) "{}") Working

(* The five cases of a BFF that relays a stream and answers 502 when the
   agent did not accept the request. *)
let relay ?(protocol_version = Protocol_version.V1_0) ?(binding = Protocol_binding.Jsonrpc) clock
    reply =
  let agent = T.agent ~protocol_version ~binding ~clock (fun _ -> reply) in
  let client = create ~clock ~transport:(T.transport agent) ~protocol_version ~binding endpoint in
  Eio.Switch.run @@ fun sw ->
  match open_streaming_message client ~sw (Message.user_text "go") with
  | Error e -> `Bad_gateway e
  | Ok s ->
      let rec drain acc =
        match Event_stream.next s with
        | Ok (Some ev) -> drain (ev :: acc)
        | Ok None -> `Relayed (List.rev acc, None)
        | Error e -> `Relayed (List.rev acc, Some e)
      in
      drain []

let test_relay_cases () =
  run @@ fun clock ->
  let events = [ Stream_response.Task (task Submitted); ui 1; ui 2; ui 3; status Completed ] in
  (match relay clock (Reply.stream (List.map Step.event events)) with
   | `Relayed (evs, None) -> Alcotest.(check int) "all events" 5 (List.length evs)
   | _ -> Alcotest.fail "normal: expected a relayed stream");
  (match relay clock Reply.refuse with
   | `Bad_gateway (Error.Transport_error _) -> ()
   | _ -> Alcotest.fail "refused: expected Transport_error");
  (match relay clock (Reply.http ~status:500 "boom") with
   | `Bad_gateway (Error.Http_error { status = 500; body = "boom" }) -> ()
   | _ -> Alcotest.fail "HTTP 500: expected Http_error");
  (match relay clock (Reply.error Invalid_params "bad") with
   | `Bad_gateway (Error.Rpc_error { code = Invalid_params; _ }) -> ()
   | _ -> Alcotest.fail "error response: expected Invalid_params");
  (match relay clock (Reply.stream [ Step.error Invalid_params "bad" ]) with
   | `Bad_gateway (Error.Rpc_error { code = Invalid_params; _ }) -> ()
   | _ -> Alcotest.fail "error event: expected Invalid_params at open");
  match relay clock (Reply.stream [ Step.event (Task (task Working)); Step.event (ui 1); Step.drop ]) with
  | `Relayed ([ _; _ ], Some (Error.Transport_error _)) -> ()
  | `Relayed (evs, e) ->
      Alcotest.failf "dropped: %d events, %s" (List.length evs)
        (Option.fold ~none:"no error" ~some:Error.to_string e)
  | `Bad_gateway e -> Alcotest.failf "dropped: refused at open: %s" (Error.to_string e)

let test_wire_formats () =
  run @@ fun clock ->
  let events = [ Stream_response.Task (task Working); ui 1; status Completed ] in
  List.iter
    (fun (name, protocol_version, binding) ->
      (match relay ~protocol_version ~binding clock (Reply.stream (List.map Step.event events)) with
       | `Relayed ([ Task _; Status_update _; Status_update { status = { state = Completed; _ }; _ } ], None) -> ()
       | _ -> Alcotest.failf "%s: events not relayed" name);
      match relay ~protocol_version ~binding clock (Reply.error ~status:404 Task_not_found "gone") with
      | `Bad_gateway (Error.Rpc_error { code = Task_not_found; message = "gone"; _ }) -> ()
      | `Bad_gateway e -> Alcotest.failf "%s: %s" name (Error.to_string e)
      | `Relayed _ -> Alcotest.failf "%s: expected an error" name)
    [ ("1.0 JSON-RPC", Protocol_version.V1_0, Protocol_binding.Jsonrpc);
      ("1.0 REST", V1_0, Http_json); ("0.3 JSON-RPC", V0_3, Jsonrpc) ]

let test_outcome_and_end () =
  run @@ fun clock ->
  let agent =
    T.agent ~clock (fun _ ->
        Reply.stream [ Step.event (Task (task Working)); Step.event (status ~message:(agent_msg "m" "done") Completed) ])
  in
  let client = create ~clock ~transport:(T.transport agent) endpoint in
  Eio.Switch.run @@ fun sw ->
  let s = ok "open" (open_streaming_message client ~sw (Message.user_text "go")) in
  Alcotest.(check bool) "no outcome before the end" true (Event_stream.outcome s = None);
  ignore (ok "first" (Event_stream.next s));
  ignore (ok "second" (Event_stream.next s));
  Alcotest.(check bool) "end" true (ok "end" (Event_stream.next s) = None);
  Alcotest.(check bool) "end again" true (ok "end again" (Event_stream.next s) = None);
  match Event_stream.outcome s with
  | Some (Ok (Outcome.Completed t)) -> Alcotest.(check int) "history" 1 (List.length t.history)
  | _ -> Alcotest.fail "expected Completed"

let test_close () =
  run @@ fun clock ->
  let released = ref false in
  let agent = T.agent ~clock (fun _ -> Reply.stream [ Step.event (Task (task Working)); Step.hang ]) in
  let transport : Transport.t =
   fun ~sw req ->
    Eio.Switch.on_release sw (fun () -> released := true);
    T.transport agent ~sw req
  in
  let client = create ~clock ~transport endpoint in
  Eio.Switch.run @@ fun sw ->
  let s = ok "open" (open_streaming_message client ~sw (Message.user_text "go")) in
  ignore (ok "first" (Event_stream.next s));
  Eio.Fiber.both
    (fun () -> Alcotest.(check bool) "waiting next ends" true (ok "next" (Event_stream.next s) = None))
    (fun () -> Event_stream.close s);
  Eio.Fiber.yield ();
  Alcotest.(check bool) "connection released" true !released;
  Alcotest.(check bool) "next after close" true (ok "next" (Event_stream.next s) = None);
  Alcotest.(check bool) "no outcome after close" true (Event_stream.outcome s = None);
  Event_stream.close s

let test_switch_release () =
  run @@ fun clock ->
  let agent = T.agent ~clock (fun _ -> Reply.stream [ Step.event (Task (task Working)); Step.hang ]) in
  let client = create ~clock ~transport:(T.transport agent) endpoint in
  (* Leaving the switch without closing the stream must not hang. *)
  Eio.Switch.run (fun sw ->
      let s = ok "open" (open_streaming_message client ~sw (Message.user_text "go")) in
      ignore (ok "first" (Event_stream.next s)))

let test_no_read_ahead () =
  run @@ fun clock ->
  let reads = ref 0 in
  let events = [ Stream_response.Task (task Working); ui 1; ui 2; ui 3; status Completed ] in
  let agent = T.agent ~clock (fun _ -> Reply.stream (List.map Step.event events)) in
  let transport : Transport.t =
   fun ~sw req ->
    let resp = T.transport agent ~sw req in
    let module Counting = struct
      type t = Eio.Flow.source_ty Eio.Resource.t

      let read_methods = []

      let single_read t buf =
        incr reads;
        Eio.Flow.single_read t buf
    end in
    { resp with body = Eio.Resource.T (resp.body, Eio.Flow.Pi.source (module Counting)) }
  in
  let client = create ~clock ~transport endpoint in
  Eio.Switch.run @@ fun sw ->
  let s = ok "open" (open_streaming_message client ~sw (Message.user_text "go")) in
  for _ = 1 to 10 do Eio.Fiber.yield () done;
  (* Only the first event, waiting to be handed over. *)
  Alcotest.(check int) "reads while the caller does not ask" 1 !reads;
  let rec drain n = match ok "next" (Event_stream.next s) with Some _ -> drain (n + 1) | None -> n in
  Alcotest.(check int) "events" 5 (drain 0)

let test_accumulate () =
  run @@ fun clock ->
  let n = 50 in
  let agent =
    T.agent ~clock (fun _ ->
        Reply.stream
          (Step.event (Task (task Submitted))
           :: List.init n (fun i -> Step.event (ui i))
           @ [ Step.event
                 (Artifact_update
                    { task_id = "t-1"; context_id = "ctx-1";
                      artifact = Artifact.make ~artifact_id:"a" [ Part.text "x" ];
                      append = false; last_chunk = true; metadata = None });
               Step.event (status Completed) ]))
  in
  let client = create ~clock ~transport:(T.transport agent) endpoint in
  let count = ref 0 in
  (match
     send_streaming_message client ~accumulate:false ~on_event:(fun _ -> incr count)
       (Message.user_text "go")
   with
   | Ok (Outcome.Completed t) ->
       Alcotest.(check int) "events still delivered" (n + 3) !count;
       Alcotest.(check int) "no history kept" 0 (List.length t.history);
       Alcotest.(check int) "no artifacts kept" 0 (List.length t.artifacts);
       Alcotest.(check string) "id" "t-1" t.id;
       Alcotest.(check (option string)) "context" (Some "ctx-1") t.context_id
   | _ -> Alcotest.fail "expected Completed");
  match send_streaming_message client (Message.user_text "go") with
  | Ok (Outcome.Completed t) ->
      Alcotest.(check int) "history by default" n (List.length t.history);
      Alcotest.(check int) "artifacts by default" 1 (List.length t.artifacts)
  | _ -> Alcotest.fail "expected Completed"

let card_json url =
  Printf.sprintf
    {|{"name":"a","description":"","version":"1","capabilities":{"streaming":true},
       "defaultInputModes":[],"defaultOutputModes":[],"skills":[],
       "supportedInterfaces":[{"url":%S,"protocolBinding":"JSONRPC","protocolVersion":"1.0"}]}|}
    url

let test_rewrite_endpoint () =
  run @@ fun clock ->
  let agent =
    T.agent ~clock (fun req ->
        if Uri.path req.uri = "/.well-known/agent-card.json" then
          Reply.http ~status:200 ~content_type:"application/json" (card_json "http://127.0.0.1:8080/a2a?x=1")
        else Reply.send_message_response (Message (agent_msg "r" "hi")))
  in
  let base = Uri.of_string "https://agent.ns.svc:9443" in
  let client =
    ok "connect"
      (connect ~clock ~transport:(T.transport agent) ~rewrite_endpoint:(rebase_endpoint ~onto:base) base)
  in
  Alcotest.(check string) "endpoint" "https://agent.ns.svc:9443/a2a?x=1" (Uri.to_string (A2a_client.endpoint client));
  ignore (ok "send" (send_text client "hello"));
  let last = List.nth (T.requests agent) 1 in
  Alcotest.(check string) "request goes to the rebased host" "https://agent.ns.svc:9443/a2a?x=1"
    (Uri.to_string last.uri);
  Alcotest.(check (option string)) "testing: rpc_method" (Some "SendMessage") (T.rpc_method last);
  let unchanged =
    ok "connect" (connect ~clock ~transport:(T.transport agent) base)
  in
  Alcotest.(check string) "default: the card's URL" "http://127.0.0.1:8080/a2a?x=1"
    (Uri.to_string (A2a_client.endpoint unchanged))

let tests =
  [ Alcotest.test_case "relay: the five cases" `Quick test_relay_cases;
    Alcotest.test_case "every wire format" `Quick test_wire_formats;
    Alcotest.test_case "outcome and end" `Quick test_outcome_and_end;
    Alcotest.test_case "close" `Quick test_close;
    Alcotest.test_case "switch release" `Quick test_switch_release;
    Alcotest.test_case "no read-ahead" `Quick test_no_read_ahead;
    Alcotest.test_case "accumulate" `Quick test_accumulate;
    Alcotest.test_case "rewrite_endpoint" `Quick test_rewrite_endpoint ]
