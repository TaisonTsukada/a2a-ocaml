(* Task lifecycle helpers: classifying task states and folding streaming
   events into a task snapshot. Pure; no I/O. *)

open Types

(* Where an interaction ended up, from the client's point of view. *)
module Outcome = struct
  type t =
    | Message of Message.t  (** the agent answered directly, no task *)
    | Completed of Task.t
    | Failed of Task.t
    | Canceled of Task.t
    | Rejected of Task.t
    | Input_required of Task.t
        (** reply with [Task.follow_up] to continue *)
    | Auth_required of Task.t
    | In_progress of Task.t
        (** submitted / working / unspecified: not settled yet *)

  let of_task (t : Task.t) =
    match t.status.state with
    | Completed -> Completed t
    | Failed -> Failed t
    | Canceled -> Canceled t
    | Rejected -> Rejected t
    | Input_required -> Input_required t
    | Auth_required -> Auth_required t
    | Submitted | Working | Unspecified -> In_progress t

  let of_send_message_response : Send_message_response.t -> t = function
    | Message m -> Message m
    | Task t -> of_task t

  let task = function
    | Message _ -> None
    | Completed t | Failed t | Canceled t | Rejected t | Input_required t
    | Auth_required t | In_progress t ->
        Some t

  (** The task will not change any more (or there was no task). *)
  let is_final = function
    | Message _ | Completed _ | Failed _ | Canceled _ | Rejected _ -> true
    | Input_required _ | Auth_required _ | In_progress _ -> false

  (** The agent is done for now: final, or waiting for the client. *)
  let is_settled = function In_progress _ -> false | _ -> true
end

let replace_or_add_artifact (artifacts : Artifact.t list) (a : Artifact.t) =
  if List.exists (fun (x : Artifact.t) -> x.artifact_id = a.artifact_id) artifacts then
    List.map (fun (x : Artifact.t) -> if x.artifact_id = a.artifact_id then a else x) artifacts
  else artifacts @ [ a ]

let apply_artifact_update (task : Task.t) (e : Task_artifact_update_event.t) =
  let a = e.artifact in
  let artifacts =
    match List.find_opt (fun (x : Artifact.t) -> x.artifact_id = a.artifact_id) task.artifacts with
    | Some existing when e.append ->
        let merged =
          { existing with
            parts = existing.parts @ a.parts;
            metadata = (match a.metadata with Some _ -> a.metadata | None -> existing.metadata) }
        in
        replace_or_add_artifact task.artifacts merged
    | _ -> replace_or_add_artifact task.artifacts a
  in
  { task with artifacts }

let merge_metadata old upd =
  match (old, upd) with
  | None, m | m, None -> m
  | Some o, Some u ->
      Some (List.filter (fun (k, _) -> not (List.mem_assoc k u)) o @ u)

let apply_status_update (task : Task.t) (e : Task_status_update_event.t) =
  let history =
    match e.status.message with
    | Some m
      when not (List.exists (fun (h : Message.t) -> h.message_id = m.message_id && m.message_id <> "") task.history) ->
        task.history @ [ m ]
    | _ -> task.history
  in
  { task with
    status = e.status;
    history;
    metadata = merge_metadata task.metadata e.metadata;
    context_id = (match task.context_id with None when e.context_id <> "" -> Some e.context_id | c -> c) }

(* Fold one stream event into the current task snapshot. Events for a
   different task id than the current one start a fresh snapshot. *)
let apply (current : Task.t option) (ev : Stream_response.t) : Task.t option =
  match ev with
  | Task t -> Some t
  | Message _ -> current
  | Status_update e -> (
      match current with
      | Some t when t.id = e.task_id -> Some (apply_status_update t e)
      | _ ->
          let context_id = if e.context_id = "" then None else Some e.context_id in
          Some (apply_status_update (Task.make ?context_id ~id:e.task_id e.status) e))
  | Artifact_update e -> (
      match current with
      | Some t when t.id = e.task_id -> Some (apply_artifact_update t e)
      | _ ->
          let context_id = if e.context_id = "" then None else Some e.context_id in
          Some
            (apply_artifact_update
               (Task.make ?context_id ~id:e.task_id (Task_status.make Task_state.Unspecified))
               e))
