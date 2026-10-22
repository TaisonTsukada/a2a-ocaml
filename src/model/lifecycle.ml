open Types

module Outcome = struct
  type t =
    | Message of Message.t
    | Completed of Task.t
    | Failed of Task.t
    | Canceled of Task.t
    | Rejected of Task.t
    | Input_required of Task.t
    | Auth_required of Task.t
    | In_progress of Task.t

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

  let is_final = function
    | Message _ | Completed _ | Failed _ | Canceled _ | Rejected _ -> true
    | Input_required _ | Auth_required _ | In_progress _ -> false

  let is_settled = function In_progress _ -> false | _ -> true
end

let apply current ev = Task_fold.(task (apply (of_task_opt current) ev))
