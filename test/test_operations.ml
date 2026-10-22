open A2a_client
open Test_client

let rpc ~clock result =
  Mock.transport ~clock (fun req -> Mock.json_reply (Mock.result_envelope ~id:(Mock.request_id req) (result req)))

let card ?(extra = []) () =
  ok "card"
    (Codec.decode_json Codec.agent_card
       (`Assoc
          ([ ("name", `String "a");
             ("supportedInterfaces",
               `List
                 [ `Assoc
                     [ ("url", `String "http://agent.test/a2a"); ("protocolBinding", `String "JSONRPC");
                       ("protocolVersion", `String "1.0") ] ]) ]
          @ extra))
    |> Result.map_error (fun e -> Error.Invalid_response e))

let test_list_tasks () =
  run @@ fun clock ->
  let transport, rec_ =
    rpc ~clock (fun _ ->
        `Assoc
          [ ("tasks", `List [ task_json "t-2" "WORKING"; task_json "t-1" "COMPLETED" ]);
            ("nextPageToken", `String "cursor-2"); ("pageSize", `Int 2); ("totalSize", `Int 5) ])
  in
  let client = create ~clock ~transport ~tenant:"acme" endpoint in
  let after = Option.get (Ptime.of_date_time ((2025, 11, 9), ((10, 30, 0), 0))) in
  let r =
    ok "list"
      (list_tasks client ~context_id:"ctx-1" ~status:Working ~page_size:2 ~page_token:"cursor-1"
         ~history_length:0 ~status_timestamp_after:after ~include_artifacts:true ())
  in
  Alcotest.(check (list string)) "tasks" [ "t-2"; "t-1" ] (List.map (fun (t : Task.t) -> t.id) r.tasks);
  Alcotest.(check (option string)) "next page" (Some "cursor-2") r.next_page_token;
  Alcotest.(check (pair int int)) "sizes" (2, 5) (r.page_size, r.total_size);
  let req = List.hd rec_.requests in
  Alcotest.(check string) "method" "ListTasks" (meth req);
  Alcotest.(check string) "params"
    {|{"tenant":"acme","contextId":"ctx-1","status":"TASK_STATE_WORKING","pageSize":2,"pageToken":"cursor-1","historyLength":0,"statusTimestampAfter":"2025-11-09T10:30:00.000Z","includeArtifacts":true}|}
    (Yojson.Safe.to_string (params req));
  let transport, _ = rpc ~clock (fun _ -> `Assoc [ ("tasks", `List []) ]) in
  let r = ok "last page" (list_tasks (create ~clock ~transport endpoint) ()) in
  Alcotest.(check (option string)) "absent token is the last page" None r.next_page_token

let push_config_json : Yojson.Safe.t =
  `Assoc
    [ ("id", `String "cfg-1"); ("taskId", `String "t-1"); ("url", `String "https://hook.test/a2a");
      ("token", `String "verify-me");
      ("authentication", `Assoc [ ("scheme", `String "Bearer"); ("credentials", `String "c") ]) ]

let test_push_configs () =
  run @@ fun clock ->
  let transport, rec_ =
    rpc ~clock (fun req ->
        match meth req with
        | "ListTaskPushNotificationConfigs" ->
            `Assoc [ ("configs", `List [ push_config_json ]); ("nextPageToken", `String "") ]
        | "DeleteTaskPushNotificationConfig" -> `Assoc []
        | _ -> push_config_json)
  in
  let client = create ~clock ~transport endpoint in
  let hook =
    Push_notification_config.make ~token:"verify-me"
      ~authentication:(Authentication_info.make ~credentials:"c" "Bearer")
      (Uri.of_string "https://hook.test/a2a")
  in
  let config = Task_push_notification_config.make ~task_id:"t-1" hook in
  let created = ok "create" (create_task_push_notification_config client config) in
  Alcotest.(check (option string)) "assigned id" (Some "cfg-1") created.config.id;
  Alcotest.(check string) "create params"
    {|{"taskId":"t-1","url":"https://hook.test/a2a","token":"verify-me","authentication":{"scheme":"Bearer","credentials":"c"}}|}
    (Yojson.Safe.to_string (params (List.hd rec_.requests)));
  let got = ok "get" (get_task_push_notification_config client ~task_id:"t-1" "cfg-1") in
  Alcotest.(check bool) "get" true (got = created);
  Alcotest.(check string) "get params" {|{"taskId":"t-1","id":"cfg-1"}|}
    (Yojson.Safe.to_string (params (List.hd rec_.requests)));
  let l = ok "list" (list_task_push_notification_configs client ~page_size:10 "t-1") in
  Alcotest.(check int) "listed" 1 (List.length l.configs);
  Alcotest.(check (option string)) "empty token is the last page" None l.next_page_token;
  Alcotest.(check string) "list params" {|{"taskId":"t-1","pageSize":10}|}
    (Yojson.Safe.to_string (params (List.hd rec_.requests)));
  ok "delete" (delete_task_push_notification_config client ~task_id:"t-1" "cfg-1");
  Alcotest.(check string) "delete method" "DeleteTaskPushNotificationConfig" (meth (List.hd rec_.requests));
  let configuration = Send_message_configuration.make ~push_notification_config:hook () in
  ignore (send_message client ~configuration (Message.user_text "x"));
  let inline = member [ "configuration"; "taskPushNotificationConfig" ] (params (List.hd rec_.requests)) in
  Alcotest.(check string) "inline config" "https://hook.test/a2a"
    (Yojson.Safe.Util.to_string (member [ "url" ] inline));
  Alcotest.(check bool) "inline config has no taskId" true
    (Yojson.Safe.Util.member "taskId" inline = `Null);
  let n = List.length rec_.requests in
  let no_push = create ~clock ~transport ~card:(card ()) endpoint in
  create_task_push_notification_config no_push config
  |> expect_error "capability" (function Error.Unsupported_capability _ -> true | _ -> false);
  Alcotest.(check int) "refused locally" n (List.length rec_.requests)

let test_push_configs_v0_3 () =
  run @@ fun clock ->
  let config_v0_3 : Yojson.Safe.t =
    `Assoc
      [ ("taskId", `String "t-1");
        ("pushNotificationConfig",
          `Assoc
            [ ("id", `String "cfg-1"); ("url", `String "https://hook.test/a2a");
              ("authentication", `Assoc [ ("schemes", `List [ `String "Bearer" ]) ]) ]) ]
  in
  let transport, rec_ =
    rpc ~clock (fun req ->
        match meth req with
        | "tasks/pushNotificationConfig/list" -> `List [ config_v0_3 ]
        | "tasks/pushNotificationConfig/delete" -> `Null
        | _ -> config_v0_3)
  in
  let client = create ~clock ~transport ~protocol:V0_3 endpoint in
  let hook =
    Push_notification_config.make ~authentication:(Authentication_info.make "Bearer")
      (Uri.of_string "https://hook.test/a2a")
  in
  let config = Task_push_notification_config.make ~task_id:"t-1" hook in
  let created = ok "set" (create_task_push_notification_config client config) in
  Alcotest.(check (option string)) "id" (Some "cfg-1") created.config.id;
  Alcotest.(check (option string)) "scheme" (Some "Bearer")
    (Option.map (fun (a : Authentication_info.t) -> a.scheme) created.config.authentication);
  let last () = List.hd rec_.requests in
  Alcotest.(check string) "set" "tasks/pushNotificationConfig/set" (meth (last ()));
  Alcotest.(check string) "set params"
    {|{"taskId":"t-1","pushNotificationConfig":{"url":"https://hook.test/a2a","authentication":{"schemes":["Bearer"]}}}|}
    (Yojson.Safe.to_string (params (last ())));
  ignore (ok "get" (get_task_push_notification_config client ~task_id:"t-1" "cfg-1"));
  Alcotest.(check string) "get params" {|{"id":"t-1","pushNotificationConfigId":"cfg-1"}|}
    (Yojson.Safe.to_string (params (last ())));
  let l = ok "list" (list_task_push_notification_configs client "t-1") in
  Alcotest.(check (list string)) "listed" [ "t-1" ]
    (List.map (fun (c : Task_push_notification_config.t) -> c.task_id) l.configs);
  ok "delete" (delete_task_push_notification_config client ~task_id:"t-1" "cfg-1");
  Alcotest.(check string) "delete" "tasks/pushNotificationConfig/delete" (meth (last ()));
  let configuration = Send_message_configuration.make ~push_notification_config:hook () in
  ignore (send_message client ~configuration (Message.user_text "x"));
  Alcotest.(check string) "inline config" "https://hook.test/a2a"
    (Yojson.Safe.Util.to_string
       (member [ "configuration"; "pushNotificationConfig"; "url" ] (params (last ()))));
  let n = List.length rec_.requests in
  list_tasks client ()
  |> expect_error "no ListTasks in 0.3" (function Error.Unsupported_capability _ -> true | _ -> false);
  Alcotest.(check int) "refused locally" n (List.length rec_.requests)

let test_extended_agent_card () =
  run @@ fun clock ->
  let extended : Yojson.Safe.t =
    `Assoc
      [ ("name", `String "a (authenticated)");
        ("supportedInterfaces",
          `List
            [ `Assoc
                [ ("url", `String "http://agent.test/a2a"); ("protocolBinding", `String "JSONRPC");
                  ("protocolVersion", `String "1.0") ] ]);
        ("capabilities", `Assoc [ ("streaming", `Bool true); ("extendedAgentCard", `Bool true) ]) ]
  in
  let transport, rec_ = rpc ~clock (fun _ -> extended) in
  let public = card ~extra:[ ("capabilities", `Assoc [ ("extendedAgentCard", `Bool true) ]) ] () in
  let client = create ~clock ~transport ~auth:(Auth.bearer "tok") ~card:public endpoint in
  let ext = ok "extended" (get_extended_agent_card client ()) in
  Alcotest.(check string) "name" "a (authenticated)" ext.name;
  let req = List.hd rec_.requests in
  Alcotest.(check string) "method" "GetExtendedAgentCard" (meth req);
  Alcotest.(check (option string)) "authenticated" (Some "Bearer tok") (header "authorization" req);
  send_streaming_message client (Message.user_text "x")
  |> expect_error "public card has no streaming" (function Error.Unsupported_capability _ -> true | _ -> false);
  let client = with_agent_card client ext in
  Alcotest.(check bool) "card replaced" true (agent_card client = Some ext);
  let n = List.length rec_.requests in
  get_extended_agent_card (create ~clock ~transport ~card:(card ()) endpoint) ()
  |> expect_error "not declared" (function Error.Unsupported_capability _ -> true | _ -> false);
  Alcotest.(check int) "refused locally" n (List.length rec_.requests);
  let transport, rec_ = rpc ~clock (fun _ -> `Assoc [ ("name", `String "legacy"); ("url", `String "http://x") ]) in
  let ext = ok "0.3" (get_extended_agent_card (create ~clock ~transport ~protocol:V0_3 endpoint) ()) in
  Alcotest.(check string) "0.3 card" "legacy" ext.name;
  let req = Mock.request_json (List.hd rec_.requests) in
  Alcotest.(check string) "0.3 method, no params" "agent/getAuthenticatedExtendedCard"
    (Yojson.Safe.Util.(to_string (member "method" req)));
  Alcotest.(check bool) "no params" true (Yojson.Safe.Util.member "params" req = `Null)

let tests =
  [ ("ListTasks", `Quick, test_list_tasks);
    ("push notification configs", `Quick, test_push_configs);
    ("push notification configs (0.3)", `Quick, test_push_configs_v0_3);
    ("extended Agent Card", `Quick, test_extended_agent_card) ]
