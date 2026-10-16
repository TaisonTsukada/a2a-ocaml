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
  card : Agent_card.t option;
  wire : Wire.t;
}

let default_timeout = 30.0
let default_max_response_size = 16 * 1024 * 1024

let create ?(auth = Auth.none) ?(headers = []) ?tenant ?(extensions = [])
    ?(timeout = default_timeout) ?stream_idle_timeout
    ?(max_response_size = default_max_response_size) ?card
    ?(protocol_version = Protocol_version.V1_0) ~clock ~transport endpoint =
  let timeout = Some timeout in
  { transport; clock = (clock :> Eio.Time.Mono.ty Eio.Resource.t); endpoint;
    tenant; auth; headers; extensions; timeout; stream_idle_timeout;
    max_response_size; card; wire = Wire.of_version protocol_version }

let endpoint t = t.endpoint
let agent_card t = t.card
let version t = t.wire.version

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
  match guard "reading response body" loop with Ok r -> r | Error e -> Error e

let excerpt_limit = 1024

let http_error (resp : Transport.response) =
  let body =
    let cs = Cstruct.create excerpt_limit in
    match Eio.Flow.single_read resp.body cs with
    | n -> Cstruct.to_string ~len:n cs
    | exception (Eio.Cancel.Cancelled _ as e) -> raise e
    | exception _ -> ""
  in
  Error.Http_error { status = resp.status; body }

let is_success status = status >= 200 && status < 300

let request_headers t ~accept =
  let extensions =
    match t.extensions with
    | [] -> []
    | l -> List.map (fun name -> (name, String.concat "," l)) t.wire.extension_headers
  in
  [ ("Content-Type", "application/json"); ("Accept", accept);
    ("A2A-Version", Protocol_version.to_string t.wire.version) ]
  @ extensions @ t.headers @ t.auth ()

let call t (op : _ Wire.op) req =
  let meth = op.meth in
  let id = Jsonrpc.new_id () in
  let body = Yojson.Safe.to_string (Jsonrpc.request ~id ~meth (op.encode req)) in
  Log.debug (fun m -> m "%s -> %s (id %s)" meth (redact_uri t.endpoint) id);
  let result =
    with_timeout t.clock t.timeout meth @@ fun () ->
    Eio.Switch.run @@ fun sw ->
    let req =
      { Transport.meth = `POST; uri = t.endpoint;
        headers = request_headers t ~accept:"application/json"; body = Some body }
    in
    let* resp = guard "sending request" (fun () -> t.transport ~sw req) in
    if not (is_success resp.status) then Error (http_error resp)
    else
      let* body = read_all ~limit:t.max_response_size resp.body in
      Jsonrpc.decode_response ~expected_id:id op.decode body
  in
  (match result with
   | Ok _ -> Log.debug (fun m -> m "%s <- ok (id %s)" meth id)
   | Error e -> Log.info (fun m -> m "%s failed (id %s): %a" meth id Error.pp e));
  result

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

let cancel_task t ?tenant ?metadata id =
  let req = { Cancel_task_request.tenant = with_tenant t tenant; id; metadata } in
  call t t.wire.cancel_task req

type stream_state = { task : Task.t option; message : Message.t option }

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

let capability_check t =
  match t.card with
  | Some card when not (Agent_card.supports_streaming card) ->
      Error (Error.Unsupported_capability "the Agent Card does not declare streaming support")
  | _ -> Ok ()

let decode_event decode ~id data =
  let* json = Jsonrpc.parse_json data in
  let* result = Jsonrpc.parse_response ~expected_id:id json in
  Result.map_error
    (fun e -> Error.Invalid_response (Json_decode.error_to_string (Json_decode.under "result" e)))
    (decode result)

let stream t (op : _ Wire.op) req ~on_event : (Lifecycle.Outcome.t, Error.t) result =
  let* () = capability_check t in
  let meth = op.meth in
  let id = Jsonrpc.new_id () in
  let body = Yojson.Safe.to_string (Jsonrpc.request ~id ~meth (op.encode req)) in
  Log.debug (fun m -> m "%s -> %s (id %s, streaming)" meth (redact_uri t.endpoint) id);
  Eio.Switch.run @@ fun sw ->
  let req =
    { Transport.meth = `POST; uri = t.endpoint;
      headers = request_headers t ~accept:"text/event-stream" @ [ ("Cache-Control", "no-store") ];
      body = Some body }
  in
  let* resp =
    with_timeout t.clock t.timeout (meth ^ " response") @@ fun () ->
    let* resp = guard "sending request" (fun () -> t.transport ~sw req) in
    if not (is_success resp.status) then Error (http_error resp)
    else
      match Transport.media_type resp.headers with
      | Some "text/event-stream" -> Ok (`Stream resp)
      | _ ->
          let* body = read_all ~limit:t.max_response_size resp.body in
          Ok (`Single body)
  in
  let state = ref { task = None; message = None } in
  let deliver ev =
    state :=
      { task = Lifecycle.apply !state.task ev;
        message = (match ev with Stream_response.Message m when !state.message = None -> Some m | _ -> !state.message) };
    on_event ev
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
              Log.debug (fun m -> m "%s: ignoring SSE event of type %S" meth typ);
              handle_events rest
          | (ev : Sse.event) :: rest ->
              let* sr = decode_event op.decode ~id ev.data in
              deliver sr;
              if finished !state then Ok `Done else handle_events rest
        in
        let rec loop () =
          let* chunk = read_chunk () in
          match chunk with
          | None ->
              if settled !state then Ok (outcome !state)
              else Error (Error.Stream_ended { last_task = !state.task })
          | Some chunk -> (
              match Sse.feed parser chunk with
              | Error (`Event_too_large n) ->
                  Error (Error.Invalid_response (Printf.sprintf "SSE event exceeds %d bytes" n))
              | Ok events -> (
                  let* r = handle_events events in
                  match r with `Done -> Ok (outcome !state) | `Continue -> loop ()))
        in
        let r = loop () in
        Log.debug (fun m -> m "%s stream closed (id %s)" meth id);
        r
    | `Single body ->
        let* sr = decode_event op.decode ~id body in
        deliver sr;
        if settled !state then Ok (outcome !state)
        else Error (Error.Stream_ended { last_task = !state.task })

let send_streaming_message t ?tenant ?configuration ?metadata ?(on_event = ignore) message =
  let req = send_message_request t ?tenant ?configuration ?metadata message in
  stream t t.wire.send_streaming_message req ~on_event

let subscribe_to_task t ?tenant ?(on_event = ignore) id =
  let req = { Subscribe_to_task_request.tenant = with_tenant t tenant; id } in
  stream t t.wire.subscribe_to_task req ~on_event

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
    let path =
      if String.ends_with ~suffix:"/" path then String.sub path 0 (String.length path - 1) else path
    in
    Uri.with_path base (path ^ well_known_path)

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
  let* resp = guard "fetching Agent Card" (fun () -> (transport : Transport.t) ~sw req) in
  if not (is_success resp.status) then Error (http_error resp)
  else
    let* body = read_all ~limit:max_response_size resp.body in
    Codec.decode_string Codec.agent_card body
    |> Result.map_error (fun msg -> Error.Invalid_response ("Agent Card " ^ msg))

let select ?protocol_version (card : Agent_card.t) =
  let wanted = match protocol_version with Some v -> [ v ] | None -> Protocol_version.supported in
  let for_version v =
    List.find_map
      (fun (i : Agent_interface.t) ->
        if String.uppercase_ascii i.protocol_binding = "JSONRPC"
           && Protocol_version.of_string i.protocol_version = Some v
        then Some (i, v)
        else None)
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
      let wanted =
        List.map (fun v -> Protocol_version.to_string v ^ ".x") wanted |> String.concat " or "
      in
      Error
        (Error.No_compatible_interface
           (Printf.sprintf "need JSONRPC with protocol %s; agent offers [%s]" wanted offered))

let select_interface ?protocol_version card = Result.map fst (select ?protocol_version card)

let of_agent_card ?auth ?headers ?extensions ?timeout ?stream_idle_timeout
    ?max_response_size ?protocol_version ~clock ~transport (card : Agent_card.t) =
  let* iface, version = select ?protocol_version card in
  Ok
    (create ?auth ?headers ?tenant:iface.tenant ?extensions ?timeout ?stream_idle_timeout
       ?max_response_size ~card ~protocol_version:version ~clock ~transport
       (Uri.of_string iface.url))

let connect ?auth ?headers ?extensions ?timeout ?stream_idle_timeout ?max_response_size
    ?protocol_version ~clock ~transport base =
  let* card = fetch_agent_card ?auth ?headers ?timeout ?max_response_size ~clock ~transport base in
  of_agent_card ?auth ?headers ?extensions ?timeout ?stream_idle_timeout ?max_response_size
    ?protocol_version ~clock ~transport card
