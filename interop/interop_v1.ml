open A2a_client
open Report

let state (t : Task.t) = Task_state.to_string t.status.state

let webhook ~sw net =
  let received = ref [] in
  let socket = Eio.Net.listen ~sw ~backlog:16 ~reuse_addr:true net (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0)) in
  let port = match Eio.Net.listening_addr socket with `Tcp (_, p) -> p | _ -> assert false in
  let callback _ req body =
    let body = Eio.Buf_read.(parse_exn take_all) body ~max_size:1_000_000 in
    let token = Http.Header.get (Http.Request.headers req) "x-a2a-notification-token" in
    received := (token, body) :: !received;
    Cohttp_eio.Server.respond_string ~status:`OK ~body:"" ()
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      Cohttp_eio.Server.run socket (Cohttp_eio.Server.make ~callback ()) ~on_error:(fun _ -> ()));
  (received, Printf.sprintf "http://127.0.0.1:%d/hook" port)

let run ~clock ~transport ~hook ~hook_url base binding =
  let tag name = Printf.sprintf "[%s] %s" (Protocol_binding.to_string binding) name in
  let check name = check (tag name) in
  let connect ?stream_idle_timeout ?reconnect () =
    match connect ~clock ~transport ~bindings:[ binding ] ?stream_idle_timeout ?reconnect base with
    | Ok c -> c
    | Error e -> failwith ("connect: " ^ err e)
  in
  let client = connect () in
  check "binding selected" (A2a_client.binding client = binding) (Uri.to_string (endpoint client));
  let send ?configuration text = send_message client ?configuration (Message.user_text text) in

  let first =
    match send "work one" with
    | Ok (Task t) ->
        check "SendMessage -> completed" (Task.state t = Completed) (state t);
        Some t
    | Ok (Message _) -> check "SendMessage" false "message"; None
    | Error e -> check "SendMessage" false (err e); None
  in
  ignore (send "work two");

  (match list_tasks client () with
   | Ok r ->
       check "ListTasks"
         (List.exists (fun (t : Task.t) -> Some t.id = Option.map (fun (t : Task.t) -> t.id) first) r.tasks)
         (Printf.sprintf "%d tasks" (List.length r.tasks))
   | Error e -> check "ListTasks" false (err e));
  (match list_tasks client ~page_size:1 () with
   | Ok ({ tasks = [ _ ]; next_page_token = Some next_page_token; _ } as r) -> (
       match list_tasks client ~page_size:1 ~page_token:next_page_token () with
       | Ok r2 ->
           check "ListTasks pagination"
             (match (r.tasks, r2.tasks) with [ a ], [ b ] -> a.id <> b.id | _ -> false)
             (Printf.sprintf "%d tasks on page 2" (List.length r2.tasks))
       | Error e -> check "ListTasks page 2" false (err e))
   | Ok r -> check "ListTasks pagination" false (Printf.sprintf "%d tasks, token %s" (List.length r.tasks) (Option.value r.next_page_token ~default:"none"))
   | Error e -> check "ListTasks pagination" false (err e));
  (match list_tasks client ~status:Completed ~history_length:0 () with
   | Ok r ->
       check "ListTasks status filter"
         (r.tasks <> [] && List.for_all (fun t -> Task.state t = Completed) r.tasks)
         (String.concat "," (List.map state r.tasks))
   | Error e -> check "ListTasks status filter" false (err e));

  (match get_task client "does-not-exist" with
   | Error (Rpc_error { code = Task_not_found; _ }) -> check "GetTask unknown -> TaskNotFound" true ""
   | Ok _ -> check "GetTask unknown" false "found?"
   | Error e -> check "GetTask unknown" false (err e));
  (match first with
   | Some t -> (
       match cancel_task client t.id with
       | Error (Rpc_error { code = Task_not_cancelable; _ }) -> check "CancelTask terminal -> TaskNotCancelable" true ""
       | Ok t -> check "CancelTask terminal" false (state t)
       | Error e -> check "CancelTask terminal" false (err e))
   | None -> ());

  (match send_streaming_message client (Message.user_text "work streamed") with
   | Ok (Outcome.Completed _) -> check "SendStreamingMessage" true ""
   | Ok o -> check "SendStreamingMessage" false (describe o)
   | Error e -> check "SendStreamingMessage" false (err e));

  (match get_extended_agent_card client () with
   | Ok card ->
       check "GetExtendedAgentCard" (card.name = "v1 test agent (extended)" && List.length card.skills = 2) card.name;
       let client = with_agent_card client card in
       check "with_agent_card" ((Option.get (agent_card client)).name = card.name) ""
   | Error e -> check "GetExtendedAgentCard" false (err e));

  let poll = Poll.make ~interval:0.3 () in
  let immediately = Send_message_configuration.make ~return_immediately:true () in
  (match send ~configuration:immediately "slow push" with
   | Ok (Task t) -> (
       let token = "tok-" ^ Protocol_binding.to_string binding in
       let config =
         Task_push_notification_config.make ~task_id:t.id
           (Push_notification_config.make ~token (Uri.of_string hook_url))
       in
       match create_task_push_notification_config client config with
       | Error e -> check "CreateTaskPushNotificationConfig" false (err e)
       | Ok created -> (
           check "CreateTaskPushNotificationConfig" (Uri.to_string created.config.url = hook_url && created.config.id <> None) "";
           let id = Option.value created.config.id ~default:"" in
           (match get_task_push_notification_config client ~task_id:t.id id with
            | Ok c -> check "GetTaskPushNotificationConfig" (Uri.to_string c.config.url = hook_url && c.config.token = Some token) ""
            | Error e -> check "GetTaskPushNotificationConfig" false (err e));
           (match list_task_push_notification_configs client t.id with
            | Ok r -> check "ListTaskPushNotificationConfigs" (List.length r.configs = 1) ""
            | Error e -> check "ListTaskPushNotificationConfigs" false (err e));
           (match wait_for_task client ~poll ~timeout:20. t.id with
            | Ok t' -> check "task completed" (Task.state t' = Completed) (state t')
            | Error e -> check "task completed" false (err e));
           Eio.Time.Mono.sleep clock 0.5;
           let mine = List.filter (fun (tok, _) -> tok = Some token) !hook in
           check "push notifications delivered with the token" (mine <> [])
             (Printf.sprintf "%d received" (List.length !hook));
           (match delete_task_push_notification_config client ~task_id:t.id id with
            | Ok () -> check "DeleteTaskPushNotificationConfig" true ""
            | Error e -> check "DeleteTaskPushNotificationConfig" false (err e));
           match list_task_push_notification_configs client t.id with
           | Ok r -> check "deleted" (r.configs = []) (string_of_int (List.length r.configs))
           | Error e -> check "deleted" false (err e)))
   | Ok _ -> check "push setup" false "no task"
   | Error e -> check "push setup" false (err e));

  let inline_token = "inline-" ^ Protocol_binding.to_string binding in
  let configuration =
    Send_message_configuration.make ~return_immediately:true
      ~push_notification_config:
        (Push_notification_config.make ~token:inline_token (Uri.of_string hook_url))
      ()
  in
  (match send ~configuration "slow inline" with
   | Ok (Task t) ->
       ignore (wait_for_task client ~poll ~timeout:20. t.id);
       Eio.Time.Mono.sleep clock 0.5;
       check "push config sent with the message"
         (List.exists (fun (tok, _) -> tok = Some inline_token) !hook)
         (Printf.sprintf "%d received" (List.length !hook))
   | Ok _ -> check "inline push" false "no task"
   | Error e -> check "inline push" false (err e));

  let resuming = connect ~stream_idle_timeout:1.0 ~reconnect:(Reconnect.make ~delay:0.2 ()) () in
  let snapshots = ref 0 in
  match
    send_streaming_message resuming
      ~on_event:(function Stream_response.Task _ -> incr snapshots | _ -> ())
      (Message.user_text "slow stream")
  with
  | Ok (Outcome.Completed _) ->
      check "stream resumed after idle timeouts" (!snapshots > 1)
        (Printf.sprintf "%d task snapshots" !snapshots)
  | Ok o -> check "stream resumed" false (describe o)
  | Error e -> check "stream resumed" false (err e)

let () =
  let base = if Array.length Sys.argv > 1 then Sys.argv.(1) else "http://127.0.0.1:9995" in
  Eio_main.run (fun env ->
      Eio.Switch.run @@ fun sw ->
      let net = Eio.Stdenv.net env and clock = Eio.Stdenv.mono_clock env in
      let hook, hook_url = webhook ~sw net in
      let transport = Transport.pooled ~sw ~clock net in
      List.iter
        (run ~clock ~transport ~hook ~hook_url (Uri.of_string base))
        Protocol_binding.[ Jsonrpc; Http_json ]);
  finish ()
