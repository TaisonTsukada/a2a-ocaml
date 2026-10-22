(* Streaming calls: one SSE session per HTTP exchange, resumption with
   [SubscribeToTask] under a [Reconnect] policy, and a pull interface
   (Event_stream) on top of the push one. *)

open Types
open Conn

type state = {
  mutable task : Task_fold.t;
  mutable message : Message.t option;
  mutable last_event_id : string option;
  mutable retry : float option;
  mutable events : int;
}

(* A task state satisfying [p], or a direct [Message] answer. *)
let reached p st =
  match Task_fold.state st.task with Some state -> p state | None -> st.message <> None

let settled = reached (fun s -> not (Task_state.is_active s))
let finished = reached Task_state.is_terminal

let ended st = Error (Error.Stream_ended { last_task = Task_fold.task st.task })

(* The end of an exchange: the outcome if the agent is done for now. *)
let conclude st =
  match (settled st, Task_fold.task st.task, st.message) with
  | true, Some task, _ -> Ok (Lifecycle.Outcome.of_task task)
  | true, None, Some m -> Ok (Lifecycle.Outcome.Message m)
  | _ -> ended st

let deliver st ~on_event ev =
  st.task <- Task_fold.apply st.task ev;
  (match ev with
   | Stream_response.Message m when st.message = None -> st.message <- Some m
   | _ -> ());
  st.events <- st.events + 1;
  on_event ev

let attempt t (op : _ Op.t) req ~st ~on_event =
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
      let rec loop () =
        let* chunk = read_chunk () in
        match chunk with
        | None -> conclude st
        | Some chunk -> (
            match Sse.feed parser chunk with
            | Error (`Event_too_large n) ->
                Error (Error.Invalid_response (Printf.sprintf "SSE event exceeds %d bytes" n))
            | Ok events -> handle_events events)
      and handle_events = function
        | [] -> loop ()
        | ({ event_type = Some typ; _ } : Sse.event) :: rest when typ <> "message" && typ <> "error" ->
            Log.debug (fun m -> m "%s: ignoring SSE event of type %S" op.name typ);
            handle_events rest
        | (ev : Sse.event) :: rest ->
            if ev.id <> None then st.last_event_id <- ev.id;
            Option.iter (fun ms -> st.retry <- Some (float_of_int ms /. 1000.)) ev.retry;
            let* sr = r.decode ev.data in
            deliver st ~on_event sr;
            if finished st then conclude st else handle_events rest
      in
      let r = loop () in
      Log.debug (fun m -> m "%s stream closed (id %s)" op.name id);
      r
  | `Single body ->
      let* sr = r.decode body in
      deliver st ~on_event sr;
      conclude st

let resumable = function
  | Error.Stream_ended _ | Transport_error _ | Timeout _ -> true
  | _ -> false

let run t ?tenant ~accumulate (op : _ Op.t) req ~on_event :
    (Lifecycle.Outcome.t, Error.t) result =
  let* () = require_capability t "streaming support" (fun c -> c.capabilities.streaming) in
  let st =
    { task = Task_fold.empty ~accumulate; message = None; last_event_id = None; retry = None;
      events = 0 }
  in
  let policy = t.reconnect in
  let resync task_id =
    let* task = get_task t ?tenant task_id in
    deliver st ~on_event (Stream_response.Task task);
    conclude st
  in
  let subscribable = ref true in
  let resume task_id =
    if not !subscribable then (resync task_id, false)
    else
      let before = st.events in
      match
        attempt t t.wire.subscribe_to_task
          { Subscribe_to_task_request.tenant = with_tenant t tenant; id = task_id } ~st ~on_event
      with
      | Error (Error.Rpc_error { code = Unsupported_operation; _ }) ->
          subscribable := false;
          (resync task_id, false)
      | r -> (r, st.events > before)
  in
  let rec retry ~attempt:n ~delay result =
    match (result, Task_fold.id st.task) with
    | Error e, Some task_id when resumable e && n < policy.Reconnect.max_attempts ->
        let wait = Float.max delay (Option.value st.retry ~default:0.) in
        Log.info (fun m ->
            m "stream for task %s interrupted (%a); reconnecting in %gs (%d/%d)" task_id Error.pp e
              wait (n + 1) policy.max_attempts);
        Eio.Time.Mono.sleep t.clock wait;
        let result, progressed = resume task_id in
        let n, delay =
          if progressed then (0, policy.delay)
          else (n + 1, Float.min policy.max_delay (delay *. policy.backoff))
        in
        retry ~attempt:n ~delay result
    | _ -> result
  in
  retry ~attempt:0 ~delay:policy.delay (attempt t op req ~st ~on_event)

module Event_stream = struct
  exception Closed

  type ending = Done of (Lifecycle.Outcome.t, Error.t) result | Closed_by_caller

  type t = {
    events : Stream_response.t Eio.Stream.t;  (* capacity 0: the producer waits for [next] *)
    ending : ending Eio.Promise.t;  (* resolved after the last event was taken *)
    set_ending : ending Eio.Promise.u;
    mutable producer : Eio.Switch.t option;  (* while the producer runs *)
  }

  let take t =
    match Eio.Promise.peek t.ending with
    | Some ending -> `End ending
    | None ->
        Eio.Fiber.first
          (fun () -> `Event (Eio.Stream.take t.events))
          (fun () -> `End (Eio.Promise.await t.ending))

  let next t =
    match take t with
    | `Event ev -> Ok (Some ev)
    | `End (Done (Ok _) | Closed_by_caller) -> Ok None
    | `End (Done (Error e)) -> Error e

  let outcome t = match Eio.Promise.peek t.ending with Some (Done r) -> Some r | _ -> None

  let close t =
    if Eio.Promise.try_resolve t.set_ending Closed_by_caller then
      Option.iter (fun sw -> Eio.Switch.fail sw Closed) t.producer

  let open_ ~sw produce =
    let ending, set_ending = Eio.Promise.create () in
    let started, set_started = Eio.Promise.create () in
    let t = { events = Eio.Stream.create 0; ending; set_ending; producer = None } in
    let on_event ev =
      ignore (Eio.Promise.try_resolve set_started ());
      Eio.Stream.add t.events ev
    in
    (* A daemon, so that [sw] does not wait for a stream nobody reads. *)
    Eio.Fiber.fork_daemon ~sw (fun () ->
        (match
           Eio.Switch.run (fun psw ->
               t.producer <- Some psw;
               produce ~on_event)
         with
         | r ->
             t.producer <- None;
             ignore (Eio.Promise.try_resolve set_ending (Done r))
         | exception Closed -> t.producer <- None);
        `Stop_daemon);
    match
      Eio.Fiber.first
        (fun () -> Eio.Promise.await started; Ok t)
        (fun () ->
          match Eio.Promise.await ending with Done (Error e) -> Error e | _ -> Ok t)
    with
    | r -> r
    | exception e ->
        close t;
        raise e
end
