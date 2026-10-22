(** Task lifecycle helpers: where an interaction ended up, and folding
    streaming events into a task. Pure; no I/O. *)

open Types

(** Where an interaction ended up, from the client's point of view. *)
module Outcome : sig
  type t =
    | Message of Message.t  (** The agent answered directly, without a task. *)
    | Completed of Task.t
    | Failed of Task.t
    | Canceled of Task.t
    | Rejected of Task.t
    | Input_required of Task.t
        (** Reply with {!Types.Task.follow_up} to continue. *)
    | Auth_required of Task.t
    | In_progress of Task.t  (** Submitted, working or unspecified: not settled yet. *)

  val of_task : Task.t -> t
  val of_send_message_response : Send_message_response.t -> t

  val task : t -> Task.t option
  (** [None] for [Message]. *)

  val is_final : t -> bool
  (** The task will not change any more, or there was no task. *)

  val is_settled : t -> bool
  (** The agent is done for now: final, or waiting for the client. *)
end

val apply : Task.t option -> Stream_response.t -> Task.t option
(** Fold one stream event into the current task snapshot.
    - A [Task] event replaces the snapshot; a [Message] leaves it unchanged.
    - A status update sets the status, appends its message to the history
      (once per message id) and merges its metadata.
    - An artifact update adds or replaces the artifact by id, or appends its
      parts when [append] is set.
    - An event for another task id starts a fresh snapshot.

    Each call takes time linear in the size of the task. The streaming
    operations fold incrementally instead, in time linear in the number of
    events overall. *)
