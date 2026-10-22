(** Incremental {!Lifecycle.apply} for long streams. History and appended
    artifact parts are kept reversed and seen message ids in a set, so an
    event costs O(log n) instead of O(n); {!task} rebuilds the snapshot in
    O(n). Internal. *)

open Types

type t

val empty : accumulate:bool -> t
(** No task yet. With [~accumulate:false] only the task's id, context,
    status and metadata are tracked: history and artifacts stay empty, so
    memory does not grow with the stream. *)

val of_task_opt : Task.t option -> t
(** Accumulating, starting from a snapshot. *)

val apply : t -> Stream_response.t -> t
(** Same result as {!Lifecycle.apply} when accumulating. *)

val task : t -> Task.t option
val id : t -> string option
val state : t -> Task_state.t option
