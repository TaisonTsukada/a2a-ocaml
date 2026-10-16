open Types

let src = Logs.Src.create "a2a-client" ~doc:"A2A protocol client"

module Log = (val Logs.src_log src : Logs.LOG)

let ( let* ) = Result.bind
let protocol_version = Protocol_version.(to_string V1_0)

module Auth = struct
  type t = unit -> (string * string) list

  let none : t = fun () -> []
  let bearer token : t = fun () -> [ ("Authorization", "Bearer " ^ token) ]
  let header name value : t = fun () -> [ (name, value) ]
  let headers hs : t = fun () -> hs
  let dynamic (f : unit -> (string * string) list) : t = f
end

module Reconnect = struct
  type t = { max_attempts : int; delay : float; max_delay : float; backoff : float }

  let none = { max_attempts = 0; delay = 1.0; max_delay = 30.0; backoff = 2.0 }

  let make ?(max_attempts = 5) ?(delay = 1.0) ?(max_delay = 30.0) ?(backoff = 2.0) () =
    if max_attempts < 0 || delay < 0. || backoff < 1. then
      invalid_arg "Reconnect.make: need max_attempts >= 0, delay >= 0 and backoff >= 1";
    { max_attempts; delay; max_delay; backoff }
end

type t = {
  transport : Transport.t;
  clock : Eio.Time.Mono.ty Eio.Resource.t;
  endpoint : Uri.t;
  tenant : string option;
  auth : Auth.t;
  headers : (string * string) list;
  extensions : string list;
  timeout : float option;
  stream_idle_timeout : float option;
  max_response_size : int;
  reconnect : Reconnect.t;
  card : Agent_card.t option;
  wire : Wire.t;
}

let default_timeout = 30.0
let default_max_response_size = 16 * 1024 * 1024

let create ?(auth = Auth.none) ?(headers = []) ?tenant ?(extensions = [])
    ?(timeout = default_timeout) ?stream_idle_timeout
    ?(max_response_size = default_max_response_size) ?(reconnect = Reconnect.none) ?card
    ?(protocol_version = Protocol_version.V1_0) ?(binding = Protocol_binding.Jsonrpc) ~clock
    ~transport endpoint =
  let timeout = Some timeout in
  { transport; clock = (clock :> Eio.Time.Mono.ty Eio.Resource.t); endpoint;
    tenant; auth; headers; extensions; timeout; stream_idle_timeout;
    max_response_size; reconnect; card; wire = Wire.make protocol_version binding }

let endpoint t = t.endpoint
let agent_card t = t.card
let with_agent_card t card = { t with card = Some card }
let version t = t.wire.version
let binding t = t.wire.binding

let redact_uri u = Uri.with_query (Uri.with_userinfo u None) [] |> Uri.to_string

let guard what f =
  match f () with
  | v -> Ok v
  | exception (Eio.Cancel.Cancelled _ as e) -> raise e
  | exception e -> Error (Error.Transport_error (what ^ ": " ^ Printexc.to_string e))

let with_timeout clock secs what f =
  match secs with
  | None -> f ()
  | Some s when s = Float.infinity -> f ()
  | Some s -> (
      match Eio.Time.Timeout.run (Eio.Time.Timeout.seconds clock s) (fun () -> Ok (f ())) with
      | Ok r -> r
      | Error `Timeout -> Error (Error.Timeout (Printf.sprintf "%s (%gs)" what s)))

let read_buffer_size = 16 * 1024

let read_all ~limit (body : Eio.Flow.source_ty Eio.Resource.t) =
  let buf = Buffer.create 4096 in
  let cs = Cstruct.create read_buffer_size in
  let rec loop () =
    match Eio.Flow.single_read body cs with
    | n ->
        if Buffer.length buf + n > limit then
          Error (Error.Invalid_response (Printf.sprintf "response body exceeds %d bytes" limit))
        else begin
          Buffer.add_string buf (Cstruct.to_string ~len:n cs);
          loop ()
        end
    | exception End_of_file -> Ok (Buffer.contents buf)
  in
  Result.join (guard "reading response body" loop)

let excerpt_limit = 1024
let error_body_limit = 64 * 1024

let excerpt (resp : Transport.response) =
  let cs = Cstruct.create excerpt_limit in
  match Eio.Flow.single_read resp.body cs with
  | n -> Cstruct.to_string ~len:n cs
  | exception (Eio.Cancel.Cancelled _ as e) -> raise e
  | exception _ -> ""

let http_error ?error_of_body (resp : Transport.response) =
  let fallback body = Error.Http_error { status = resp.status; body } in
  match error_of_body with
  | None -> fallback (excerpt resp)
  | Some parse -> (
      match read_all ~limit:error_body_limit resp.body with
      | Error _ -> fallback ""
      | Ok body -> (
          match parse body with
          | Some e -> e
          | None ->
              fallback
                (if String.length body > excerpt_limit then String.sub body 0 excerpt_limit
                 else body)))

let is_success status = status >= 200 && status < 300

let send ?error_of_body (transport : Transport.t) ~sw what req =
  let* resp = guard what (fun () -> transport ~sw req) in
  if is_success resp.status then Ok resp else Error (http_error ?error_of_body resp)

let strip_trailing_slash path =
  if String.ends_with ~suffix:"/" path then String.sub path 0 (String.length path - 1) else path

let request_headers t ~accept (r : _ Op.request) =
  let extensions =
    match t.extensions with
    | [] -> []
    | l ->
        let v = String.concat "," l in
        List.map (fun name -> (name, v)) t.wire.extension_headers
  in
  (match r.body with Some _ -> [ ("Content-Type", r.content_type) ] | None -> [])
  @ [ ("Accept", accept); ("A2A-Version", Protocol_version.to_string t.wire.version) ]
  @ extensions @ t.headers @ t.auth ()

let http_request t (r : _ Op.request) ~accept ~extra_headers =
  let uri =
    if r.path = "" then t.endpoint
    else Uri.with_path t.endpoint (strip_trailing_slash (Uri.path t.endpoint) ^ r.path)
  in
  let uri = if r.query = [] then uri else Uri.add_query_params' uri r.query in
  { Transport.meth = r.meth; uri;
    headers = request_headers t ~accept r @ extra_headers;
    body = r.body }

let request_id (r : _ Op.request) = Option.value r.id ~default:"-"

let call t (op : _ Op.t) req =
  let r = op.prepare req in
  let id = request_id r in
  Log.debug (fun m -> m "%s -> %s (id %s)" op.name (redact_uri t.endpoint) id);
  let result =
    with_timeout t.clock t.timeout op.name @@ fun () ->
    Eio.Switch.run @@ fun sw ->
    let req = http_request t r ~accept:r.accept ~extra_headers:[] in
    let* resp = send ?error_of_body:r.error_of_body t.transport ~sw "sending request" req in
    let* body = read_all ~limit:t.max_response_size resp.body in
    r.decode body
  in
  (match result with
   | Ok _ -> Log.debug (fun m -> m "%s <- ok (id %s)" op.name id)
   | Error e -> Log.info (fun m -> m "%s failed (id %s): %a" op.name id Error.pp e));
  result

let optional t what = function
  | Some op -> Ok op
  | None ->
      Error
        (Error.Unsupported_capability
           (Printf.sprintf "%s is not part of protocol %s" what
              (Protocol_version.to_string t.wire.version)))

let require_capability t what declared =
  match t.card with
  | Some card when declared card <> Some true ->
      Error (Error.Unsupported_capability (Printf.sprintf "the Agent Card does not declare %s" what))
  | _ -> Ok ()

let with_tenant t = function Some _ as x -> x | None -> t.tenant

let send_message_request t ?tenant ?configuration ?metadata message =
  { Send_message_request.tenant = with_tenant t tenant; message; configuration; metadata }

let send_message t ?tenant ?configuration ?metadata message =
  let req = send_message_request t ?tenant ?configuration ?metadata message in
  call t t.wire.send_message req

let send_text t ?context_id ?task_id ?configuration ?metadata text =
  send_message t ?configuration ?metadata (Message.user_text ?context_id ?task_id text)

let get_task t ?tenant ?history_length id =
  let req = { Get_task_request.tenant = with_tenant t tenant; id; history_length } in
  call t t.wire.get_task req

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

type stream_state = {
  mutable task : Task.t option;
  mutable message : Message.t option;
  mutable last_event_id : string option;
  mutable retry : float option;
  mutable events : int;
}

let settled st =
  match (st.task, st.message) with
  | Some task, _ -> not (Task_state.is_active task.status.state)
  | None, Some _ -> true
  | None, None -> false

let outcome st =
  match (st.task, st.message) with
  | Some task, _ -> Lifecycle.Outcome.of_task task
  | None, Some m -> Lifecycle.Outcome.Message m
  | None, None -> assert false

let finished st =
  match (st.task, st.message) with
  | Some task, _ -> Task_state.is_terminal task.status.state
  | None, Some _ -> true
  | None, None -> false

let deliver st ~on_event ev =
  st.task <- Lifecycle.apply st.task ev;
  (match ev with
   | Stream_response.Message m when st.message = None -> st.message <- Some m
   | _ -> ());
  st.events <- st.events + 1;
  on_event ev

let ended st = Error (Error.Stream_ended { last_task = st.task })

let stream_once t (op : _ Op.t) req ~st ~on_event =
  let r = op.prepare req in
  let id = request_id r in
  Log.debug (fun m -> m "%s -> %s (id %s, streaming)" op.name (redact_uri t.endpoint) id);
  Eio.Switch.run @@ fun sw ->
  let extra_headers =
    ("Cache-Control", "no-store")
    :: (match st.last_event_id with Some i -> [ ("Last-Event-ID", i) ] | None -> [])
  in
  let req = http_request t r ~accept:"text/event-stream" ~extra_headers in
  let* resp =
    with_timeout t.clock t.timeout (op.name ^ " response") @@ fun () ->
    let* resp = send ?error_of_body:r.error_of_body t.transport ~sw "sending request" req in
    match Transport.media_type resp.headers with
      | Some "text/event-stream" -> Ok (`Stream resp)
      | _ ->
          let* body = read_all ~limit:t.max_response_size resp.body in
          Ok (`Single body)
  in
  match resp with
  | `Stream resp ->
      let parser = Sse.create ~max_event_size:t.max_response_size () in
      let cs = Cstruct.create read_buffer_size in
      let read_chunk () =
        with_timeout t.clock t.stream_idle_timeout "waiting for stream data" @@ fun () ->
        guard "reading stream" @@ fun () ->
        match Eio.Flow.single_read resp.body cs with
        | n -> Some (Cstruct.to_string ~len:n cs)
        | exception End_of_file -> None
      in
      let rec handle_events = function
        | [] -> Ok `Continue
        | ({ event_type = Some typ; _ } : Sse.event) :: rest when typ <> "message" && typ <> "error" ->
            Log.debug (fun m -> m "%s: ignoring SSE event of type %S" op.name typ);
            handle_events rest
        | (ev : Sse.event) :: rest ->
            if ev.id <> None then st.last_event_id <- ev.id;
            Option.iter (fun ms -> st.retry <- Some (float_of_int ms /. 1000.)) ev.retry;
            let* sr = r.decode ev.data in
            deliver st ~on_event sr;
            if finished st then Ok `Done else handle_events rest
      in
      let rec loop () =
        let* chunk = read_chunk () in
        match chunk with
        | None -> if settled st then Ok (outcome st) else ended st
        | Some chunk -> (
            match Sse.feed parser chunk with
            | Error (`Event_too_large n) ->
                Error (Error.Invalid_response (Printf.sprintf "SSE event exceeds %d bytes" n))
            | Ok events -> (
                let* r = handle_events events in
                match r with
                | `Done -> Ok (outcome st)
                | `Continue -> loop ()))
      in
      let r = loop () in
      Log.debug (fun m -> m "%s stream closed (id %s)" op.name id);
      r
  | `Single body ->
      let* sr = r.decode body in
      deliver st ~on_event sr;
      if settled st then Ok (outcome st) else ended st

let resumable = function
  | Error.Stream_ended _ | Transport_error _ | Timeout _ -> true
  | _ -> false

let stream t ?tenant (op : _ Op.t) req ~on_event : (Lifecycle.Outcome.t, Error.t) result =
  let* () = require_capability t "streaming support" (fun c -> c.capabilities.streaming) in
  let st = { task = None; message = None; last_event_id = None; retry = None; events = 0 } in
  let policy = t.reconnect in
  let resync task_id =
    let* task = get_task t ?tenant task_id in
    deliver st ~on_event (Stream_response.Task task);
    if settled st then Ok (outcome st) else ended st
  in
  let subscribable = ref true in
  let resume task_id =
    if not !subscribable then (resync task_id, false)
    else
      let before = st.events in
      match
        stream_once t t.wire.subscribe_to_task
          { Subscribe_to_task_request.tenant = with_tenant t tenant; id = task_id } ~st ~on_event
      with
      | Error (Error.Rpc_error { code = Unsupported_operation; _ }) ->
          subscribable := false;
          (resync task_id, false)
      | r -> (r, st.events > before)
  in
  let rec retry ~attempt ~delay result =
    match (result, st.task) with
    | Error e, Some task when resumable e && attempt < policy.Reconnect.max_attempts ->
        let wait = Float.max delay (Option.value st.retry ~default:0.) in
        Log.info (fun m ->
            m "stream for task %s interrupted (%a); reconnecting in %gs (%d/%d)" task.id Error.pp e
              wait (attempt + 1) policy.max_attempts);
        Eio.Time.Mono.sleep t.clock wait;
        let result, progressed = resume task.id in
        let attempt, delay =
          if progressed then (0, policy.delay)
          else (attempt + 1, Float.min policy.max_delay (delay *. policy.backoff))
        in
        retry ~attempt ~delay result
    | _ -> result
  in
  retry ~attempt:0 ~delay:policy.delay (stream_once t op req ~st ~on_event)

let send_streaming_message t ?tenant ?configuration ?metadata ?(on_event = ignore) message =
  let req = send_message_request t ?tenant ?configuration ?metadata message in
  stream t ?tenant t.wire.send_streaming_message req ~on_event

let subscribe_to_task t ?tenant ?(on_event = ignore) id =
  let req = { Subscribe_to_task_request.tenant = with_tenant t tenant; id } in
  stream t ?tenant t.wire.subscribe_to_task req ~on_event

let poll ~clock ~interval ~max_interval ~backoff ~last fetch =
  let rec loop delay =
    let* task = fetch () in
    last := Some task;
    if Task_state.is_active task.Task.status.state then begin
      Eio.Time.Mono.sleep clock delay;
      loop (Float.min max_interval (delay *. backoff))
    end
    else Ok task
  in
  loop interval

let wait_for_task t ?tenant ?history_length ?(interval = 1.0) ?(max_interval = 10.0)
    ?(backoff = 1.5) ~timeout id =
  if interval <= 0. || backoff < 1. then invalid_arg "wait_for_task: need interval > 0 and backoff >= 1";
  let last = ref None in
  match
    Eio.Time.Timeout.run (Eio.Time.Timeout.seconds t.clock timeout) @@ fun () ->
    Ok (poll ~clock:t.clock ~interval ~max_interval ~backoff ~last
          (fun () -> get_task t ?tenant ?history_length id))
  with
  | Ok r -> r
  | Error `Timeout -> Error (Error.Poll_timeout { last_task = !last })

let send_message_and_wait t ?tenant ?configuration ?metadata ?history_length
    ?(interval = 1.0) ?(max_interval = 10.0) ?(backoff = 1.5) ~timeout message =
  if interval <= 0. || backoff < 1. then invalid_arg "send_message_and_wait: need interval > 0 and backoff >= 1";
  let last = ref None in
  match
    Eio.Time.Timeout.run (Eio.Time.Timeout.seconds t.clock timeout) @@ fun () ->
    Ok
      (let* resp = send_message t ?tenant ?configuration ?metadata message in
       match resp with
       | Send_message_response.Message m -> Ok (Lifecycle.Outcome.Message m)
       | Task task when not (Task_state.is_active task.status.state) ->
           Ok (Lifecycle.Outcome.of_task task)
       | Task task ->
           last := Some task;
           let* task =
             poll ~clock:t.clock ~interval ~max_interval ~backoff ~last
               (fun () -> get_task t ?tenant ?history_length task.id)
           in
           Ok (Lifecycle.Outcome.of_task task))
  with
  | Ok r -> r
  | Error `Timeout -> Error (Error.Poll_timeout { last_task = !last })

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
  let for_version v =
    List.find_map
      (fun (i : Agent_interface.t) ->
        match Protocol_binding.of_string i.protocol_binding with
        | Some b
          when List.mem b bindings && Wire.supports v b
               && Protocol_version.of_string i.protocol_version = Some v ->
            Some (i, v, b)
        | _ -> None)
      card.supported_interfaces
  in
  match List.find_map for_version wanted with
  | Some found -> Ok found
  | None ->
      let offered =
        card.supported_interfaces
        |> List.map (fun (i : Agent_interface.t) ->
               Printf.sprintf "%s %s" i.protocol_binding i.protocol_version)
        |> String.concat ", "
      in
      let usable v =
        let bs = List.filter (Wire.supports v) bindings in
        Printf.sprintf "%s with protocol %s.x"
          (String.concat " or " (List.map Protocol_binding.to_string bs))
          (Protocol_version.to_string v)
      in
      Error
        (Error.No_compatible_interface
           (Printf.sprintf "need %s; agent offers [%s]"
              (String.concat ", or " (List.map usable wanted))
              offered))

let select_interface ?protocol_version ?bindings card =
  Result.map (fun (i, _, _) -> i) (select ?protocol_version ?bindings card)

let of_agent_card ?auth ?headers ?extensions ?timeout ?stream_idle_timeout
    ?max_response_size ?reconnect ?protocol_version ?bindings ~clock ~transport
    (card : Agent_card.t) =
  let* iface, version, binding = select ?protocol_version ?bindings card in
  Ok
    (create ?auth ?headers ?tenant:iface.tenant ?extensions ?timeout ?stream_idle_timeout
       ?max_response_size ?reconnect ~card ~protocol_version:version ~binding ~clock ~transport
       (Uri.of_string iface.url))

let connect ?auth ?headers ?extensions ?timeout ?stream_idle_timeout ?max_response_size
    ?reconnect ?protocol_version ?bindings ~clock ~transport base =
  let* card = fetch_agent_card ?auth ?headers ?timeout ?max_response_size ~clock ~transport base in
  of_agent_card ?auth ?headers ?extensions ?timeout ?stream_idle_timeout ?max_response_size
    ?reconnect ?protocol_version ?bindings ~clock ~transport card
