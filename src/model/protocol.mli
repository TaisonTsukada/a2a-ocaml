(** A protocol version together with a binding it can be spoken over.
    Only supported combinations can be built. *)

type t =
  | V1_0 of Protocol_binding.t  (** A2A 1.0, over JSON-RPC or HTTP+JSON. *)
  | V0_3  (** A2A 0.3, over JSON-RPC (the only binding the client implements for 0.3). *)

val default : t
(** [V1_0 Jsonrpc]. *)

val make : Protocol_version.t -> Protocol_binding.t -> t option
(** [None] for 0.3 with HTTP+JSON. *)

val version : t -> Protocol_version.t
val binding : t -> Protocol_binding.t
val pp : Format.formatter -> t -> unit
