open Types
include Conn

let protocol_version = Protocol_version.(to_string V1_0)

let send_message_request t ?tenant ?configuration ?metadata message =
  { Send_message_request.tenant = with_tenant t tenant; message; configuration; metadata }

let send_message t ?tenant ?configuration ?metadata message =
  let req = send_message_request t ?tenant ?configuration ?metadata message in
  call t t.wire.send_message req

let send_text t ?context_id ?task_id ?configuration ?metadata text =
  send_message t ?configuration ?metadata (Message.user_text ?context_id ?task_id text)

let list_tasks t ?tenant ?context_id ?status ?page_size ?page_token ?history_length
    ?status_timestamp_after ?include_artifacts () =
  let* op = optional t "ListTasks" t.wire.list_tasks in
  call t op
    (List_tasks_request.make ?tenant:(with_tenant t tenant) ?context_id ?status ?page_size
       ?page_token ?history_length ?status_timestamp_after ?include_artifacts ())

let cancel_task t ?tenant ?metadata id =
  let req = { Cancel_task_request.tenant = with_tenant t tenant; id; metadata } in
  call t t.wire.cancel_task req

let push_notifications t =
  require_capability t "push notification support" (fun c -> c.capabilities.push_notifications)

let create_task_push_notification_config t (config : Task_push_notification_config.t) =
  let* () = push_notifications t in
  call t t.wire.create_push_config { config with tenant = with_tenant t config.tenant }

let get_task_push_notification_config t ?tenant ~task_id id =
  let* () = push_notifications t in
  call t t.wire.get_push_config
    { Task_push_notification_config_request.tenant = with_tenant t tenant; task_id; id }

let list_task_push_notification_configs t ?tenant ?page_size ?page_token task_id =
  let* () = push_notifications t in
  call t t.wire.list_push_configs
    { List_task_push_notification_configs_request.tenant = with_tenant t tenant; task_id;
      page_size; page_token }

let delete_task_push_notification_config t ?tenant ~task_id id =
  let* () = push_notifications t in
  call t t.wire.delete_push_config
    { Task_push_notification_config_request.tenant = with_tenant t tenant; task_id; id }

let get_extended_agent_card t ?tenant () =
  let* () =
    require_capability t "an extended Agent Card" (fun c -> c.capabilities.extended_agent_card)
  in
  call t t.wire.get_extended_agent_card { Get_extended_agent_card_request.tenant = with_tenant t tenant }

module Event_stream = Streaming.Event_stream

let send_streaming_message t ?tenant ?configuration ?metadata ?(accumulate = true)
    ?(on_event = ignore) message =
  let req = send_message_request t ?tenant ?configuration ?metadata message in
  Streaming.run t ?tenant ~accumulate t.wire.send_streaming_message req ~on_event

let subscribe_to_task t ?tenant ?(accumulate = true) ?(on_event = ignore) id =
  let req = { Subscribe_to_task_request.tenant = with_tenant t tenant; id } in
  Streaming.run t ?tenant ~accumulate t.wire.subscribe_to_task req ~on_event

let open_streaming_message t ~sw ?tenant ?configuration ?metadata ?(accumulate = true) message =
  let req = send_message_request t ?tenant ?configuration ?metadata message in
  Event_stream.open_ ~sw (Streaming.run t ?tenant ~accumulate t.wire.send_streaming_message req)

let open_task_subscription t ~sw ?tenant ?(accumulate = true) id =
  let req = { Subscribe_to_task_request.tenant = with_tenant t tenant; id } in
  Event_stream.open_ ~sw (Streaming.run t ?tenant ~accumulate t.wire.subscribe_to_task req)

let poll_task ~clock (policy : Poll.t) ~last fetch =
  let rec loop delay =
    let* task = fetch () in
    last := Some task;
    if Task_state.is_active task.Task.status.state then begin
      Eio.Time.Mono.sleep clock delay;
      loop (Float.min policy.max_interval (delay *. policy.backoff))
    end
    else Ok task
  in
  loop policy.interval

(* Run [f] for at most [timeout] seconds; on expiry, report the last task
   [f] saw. *)
let with_poll_timeout t ~timeout f =
  let last = ref None in
  match Eio.Time.Timeout.run (Eio.Time.Timeout.seconds t.clock timeout) (fun () -> Ok (f ~last)) with
  | Ok r -> r
  | Error `Timeout -> Error (Error.Poll_timeout { last_task = !last })

let wait_for_task t ?tenant ?history_length ?(poll = Poll.default) ~timeout id =
  with_poll_timeout t ~timeout @@ fun ~last ->
  poll_task ~clock:t.clock poll ~last (fun () -> get_task t ?tenant ?history_length id)

let send_message_and_wait t ?tenant ?configuration ?metadata ?history_length
    ?(poll = Poll.default) ~timeout message =
  with_poll_timeout t ~timeout @@ fun ~last ->
  let* resp = send_message t ?tenant ?configuration ?metadata message in
  match resp with
  | Send_message_response.Message m -> Ok (Lifecycle.Outcome.Message m)
  | Task task when not (Task_state.is_active task.status.state) ->
      Ok (Lifecycle.Outcome.of_task task)
  | Task task ->
      last := Some task;
      let* task =
        poll_task ~clock:t.clock poll ~last (fun () -> get_task t ?tenant ?history_length task.id)
      in
      Ok (Lifecycle.Outcome.of_task task)

let well_known_path = "/.well-known/agent-card.json"

let agent_card_uri base =
  let path = Uri.path base in
  if Filename.check_suffix path ".json" then base
  else
    Uri.with_path base (strip_trailing_slash path ^ well_known_path)

let fetch_agent_card ?(auth = Auth.none) ?(headers = []) ?(timeout = default_timeout)
    ?(max_response_size = default_max_response_size) ~clock ~transport base =
  let clock = (clock :> Eio.Time.Mono.ty Eio.Resource.t) in
  let uri = agent_card_uri base in
  Log.debug (fun m -> m "GET %s" (redact_uri uri));
  with_timeout clock (Some timeout) "fetching Agent Card" @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let req =
    { Transport.meth = `GET; uri;
      headers = [ ("Accept", "application/json"); ("A2A-Version", protocol_version) ] @ headers @ auth ();
      body = None }
  in
  let* resp = send transport ~sw "fetching Agent Card" req in
  let* body = read_all ~limit:max_response_size resp.body in
  Codec.decode_string Codec.agent_card body
  |> Result.map_error (fun msg -> Error.Invalid_response ("Agent Card " ^ msg))

let default_bindings = Protocol_binding.[ Jsonrpc; Http_json ]

let select ?protocol_version ?(bindings = default_bindings) (card : Agent_card.t) =
  let wanted = match protocol_version with Some v -> [ v ] | None -> Protocol_version.supported in
  let usable v (i : Agent_interface.t) =
    match (i.protocol_version, i.protocol_binding) with
    | Known iv, Known b when iv = v && List.mem b bindings ->
        Option.map (fun p -> (i, p)) (Protocol.make v b)
    | _ -> None
  in
  match List.find_map (fun v -> List.find_map (usable v) card.supported_interfaces) wanted with
  | Some found -> Ok found
  | None ->
      let show to_string = function Known x -> to_string x | Unknown s -> s in
      let offered =
        card.supported_interfaces
        |> List.map (fun (i : Agent_interface.t) ->
               Printf.sprintf "%s %s"
                 (show Protocol_binding.to_string i.protocol_binding)
                 (show Protocol_version.to_string i.protocol_version))
        |> String.concat ", "
      in
      let needed v =
        let bs = List.filter (fun b -> Protocol.make v b <> None) bindings in
        Printf.sprintf "%s with protocol %s.x"
          (String.concat " or " (List.map Protocol_binding.to_string bs))
          (Protocol_version.to_string v)
      in
      Error
        (Error.No_compatible_interface
           (Printf.sprintf "need %s; agent offers [%s]"
              (String.concat ", or " (List.map needed wanted))
              offered))

let select_interface ?protocol_version ?bindings card =
  Result.map fst (select ?protocol_version ?bindings card)

let rebase_endpoint ~onto url =
  let url = Uri.with_scheme url (Uri.scheme onto) in
  let url = Uri.with_host url (Uri.host onto) in
  Uri.with_port url (Uri.port onto)

let of_agent_card ?auth ?headers ?extensions ?timeout ?stream_idle_timeout
    ?max_response_size ?reconnect ?protocol_version ?bindings ?(rewrite_endpoint = Fun.id)
    ~clock ~transport (card : Agent_card.t) =
  let* iface, protocol = select ?protocol_version ?bindings card in
  let endpoint = rewrite_endpoint iface.url in
  Log.debug (fun m -> m "using %a at %s" Protocol.pp protocol (redact_uri endpoint));
  Ok
    (create ?auth ?headers ?tenant:iface.tenant ?extensions ?timeout ?stream_idle_timeout
       ?max_response_size ?reconnect ~card ~protocol ~clock ~transport endpoint)

let connect ?auth ?headers ?extensions ?timeout ?stream_idle_timeout ?max_response_size
    ?reconnect ?protocol_version ?bindings ?rewrite_endpoint ~clock ~transport base =
  let* card = fetch_agent_card ?auth ?headers ?timeout ?max_response_size ~clock ~transport base in
  of_agent_card ?auth ?headers ?extensions ?timeout ?stream_idle_timeout ?max_response_size
    ?reconnect ?protocol_version ?bindings ?rewrite_endpoint ~clock ~transport card
