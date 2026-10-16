open A2a_client

let card port =
  Printf.sprintf
    {|{"name":"Test agent","description":"d","version":"1",
       "supportedInterfaces":[{"url":"http://127.0.0.1:%d/rpc","protocolBinding":"JSONRPC","protocolVersion":"1.0"}],
       "capabilities":{"streaming":true},"defaultInputModes":["text/plain"],"defaultOutputModes":["text/plain"],"skills":[]}|}
    port

let task_json id state : Yojson.Safe.t =
  `Assoc
    [ ("id", `String id); ("contextId", `String "c");
      ("status", `Assoc [ ("state", `String ("TASK_STATE_" ^ state)) ]) ]

let stream_body ~clock ~id =
  let ev j = Mock.sse_data (Mock.result_envelope ~id j) in
  let text = ev (`Assoc [ ("task", task_json "t-1" "WORKING") ])
             ^ ev (`Assoc [ ("artifactUpdate",
                             `Assoc [ ("taskId", `String "t-1"); ("contextId", `String "c");
                                      ("artifact", `Assoc [ ("artifactId", `String "a");
                                                            ("parts", `List [ `Assoc [ ("text", `String "streamed") ] ]) ]) ]) ])
             ^ ev (`Assoc [ ("statusUpdate",
                             `Assoc [ ("taskId", `String "t-1"); ("contextId", `String "c");
                                      ("status", `Assoc [ ("state", `String "TASK_STATE_COMPLETED") ]) ]) ])
  in
  let rec split i acc =
    if i >= String.length text then List.rev acc
    else
      let n = min 13 (String.length text - i) in
      split (i + n) (Mock.Sleep 0.002 :: Mock.Chunk (String.sub text i n) :: acc)
  in
  Mock.source ~clock (split 0 [])

let respond_json ?(headers = []) s =
  Cohttp_eio.Server.respond_string
    ~headers:(Http.Header.of_list (("content-type", "application/json") :: headers))
    ~status:`OK ~body:s ()

let handler ~clock ~port ((_conn, req, body) : _ * Http.Request.t * _) =
  match Http.Request.resource req with
  | "/.well-known/agent-card.json" -> respond_json (card port)
  | "/rpc" -> (
      let body = Eio.Buf_read.(parse_exn take_all) body ~max_size:1_000_000 in
      let j = Yojson.Safe.from_string body in
      let str k = match j with `Assoc kvs -> (match List.assoc k kvs with `String s -> s | _ -> "") | _ -> "" in
      let id = str "id" in
      let header = Http.Header.get (Http.Request.headers req) in
      match str "method" with
      | _ when header "a2a-version" <> Some "1.0" -> respond_json (Mock.error_envelope ~id:(`String id) (-32009) "version")
      | "SendMessage" -> respond_json (Mock.result_envelope ~id (`Assoc [ ("task", task_json "t-1" "COMPLETED") ]))
      | "SendStreamingMessage" ->
          Cohttp_eio.Server.respond
            ~headers:(Http.Header.of_list [ ("content-type", "text/event-stream") ])
            ~status:`OK ~body:(stream_body ~clock ~id) ()
      | "SubscribeToTask" ->
          Cohttp_eio.Server.respond
            ~headers:(Http.Header.of_list [ ("content-type", "text/event-stream") ])
            ~status:`OK
            ~body:(Mock.source ~clock
                     [ Mock.Chunk (Mock.sse_data (Mock.result_envelope ~id (`Assoc [ ("task", task_json "t-1" "WORKING") ])));
                       Mock.Block ])
            ()
      | "GetTask" ->
          Eio.Time.Mono.sleep clock 10.;
          respond_json (Mock.result_envelope ~id (task_json "t-1" "WORKING"))
      | _ -> respond_json (Mock.error_envelope ~id:(`String id) (-32601) "Method not found"))
  | _ -> Cohttp_eio.Server.respond_string ~status:`Not_found ~body:"" ()

let listen ~sw net =
  let socket =
    Eio.Net.listen ~sw ~backlog:16 ~reuse_addr:true net (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  (socket, match Eio.Net.listening_addr socket with `Tcp (_, p) -> p | _ -> assert false)

let serve ~sw net callback =
  let socket, port = listen ~sw net in
  let server = Cohttp_eio.Server.make ~callback:(fun conn req body -> callback ~port (conn, req, body)) () in
  Eio.Fiber.fork_daemon ~sw (fun () -> Cohttp_eio.Server.run socket server ~on_error:(fun _ -> ()));
  port

let with_server f =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.mono_clock env and net = Eio.Stdenv.net env in
  Eio.Switch.run @@ fun sw ->
  let port = serve ~sw net (handler ~clock) in
  let transport = Transport.cohttp net in
  f ~clock ~transport (Uri.of_string (Printf.sprintf "http://127.0.0.1:%d" port))

let ok name = function Ok v -> v | Error e -> Alcotest.failf "%s: %s" name (Error.to_string e)

let test_end_to_end () =
  with_server @@ fun ~clock ~transport base ->
  let client = ok "connect" (connect ~clock ~transport base) in
  (match ok "send" (send_text client "hi") with
   | Send_message_response.Task t -> Alcotest.(check bool) "completed" true (Task.is_terminal t)
   | Message _ -> Alcotest.fail "expected task");
  let events = ref 0 in
  match ok "stream" (send_streaming_message client ~on_event:(fun _ -> incr events) (Message.user_text "go")) with
  | Outcome.Completed t ->
      Alcotest.(check int) "events" 3 !events;
      Alcotest.(check string) "artifact" "streamed" (Artifact.text (List.hd t.artifacts))
  | _ -> Alcotest.fail "expected Completed"

let test_timeout_and_cancel () =
  with_server @@ fun ~clock ~transport base ->
  let client = ok "connect" (connect ~clock ~transport ~timeout:0.2 base) in
  (match get_task client "t-1" with
   | Error (Error.Timeout _) -> ()
   | _ -> Alcotest.fail "expected Timeout");
  let got = ref 0 in
  Eio.Fiber.first
    (fun () -> ignore (subscribe_to_task client ~on_event:(fun _ -> incr got) "t-1"))
    (fun () ->
      let rec wait () = if !got = 0 then (Eio.Time.Mono.sleep clock 0.01; wait ()) in
      wait ());
  Alcotest.(check int) "received the first event, then cancelled" 1 !got;
  let dead = create ~clock ~transport (Uri.of_string "http://127.0.0.1:1/rpc") in
  match send_text dead "x" with
  | Error (Error.Transport_error _) -> ()
  | _ -> Alcotest.fail "expected Transport_error"

let test_https_without_tls () =
  Eio_main.run @@ fun env ->
  let client =
    create ~clock:(Eio.Stdenv.mono_clock env) ~transport:(Transport.cohttp (Eio.Stdenv.net env))
      (Uri.of_string "https://user:SECRET@agent.invalid/rpc?token=SECRET")
  in
  match send_text client "x" with
  | Error (Error.Transport_error msg as e) ->
      Alcotest.(check bool) "explains" true (Test_codec.contains ~sub:"TLS" msg);
      Alcotest.(check bool) "no credentials in error" false
        (Test_codec.contains ~sub:"SECRET" (Error.to_string e))
  | _ -> Alcotest.fail "expected Transport_error"

let tests =
  [ ("end to end over sockets", `Quick, test_end_to_end);
    ("timeout and cancellation over sockets", `Quick, test_timeout_and_cancel);
    ("https without TLS wrapper", `Quick, test_https_without_tls) ]
