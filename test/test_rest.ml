open A2a_client
open Test_client

let base = Uri.of_string "http://agent.test/a2a/rest/"

let rest_client ?card ?tenant ~clock transport =
  create ~clock ~transport ~binding:Http_json ?card ?tenant base

let body req = Mock.request_json req

let a2a_error ~status reason message =
  Mock.json_reply ~status
    (Yojson.Safe.to_string
       (`Assoc
          [ ("error",
              `Assoc
                [ ("code", `Int status); ("status", `String "NOT_FOUND"); ("message", `String message);
                  ("details",
                    `List
                      [ `Assoc
                          [ ("@type", `String "type.googleapis.com/google.rpc.ErrorInfo");
                            ("reason", `String reason); ("domain", `String "a2a-protocol.org") ] ]) ]) ]))

let test_routes () =
  run @@ fun clock ->
  let transport, rec_ =
    Mock.transport ~clock (fun req ->
        match (req.meth, Uri.path req.uri) with
        | `POST, p when String.ends_with ~suffix:"/message:send" p ->
            Mock.json_reply (Yojson.Safe.to_string (`Assoc [ ("task", task_json "t/1" "COMPLETED") ]))
        | `GET, "/a2a/rest/tasks" ->
            Mock.json_reply {|{"tasks":[],"nextPageToken":"","pageSize":0,"totalSize":0}|}
        | `DELETE, _ -> Mock.reply ~headers:[] []
        | _ -> Mock.json_reply (Yojson.Safe.to_string (task_json "t/1" "CANCELED")))
  in
  let client = rest_client ~clock ~tenant:"acme" transport in
  let last () = List.hd rec_.requests in
  let path () = Uri.path (last ()).uri in
  let query () = Uri.query (last ()).uri in
  (match ok "send" (send_text client "hi") with
   | Task t -> Alcotest.(check string) "task" "t/1" t.id
   | Message _ -> Alcotest.fail "expected task");
  Alcotest.(check string) "tenant prefix" "/a2a/rest/acme/message:send" (path ());
  Alcotest.(check (option string)) "content type" (Some "application/a2a+json")
    (header "content-type" (last ()));
  Alcotest.(check (option string)) "A2A-Version" (Some "1.0") (header "a2a-version" (last ()));
  Alcotest.(check string) "body is the request" "hi"
    (Yojson.Safe.Util.(to_string (member "text" (List.hd (to_list (member "parts" (member "message" (body (last ())))))))));
  let client = rest_client ~clock transport in
  ignore (ok "send" (send_text client "hi"));
  Alcotest.(check string) "no tenant" "/a2a/rest/message:send" (path ());
  ignore (ok "get" (get_task client ~history_length:3 "t/1"));
  Alcotest.(check bool) "GET" true ((last ()).meth = `GET);
  Alcotest.(check string) "id in path, escaped" "/a2a/rest/tasks/t%2F1" (Uri.path (last ()).uri);
  Alcotest.(check (list (pair string (list string)))) "query" [ ("historyLength", [ "3" ]) ] (query ());
  Alcotest.(check (option string)) "no body" None (last ()).body;
  Alcotest.(check (option string)) "no content type without body" None (header "content-type" (last ()));
  ignore (ok "list" (list_tasks client ~status:Working ~include_artifacts:false ~page_size:5 ()));
  Alcotest.(check (list (pair string (list string)))) "list query"
    [ ("status", [ "TASK_STATE_WORKING" ]); ("pageSize", [ "5" ]); ("includeArtifacts", [ "false" ]) ]
    (query ());
  ignore (ok "cancel" (cancel_task client "t/1"));
  Alcotest.(check string) "cancel" "/a2a/rest/tasks/t%2F1:cancel" (Uri.path (last ()).uri);
  Alcotest.(check bool) "POST" true ((last ()).meth = `POST);
  ok "delete" (delete_task_push_notification_config client ~task_id:"t/1" "c 1");
  Alcotest.(check bool) "DELETE" true ((last ()).meth = `DELETE);
  Alcotest.(check string) "push config path" "/a2a/rest/tasks/t%2F1/pushNotificationConfigs/c%201"
    (Uri.path (last ()).uri);
  Alcotest.(check (list (pair string (list string)))) "path params are not repeated" [] (query ())

let test_errors () =
  run @@ fun clock ->
  let transport, _ =
    Mock.transport ~clock (fun req ->
        match Uri.path req.uri with
        | "/a2a/rest/tasks/missing" -> a2a_error ~status:404 "TASK_NOT_FOUND" "no such task"
        | "/a2a/rest/tasks/done:cancel" -> a2a_error ~status:400 "TASK_NOT_CANCELABLE" "done"
        | "/a2a/rest/tasks/odd" -> a2a_error ~status:400 "SOMETHING_NEW" "?"
        | _ -> Mock.json_reply ~status:502 "<html>bad gateway</html>")
  in
  let client = rest_client ~clock transport in
  (match get_task client "missing" with
   | Error (Error.Rpc_error { code = Task_not_found; message; details }) ->
       Alcotest.(check string) "message" "no such task" message;
       Alcotest.(check bool) "details kept" true (details <> [])
   | r -> Alcotest.failf "expected Task_not_found, got %s" (match r with Ok _ -> "Ok" | Error e -> Error.to_string e));
  cancel_task client "done"
  |> expect_error "not cancelable" (function
       | Error.Rpc_error { code = Task_not_cancelable; _ } -> true
       | _ -> false);
  get_task client "odd"
  |> expect_error "unknown reason" (function
       | Error.Rpc_error { code = Other 400; _ } -> true
       | _ -> false);
  get_task client "x"
  |> expect_error "not an A2A error" (function
       | Error.Http_error { status = 502; body } -> body = "<html>bad gateway</html>"
       | _ -> false)

let test_streaming () =
  run @@ fun clock ->
  let ev j = Mock.sse_data (Yojson.Safe.to_string j) in
  let transport, rec_ =
    Mock.transport ~clock (fun req ->
        match Uri.path req.uri with
        | "/a2a/rest/message:stream" ->
            Mock.sse_reply
              [ Mock.Chunk (ev (`Assoc [ ("task", task_json "t-1" "WORKING") ]));
                Mock.Chunk
                  (ev
                     (`Assoc
                        [ ("statusUpdate",
                            `Assoc
                              [ ("taskId", `String "t-1"); ("contextId", `String "ctx-1");
                                ("status", `Assoc [ ("state", `String "TASK_STATE_COMPLETED") ]) ]) ])) ]
        | _ ->
            Mock.sse_reply
              [ Mock.Chunk
                  ("event: error\n"
                  ^ ev
                      (`Assoc
                         [ ("error",
                             `Assoc
                               [ ("code", `Int 400); ("message", `String "terminal");
                                 ("details",
                                   `List
                                     [ `Assoc
                                         [ ("@type", `String "type.googleapis.com/google.rpc.ErrorInfo");
                                           ("reason", `String "UNSUPPORTED_OPERATION") ] ]) ]) ])) ])
  in
  let client = rest_client ~clock transport in
  (match send_streaming_message client (Message.user_text "go") with
   | Ok (Outcome.Completed t) -> Alcotest.(check string) "task" "t-1" t.id
   | _ -> Alcotest.fail "expected Completed");
  let req = List.hd rec_.requests in
  Alcotest.(check (option string)) "accept" (Some "text/event-stream") (header "accept" req);
  subscribe_to_task client "t-1"
  |> expect_error "error event" (function
       | Error.Rpc_error { code = Unsupported_operation; message = "terminal"; _ } -> true
       | _ -> false);
  Alcotest.(check string) "subscribe path" "/a2a/rest/tasks/t-1:subscribe"
    (Uri.path (List.hd rec_.requests).uri)

let interface binding version : Yojson.Safe.t =
  `Assoc
    [ ("url", `String ("http://agent.test/" ^ binding ^ version)); ("protocolBinding", `String binding);
      ("protocolVersion", `String version) ]

let card interfaces =
  match Codec.decode_json Codec.agent_card (`Assoc [ ("name", `String "a"); ("supportedInterfaces", `List interfaces) ]) with
  | Ok c -> c
  | Error e -> Alcotest.fail e

let test_selection () =
  let pick ?bindings ifaces =
    match select_interface ?bindings (card ifaces) with
    | Ok i -> i.url
    | Error e -> "error: " ^ Error.to_string e
  in
  Alcotest.(check string) "agent order" "http://agent.test/HTTP+JSON1.0"
    (pick [ interface "HTTP+JSON" "1.0"; interface "JSONRPC" "1.0" ]);
  Alcotest.(check string) "restricted" "http://agent.test/JSONRPC1.0"
    (pick ~bindings:[ Jsonrpc ] [ interface "HTTP+JSON" "1.0"; interface "JSONRPC" "1.0" ]);
  Alcotest.(check string) "newer version first" "http://agent.test/HTTP+JSON1.0"
    (pick [ interface "JSONRPC" "0.3"; interface "HTTP+JSON" "1.0" ]);
  Alcotest.(check string) "no REST with 0.3" "http://agent.test/JSONRPC0.3"
    (pick [ interface "HTTP+JSON" "0.3"; interface "JSONRPC" "0.3" ]);
  Alcotest.(check bool) "nothing usable" true
    (String.starts_with ~prefix:"error" (pick [ interface "HTTP+JSON" "0.3"; interface "GRPC" "1.0" ]));
  run @@ fun clock ->
  let transport, _ = Mock.transport ~clock (fun _ -> Mock.json_reply "{}") in
  match
    of_agent_card ~clock ~transport (card [ interface "HTTP+JSON" "1.0"; interface "JSONRPC" "1.0" ])
  with
  | Ok c -> Alcotest.(check bool) "client binding" true (binding c = Http_json)
  | Error e -> Alcotest.fail (Error.to_string e)

let tests =
  [ ("routes", `Quick, test_routes); ("errors", `Quick, test_errors);
    ("streaming", `Quick, test_streaming); ("interface selection", `Quick, test_selection) ]
