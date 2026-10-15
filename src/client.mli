(** A2A v1.0 client over the JSON-RPC binding.

    All operations return [result]s; network failures, timeouts and
    malformed responses never raise. Eio cancellation propagates as usual
    and closes the underlying connection. *)

open Types

val src : Logs.src
(** Log source ["a2a-client"]. Logs contain method names, request ids,
    redacted URLs (no userinfo/query) and errors — never headers,
    credentials or message bodies. *)

val protocol_version : string
(** ["1.0"], sent as the [A2A-Version] header on every request. *)

(** Credentials attached to each request. *)
module Auth : sig
  type t

  val none : t

  val bearer : string -> t
  (** [Authorization: Bearer <token>] *)

  val header : string -> string -> t
  (** e.g. [header "X-API-Key" key] *)

  val headers : (string * string) list -> t

  val dynamic : (unit -> (string * string) list) -> t
  (** Called before every request, e.g. to refresh an OAuth token. *)
end

type t

val create :
  ?auth:Auth.t ->
  ?headers:(string * string) list ->
  ?tenant:string ->
  ?extensions:string list ->
  ?timeout:float ->
  ?stream_idle_timeout:float ->
  ?max_response_size:int ->
  ?card:Agent_card.t ->
  clock:_ Eio.Time.Mono.t ->
  transport:Transport.t ->
  Uri.t ->
  t
(** [create ~clock ~transport endpoint] talks JSON-RPC to [endpoint].

    @param headers extra HTTP headers on every request.
    @param tenant sent as [tenant] in every request (spec §8.3.2).
    @param extensions extension URIs, sent as [A2A-Extensions].
    @param timeout seconds for a unary call, and for a streaming call to
      receive the response headers. Default 30; [Float.infinity] disables.
    @param stream_idle_timeout max seconds between two reads of a stream.
      Default: none (tasks may legitimately be silent for a long time).
    @param max_response_size bytes; bounds a unary body and a single SSE
      event. Default 16 MiB.
    @param card if given, streaming calls are refused locally unless the
      card declares [capabilities.streaming]. *)

val connect :
  ?auth:Auth.t ->
  ?headers:(string * string) list ->
  ?extensions:string list ->
  ?timeout:float ->
  ?stream_idle_timeout:float ->
  ?max_response_size:int ->
  clock:_ Eio.Time.Mono.t ->
  transport:Transport.t ->
  Uri.t ->
  (t, Error.t) result
(** [connect base_url] = {!fetch_agent_card} then {!of_agent_card}. *)

val endpoint : t -> Uri.t
val agent_card : t -> Agent_card.t option

(** {1 Discovery} *)

val agent_card_uri : Uri.t -> Uri.t
(** [base ^ "/.well-known/agent-card.json"], unless [base] already points
    at a [.json] file. *)

val fetch_agent_card :
  ?auth:Auth.t ->
  ?headers:(string * string) list ->
  ?timeout:float ->
  ?max_response_size:int ->
  clock:_ Eio.Time.Mono.t ->
  transport:Transport.t ->
  Uri.t ->
  (Agent_card.t, Error.t) result

val select_interface : Agent_card.t -> (Agent_interface.t, Error.t) result
(** First [supportedInterfaces] entry with binding [JSONRPC] and protocol
    version 1.x. No silent fallback to other versions. *)

val of_agent_card :
  ?auth:Auth.t ->
  ?headers:(string * string) list ->
  ?extensions:string list ->
  ?timeout:float ->
  ?stream_idle_timeout:float ->
  ?max_response_size:int ->
  clock:_ Eio.Time.Mono.t ->
  transport:Transport.t ->
  Agent_card.t ->
  (t, Error.t) result
(** Client for the interface chosen by {!select_interface}, with its
    [tenant]. *)

(** {1 Core operations} *)

val send_message :
  t ->
  ?tenant:string ->
  ?configuration:Send_message_configuration.t ->
  ?metadata:metadata ->
  Message.t ->
  (Send_message_response.t, Error.t) result
(** [SendMessage]. The agent answers with a [Message] or a [Task] that may
    still be in progress. *)

val send_text :
  t ->
  ?context_id:string ->
  ?task_id:string ->
  ?configuration:Send_message_configuration.t ->
  ?metadata:metadata ->
  string ->
  (Send_message_response.t, Error.t) result
(** [send_message] with a single text part from the user. *)

val get_task :
  t -> ?tenant:string -> ?history_length:int -> string -> (Task.t, Error.t) result
(** [GetTask]. *)

val cancel_task :
  t -> ?tenant:string -> ?metadata:metadata -> string -> (Task.t, Error.t) result
(** [CancelTask]. Fails with [Rpc_error {code = Task_not_cancelable; _}]
    for tasks already in a terminal state. *)

(** {1 Streaming}

    Events are decoded and handed to [on_event] one by one as SSE data
    arrives; the response is never buffered as a whole. If [on_event]
    raises, the exception propagates and the connection is closed. To stop
    early from outside, cancel the calling fiber (e.g. [Eio.Fiber.first],
    [Eio.Time.with_timeout]).

    The result is the final state, with all status and artifact updates
    folded into the task ({!Lifecycle.apply}). The stream ends normally
    after a [Message], when the task reaches a terminal state, or when the
    server closes it while the task is interrupted (input/auth required).
    Any other close is [Error (Stream_ended _)] carrying the last known
    task, so the caller can resume with {!subscribe_to_task} or
    {!wait_for_task}. *)

val send_streaming_message :
  t ->
  ?tenant:string ->
  ?configuration:Send_message_configuration.t ->
  ?metadata:metadata ->
  ?on_event:(Stream_response.t -> unit) ->
  Message.t ->
  (Lifecycle.Outcome.t, Error.t) result
(** [SendStreamingMessage]. *)

val subscribe_to_task :
  t ->
  ?tenant:string ->
  ?on_event:(Stream_response.t -> unit) ->
  string ->
  (Lifecycle.Outcome.t, Error.t) result
(** [SubscribeToTask]: re-attach to a non-terminal task's event stream. *)

(** {1 Task lifecycle} *)

val wait_for_task :
  t ->
  ?tenant:string ->
  ?history_length:int ->
  ?interval:float ->
  ?max_interval:float ->
  ?backoff:float ->
  timeout:float ->
  string ->
  (Task.t, Error.t) result
(** Poll [GetTask] until the task is terminal or interrupted. Sleeps
    [interval] seconds (default 1) between polls, multiplied by [backoff]
    (default 1.5) each time up to [max_interval] (default 10). Gives up
    with [Poll_timeout] after [timeout] seconds; any failed [GetTask]
    aborts with that error.
    @raise Invalid_argument if [interval <= 0] or [backoff < 1]. *)

val send_message_and_wait :
  t ->
  ?tenant:string ->
  ?configuration:Send_message_configuration.t ->
  ?metadata:metadata ->
  ?history_length:int ->
  ?interval:float ->
  ?max_interval:float ->
  ?backoff:float ->
  timeout:float ->
  Message.t ->
  (Lifecycle.Outcome.t, Error.t) result
(** [send_message], then poll as {!wait_for_task} if the agent returned a
    task that is still in progress. [timeout] bounds the whole
    interaction. The outcome is never [In_progress]. *)
