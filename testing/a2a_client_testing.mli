(** A scripted A2A agent behind an {!A2a_client.Transport.t}, for testing
    code that uses the client without a network.

    Replies are given as typed values and encoded in the wire format of
    the agent's protocol version and binding (JSON-RPC envelopes with the
    request's id, REST bodies, SSE framing), so tests contain no
    hand-written JSON.

    {[
      let agent =
        A2a_client_testing.agent ~clock (fun _req ->
            Reply.stream [ Step.event (Task task); Step.event (Status_update done_) ])
      in
      let client =
        A2a_client.create ~clock ~transport:(A2a_client_testing.transport agent) endpoint
      in
      ...
    ]} *)

open A2a_client

(** One step of a streamed response. *)
module Step : sig
  type t

  val event : Stream_response.t -> t
  (** One SSE event carrying the response. *)

  val error : Error.Code.t -> string -> t
  (** One SSE event carrying an agent error. *)

  val raw : string -> t
  (** Bytes as they are, e.g. a comment line or a malformed event. *)

  val sleep : float -> t
  (** Pause for that many seconds of the clock given to {!val-agent}. *)

  val drop : t
  (** The connection breaks: reading fails with an exception. *)

  val hang : t
  (** Nothing more arrives, until the reader is cancelled. *)
end

(** How the agent answers one request. *)
module Reply : sig
  type t

  val stream : Step.t list -> t
  (** [200] with [text/event-stream]. The agent closes the stream after
      the last step, unless that is {!Step.drop} or {!Step.hang}. *)

  val send_message_response : Send_message_response.t -> t
  (** The result of [SendMessage]. *)

  val task : Task.t -> t
  (** The result of [GetTask] or [CancelTask], or a non-streamed answer to
      a streaming request. *)

  val error : ?status:int -> Error.Code.t -> string -> t
  (** An agent error: a JSON-RPC error response, or with the REST binding
      a [google.rpc.Status] body with HTTP [status] (default 400). *)

  val http : status:int -> ?content_type:string -> string -> t
  (** Any HTTP response, e.g. [http ~status:500 "boom"] from a proxy.
      Default content type [text/plain]. *)

  val refuse : t
  (** No response: the transport raises, as when a connection is
      refused. *)

  val after : float -> t -> t
  (** The same reply, sent after that many seconds. *)
end

type agent

val agent :
  ?protocol:Protocol.t ->
  clock:_ Eio.Time.Mono.t ->
  (Transport.request -> Reply.t) ->
  agent
(** An agent that answers each request with the handler's reply, in the
    wire format of [protocol] (default {!A2a_client.Protocol.default}).
    Create the client with the same [protocol]. *)

val transport : agent -> Transport.t

val requests : agent -> Transport.request list
(** The requests received so far, oldest first. *)

val rpc_method : Transport.request -> string option
(** The JSON-RPC method of a request, e.g. ["SendStreamingMessage"] or
    ["message/stream"]; [None] for REST requests. *)

val params : Transport.request -> Yojson.Safe.t
(** The JSON-RPC [params], or the REST body; [`Null] if there is none. *)
