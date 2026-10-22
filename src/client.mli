(** A2A client over the JSON-RPC and HTTP+JSON (REST) bindings.

    Speaks protocol 1.0 and, for agents that only offer it, 0.3 (JSON-RPC
    only). The protocol version and binding are chosen once per client
    ({!connect} negotiates them from the Agent Card) and only change the
    wire format: requests and results use the same types either way.

    All operations return [result]s; network failures, timeouts and
    malformed responses never raise. Eio cancellation propagates as usual
    and closes the underlying connection. *)

open Types

val src : Logs.src
(** Log source ["a2a-client"]. Logs contain method names, request ids,
    redacted URLs (no userinfo/query) and errors — never headers,
    credentials or message bodies. *)

val protocol_version : string
(** ["1.0"], the newest protocol version supported. Each request carries
    the client's version ({!version}) in the [A2A-Version] header. *)

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

(** What a streaming call does when its stream breaks before the task
    settles. *)
module Reconnect : sig
  type t

  val none : t
  (** Give up at once with [Stream_ended] (or the transport error). The
      default. *)

  val make :
    ?max_attempts:int -> ?delay:float -> ?max_delay:float -> ?backoff:float -> unit -> t
  (** Re-attach with [SubscribeToTask] up to [max_attempts] times in a row
      (default 5), waiting [delay] seconds (default 1) multiplied by
      [backoff] (default 2) after each failed attempt, up to [max_delay]
      (default 30), and at least the server's SSE [retry] hint. An attempt
      that receives events resets the count.

      The stream must have named a task; a stream closed before that is not
      resumed. Resuming relies on the task snapshot that [SubscribeToTask]
      sends first, so events missed while disconnected are not replayed
      but are reflected in the snapshot. [Last-Event-ID] is sent when the
      server gave event ids. If the agent refuses to subscribe
      ([Unsupported_operation], e.g. the task ended meanwhile), the task
      is fetched with [GetTask] and delivered as a [Task] event; later
      attempts poll with [GetTask] instead of subscribing.

      Triggers: the stream closing early, a transport error, and
      [stream_idle_timeout]. Agent errors, HTTP errors and malformed
      events are returned as they are.
      Raises [Invalid_argument] if [max_attempts < 0], [delay < 0] or
      [backoff < 1]. *)
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
  ?reconnect:Reconnect.t ->
  ?card:Agent_card.t ->
  ?protocol_version:Protocol_version.t ->
  ?binding:Protocol_binding.t ->
  clock:_ Eio.Time.Mono.t ->
  transport:Transport.t ->
  Uri.t ->
  t
(** [create ~clock ~transport endpoint] talks to [endpoint], the URL of a
    [supportedInterfaces] entry.

    @param protocol_version wire format to use. Default [V1_0]; pass [V0_3]
      for an agent that implements A2A 0.3.x.
    @param binding default [Jsonrpc]. With [Http_json], operation paths
      such as [/message:send] are appended to [endpoint].

    @param headers extra HTTP headers on every request.
    @param tenant sent as [tenant] in every request (spec §8.3.2). Not
      part of protocol 0.3, where it is not sent.
    @param extensions extension URIs, sent as [A2A-Extensions] (and also as
      [X-A2A-Extensions] with protocol 0.3).
    @param timeout seconds for a unary call, and for a streaming call to
      receive the response headers. Default 30; [Float.infinity] disables.
    @param stream_idle_timeout max seconds between two reads of a stream.
      Default: none (tasks may legitimately be silent for a long time).
    @param max_response_size bytes; bounds a unary body and a single SSE
      event. Default 16 MiB.
    @param reconnect for streaming calls. Default {!Reconnect.none}.
    @param card if given, operations that need a capability the card does
      not declare (streaming, push notifications, extended Agent Card) are
      refused locally with [Unsupported_capability].

    Raises [Invalid_argument] for [V0_3] with [Http_json]. *)

val connect :
  ?auth:Auth.t ->
  ?headers:(string * string) list ->
  ?extensions:string list ->
  ?timeout:float ->
  ?stream_idle_timeout:float ->
  ?max_response_size:int ->
  ?reconnect:Reconnect.t ->
  ?protocol_version:Protocol_version.t ->
  ?bindings:Protocol_binding.t list ->
  ?rewrite_endpoint:(Uri.t -> Uri.t) ->
  clock:_ Eio.Time.Mono.t ->
  transport:Transport.t ->
  Uri.t ->
  (t, Error.t) result
(** [connect base_url] = {!fetch_agent_card} then {!of_agent_card}. *)

val endpoint : t -> Uri.t
val agent_card : t -> Agent_card.t option

val with_agent_card : t -> Agent_card.t -> t
(** The same client, checking capabilities against another card, e.g. the
    one from {!get_extended_agent_card}. *)

val version : t -> Protocol_version.t
(** The protocol version this client speaks. *)

val binding : t -> Protocol_binding.t

(** {1 Discovery} *)

val agent_card_uri : Uri.t -> Uri.t
(** [base ^ "/.well-known/agent-card.json"], unless [base] already points
    at a [.json] file. (Agents on protocol 0.3 use the same path.) *)

val fetch_agent_card :
  ?auth:Auth.t ->
  ?headers:(string * string) list ->
  ?timeout:float ->
  ?max_response_size:int ->
  clock:_ Eio.Time.Mono.t ->
  transport:Transport.t ->
  Uri.t ->
  (Agent_card.t, Error.t) result
(** Cards in the 0.3 layout ([url], [preferredTransport],
    [additionalInterfaces], [protocolVersion]) are decoded into the same
    {!Agent_card.t}, their endpoints listed in [supported_interfaces]. *)

val select_interface :
  ?protocol_version:Protocol_version.t ->
  ?bindings:Protocol_binding.t list ->
  Agent_card.t ->
  (Agent_interface.t, Error.t) result
(** The first [supportedInterfaces] entry with protocol version 1.x and a
    binding in [bindings] (default [JSONRPC] and [HTTP+JSON]); failing
    that, the first with version 0.3.x and binding [JSONRPC]. The card's
    order is the agent's preference. [protocol_version] accepts only that
    version. Other protocol versions and bindings are never used. *)

val of_agent_card :
  ?auth:Auth.t ->
  ?headers:(string * string) list ->
  ?extensions:string list ->
  ?timeout:float ->
  ?stream_idle_timeout:float ->
  ?max_response_size:int ->
  ?reconnect:Reconnect.t ->
  ?protocol_version:Protocol_version.t ->
  ?bindings:Protocol_binding.t list ->
  ?rewrite_endpoint:(Uri.t -> Uri.t) ->
  clock:_ Eio.Time.Mono.t ->
  transport:Transport.t ->
  Agent_card.t ->
  (t, Error.t) result
(** Client for the interface chosen by {!select_interface}, with its
    [tenant], protocol version and binding.

    @param rewrite_endpoint maps the chosen interface's URL to the one
      actually used. Default: unchanged. The card only picks the
      interface; use this when the URL it advertises is not reachable
      from the client, e.g. an agent behind a Kubernetes Service that
      builds its card from its own bind address:
      [connect ~rewrite_endpoint:(rebase_endpoint ~onto:base) base]. *)

val rebase_endpoint : onto:Uri.t -> Uri.t -> Uri.t
(** [rebase_endpoint ~onto url] is [url] with the scheme, host and port of
    [onto]; its path and query are kept. *)

val get_extended_agent_card : t -> ?tenant:string -> unit -> (Agent_card.t, Error.t) result
(** [GetExtendedAgentCard] ([agent/getAuthenticatedExtendedCard] in 0.3):
    the card as seen by the authenticated client. Use {!with_agent_card}
    to check later calls against it. *)

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

val list_tasks :
  t ->
  ?tenant:string ->
  ?context_id:string ->
  ?status:Task_state.t ->
  ?page_size:int ->
  ?page_token:string ->
  ?history_length:int ->
  ?status_timestamp_after:Ptime.t ->
  ?include_artifacts:bool ->
  unit ->
  (List_tasks_response.t, Error.t) result
(** [ListTasks]: tasks visible to the client, most recently updated first.
    Pass the response's [next_page_token] as [page_token] for the next
    page; it is [""] on the last one. Not part of protocol 0.3, where it
    fails with [Unsupported_capability]. *)

val cancel_task :
  t -> ?tenant:string -> ?metadata:metadata -> string -> (Task.t, Error.t) result
(** [CancelTask]. Fails with [Rpc_error {code = Task_not_cancelable; _}]
    for tasks already in a terminal state. *)

(** {1 Push notification configs}

    Where the agent should send task updates while no stream is open.
    These fail with [Unsupported_capability] if the client's card does not
    declare [capabilities.pushNotifications]. A config can also be given
    with the message, in {!Send_message_configuration.make}. *)

val create_task_push_notification_config :
  t -> Task_push_notification_config.t -> (Task_push_notification_config.t, Error.t) result
(** [CreateTaskPushNotificationConfig] ([tasks/pushNotificationConfig/set]
    in 0.3). The result carries the id the agent assigned. *)

val get_task_push_notification_config :
  t -> ?tenant:string -> task_id:string -> string ->
  (Task_push_notification_config.t, Error.t) result
(** [GetTaskPushNotificationConfig ~task_id id]. *)

val list_task_push_notification_configs :
  t -> ?tenant:string -> ?page_size:int -> ?page_token:string -> string ->
  (List_task_push_notification_configs_response.t, Error.t) result
(** [ListTaskPushNotificationConfigs task_id]. *)

val delete_task_push_notification_config :
  t -> ?tenant:string -> task_id:string -> string -> (unit, Error.t) result
(** [DeleteTaskPushNotificationConfig ~task_id id]. *)

(** {1 Streaming}

    Each streaming operation comes in two forms that behave the same:
    push ({!send_streaming_message}, {!subscribe_to_task}) hands events to
    [on_event] and returns when the stream ends; pull
    ({!open_streaming_message}, {!open_task_subscription}) returns an
    {!Event_stream.t} to read with {!Event_stream.next}, e.g. to relay
    events to an HTTP response of your own.

    Events are decoded one by one as SSE data arrives; the response is
    never buffered as a whole, and no event is read before the previous
    one was handed over.

    The final state is the task with all status and artifact updates
    folded in ({!Lifecycle.apply}). The stream ends normally after a
    [Message], when the task reaches a terminal state, or when the server
    closes it while the task is interrupted (input/auth required). Any
    other close is [Error (Stream_ended _)] carrying the last known task,
    so the caller can resume with {!subscribe_to_task} or
    {!wait_for_task}, unless the client was created with a {!Reconnect}
    policy, which does that itself.

    [accumulate] (default [true]) folds history and artifacts into that
    task. With [false], only its id, context, status and metadata are
    tracked: the outcome's task has empty [history] and [artifacts], and
    memory stays constant however long the stream. Use it when you
    consume the events themselves. *)

val send_streaming_message :
  t ->
  ?tenant:string ->
  ?configuration:Send_message_configuration.t ->
  ?metadata:metadata ->
  ?accumulate:bool ->
  ?on_event:(Stream_response.t -> unit) ->
  Message.t ->
  (Lifecycle.Outcome.t, Error.t) result
(** [SendStreamingMessage]. If [on_event] raises, the exception propagates
    and the connection is closed. To stop early from outside, cancel the
    calling fiber (e.g. [Eio.Fiber.first], [Eio.Time.with_timeout]). *)

val subscribe_to_task :
  t ->
  ?tenant:string ->
  ?accumulate:bool ->
  ?on_event:(Stream_response.t -> unit) ->
  string ->
  (Lifecycle.Outcome.t, Error.t) result
(** [SubscribeToTask] ([tasks/resubscribe] in 0.3): re-attach to a
    non-terminal task's event stream. *)

(** An open stream of events, read one at a time. *)
module Event_stream : sig
  type t

  val next : t -> (Stream_response.t option, Error.t) result
  (** Wait for the next event. [Ok None] once the stream has ended
      normally or was {!close}d; [Error e] if it ended otherwise, with the
      error {!send_streaming_message} would return. After the end, every
      call returns the same. Call it from one fiber at a time. *)

  val outcome : t -> (Lifecycle.Outcome.t, Error.t) result option
  (** What {!send_streaming_message} would have returned, once {!next} has
      returned every event; [None] before that and after {!close}. *)

  val close : t -> unit
  (** Stop reading and release the connection. Idempotent. A {!next}
      waiting in another fiber returns [Ok None]. Releasing the switch the
      stream was opened with also closes it. *)
end

val open_streaming_message :
  t ->
  sw:Eio.Switch.t ->
  ?tenant:string ->
  ?configuration:Send_message_configuration.t ->
  ?metadata:metadata ->
  ?accumulate:bool ->
  Message.t ->
  (Event_stream.t, Error.t) result
(** [SendStreamingMessage], read with {!Event_stream.next}. Returns once
    the agent has accepted the request and sent its first event (which
    [next] returns first), so an [Error] here means nothing was streamed:
    a refused connection, an HTTP error, or an agent error such as
    [Invalid_params], whether as a response or as the first SSE event.
    The stream is read by a fiber in [sw]; it ends with [sw] at the
    latest. *)

val open_task_subscription :
  t ->
  sw:Eio.Switch.t ->
  ?tenant:string ->
  ?accumulate:bool ->
  string ->
  (Event_stream.t, Error.t) result
(** [SubscribeToTask], read with {!Event_stream.next}. As
    {!open_streaming_message}. *)

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
    Raises [Invalid_argument] if [interval <= 0] or [backoff < 1]. *)

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
