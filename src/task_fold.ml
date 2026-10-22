open Types
module Ids = Set.Make (String)

type artifact = { artifact : Artifact.t; rev_parts : Part.t list }

type snapshot = {
  base : Task.t;  (* up to date except for [history] and [artifacts] *)
  rev_history : Message.t list;
  seen : Ids.t;  (* non-empty message ids in [rev_history] *)
  rev_artifacts : artifact list;
}

type t = { accumulate : bool; current : snapshot option }

let empty ~accumulate = { accumulate; current = None }

let of_task (t : Task.t) =
  { base = t;
    rev_history = List.rev t.history;
    seen =
      List.fold_left
        (fun s (m : Message.t) -> if m.message_id = "" then s else Ids.add m.message_id s)
        Ids.empty t.history;
    rev_artifacts =
      List.rev_map (fun (a : Artifact.t) -> { artifact = a; rev_parts = List.rev a.parts }) t.artifacts }

let of_task_opt current = { accumulate = true; current = Option.map of_task current }

let to_task s =
  { s.base with
    history = List.rev s.rev_history;
    artifacts =
      List.rev_map (fun x -> { x.artifact with parts = List.rev x.rev_parts }) s.rev_artifacts }

let task t = Option.map to_task t.current
let id t = Option.map (fun s -> s.base.Task.id) t.current
let state t = Option.map (fun s -> s.base.Task.status.state) t.current

let merge_metadata old upd =
  match (old, upd) with
  | None, m | m, None -> m
  | Some o, Some u ->
      Some (List.filter (fun (k, _) -> not (List.mem_assoc k u)) o @ u)

let status_update s (e : Task_status_update_event.t) =
  let rev_history, seen =
    match e.status.message with
    | Some m when m.message_id = "" -> (m :: s.rev_history, s.seen)
    | Some m when not (Ids.mem m.message_id s.seen) ->
        (m :: s.rev_history, Ids.add m.message_id s.seen)
    | _ -> (s.rev_history, s.seen)
  in
  let base = s.base in
  { s with
    base =
      { base with
        status = e.status;
        metadata = merge_metadata base.metadata e.metadata;
        context_id =
          (match base.context_id with None when e.context_id <> "" -> Some e.context_id | c -> c) };
    rev_history;
    seen }

let artifact_update s (e : Task_artifact_update_event.t) =
  let a = e.artifact in
  let same x = x.artifact.artifact_id = a.artifact_id in
  (* The first match in task order is the last one in the reversed list. *)
  let existing = List.fold_left (fun acc x -> if same x then Some x else acc) None s.rev_artifacts in
  let updated =
    match existing with
    | Some x when e.append ->
        { artifact =
            { x.artifact with
              metadata = (match a.metadata with Some _ -> a.metadata | None -> x.artifact.metadata) };
          rev_parts = List.rev_append a.parts x.rev_parts }
    | _ -> { artifact = a; rev_parts = List.rev a.parts }
  in
  let rev_artifacts =
    match existing with
    | Some _ -> List.map (fun x -> if same x then updated else x) s.rev_artifacts
    | None -> updated :: s.rev_artifacts
  in
  { s with rev_artifacts }

let step current (ev : Stream_response.t) =
  (* An event for another task (or the first one) starts a fresh snapshot. *)
  let target ~task_id ~context_id =
    match current with
    | Some s when s.base.id = task_id -> s
    | _ ->
        let context_id = if context_id = "" then None else Some context_id in
        of_task (Task.make ?context_id ~id:task_id (Task_status.make Task_state.Unspecified))
  in
  match ev with
  | Task t -> Some (of_task t)
  | Message _ -> current
  | Status_update e -> Some (status_update (target ~task_id:e.task_id ~context_id:e.context_id) e)
  | Artifact_update e ->
      Some (artifact_update (target ~task_id:e.task_id ~context_id:e.context_id) e)

let forget_content s =
  { base = { s.base with history = []; artifacts = [] }; rev_history = []; seen = Ids.empty;
    rev_artifacts = [] }

let apply t ev =
  let current = step t.current ev in
  { t with current = (if t.accumulate then current else Option.map forget_content current) }
