## 0.3.0

- Pull-based streaming: `open_streaming_message` and
  `open_task_subscription` return an `Event_stream.t` read with
  `Event_stream.next`. They return once the agent has accepted the
  request and sent its first event, so refusals, HTTP errors and agent
  errors (also in-band ones) are known before anything is relayed. Events
  are read only as the caller takes them; `Event_stream.close` or leaving
  the switch releases the connection. Reconnection works as for the push
  form, which is unchanged.
- `?accumulate:false` on streaming calls tracks only the task's id,
  context, status and metadata, so memory stays constant on long streams.
- Folding stream events is linear: 0.2.2 copied the task history on every
  status update and the parts of an artifact on every appended chunk,
  which was quadratic in the number of events.
- `connect` and `of_agent_card` take `?rewrite_endpoint` to use another
  URL than the one the Agent Card advertises, and `rebase_endpoint ~onto`
  moves it onto the host the card was fetched from (agents in containers
  often advertise their bind address).
- New library `a2a-client.testing`: a scripted agent behind a
  `Transport.t`, with typed replies encoded for any protocol version and
  binding.
- `Error.Code.to_reason`, the inverse of `of_reason`.

Breaking changes, so that decoded values carry their meaning in the type
instead of being checked later:

- `Protocol.t` (`V1_0 Jsonrpc`, `V1_0 Http_json`, `V0_3`) replaces
  `create ?protocol_version ?binding`; 0.3 over HTTP+JSON can no longer be
  written. `protocol client` returns it; `connect` keeps
  `?protocol_version` and `?bindings` as preferences.
- `Agent_interface.protocol_binding` and `protocol_version` are
  `Known _ | Unknown of string` instead of strings, parsed when the card is
  decoded.
- Absent values are `option`s instead of `""`: `Message.message_id`, the
  `context_id` of status and artifact update events, and
  `next_page_token`.
- Agent capabilities are `bool` (absent means `false`).
- Push notification configs are split into `Push_notification_config.t`
  (url, token, authentication, id), as sent with a message, and
  `Task_push_notification_config.t` (`task_id` and that config). A config
  whose `taskId` is missing no longer decodes.
- URLs are `Uri.t`: interface and push config URLs, URL parts, and the
  URLs of an Agent Card (provider, documentation, icon, OAuth and OpenID
  Connect).
- `wait_for_task` and `send_message_and_wait` take `?poll:Poll.t` instead
  of `?interval ?max_interval ?backoff`.
- `A2a_client_testing.agent` takes `?protocol`.
- The opam file carries the version, so pins and lock files show which
  release is used.
- The package is on the opam repository: `opam install a2a-client`.

## 0.2.2

- The HTTP and connection pool tests run over an in-memory Eio network
  instead of loopback TCP sockets, so they pass where binding a socket is
  not permitted (e.g. in the opam sandbox on macOS).

## 0.2.1

- Require cohttp-eio, cohttp and http >= 6.2.1. Earlier versions have a
  different `Cohttp_eio.Client.make ~https` type and do not compile.

## 0.2.0

- HTTP+JSON (REST) binding for protocol 1.0, selected from the Agent Card
  (`~bindings`) or with `create ~binding:Http_json`. REST errors
  (`google.rpc.Status` with an `ErrorInfo` reason) become `Rpc_error`s with
  the same codes as JSON-RPC errors. New module `Protocol_binding`, new
  `binding` accessor, and `Error.Code.of_reason`.
- `list_tasks` (`ListTasks`) with filters and cursor pagination.
- Push notification configs: `create_task_push_notification_config`,
  `get_…`, `list_…`, `delete_…`, and `push_notification_config` in
  `Send_message_configuration` (also with protocol 0.3).
- `get_extended_agent_card` (`GetExtendedAgentCard`, 0.3
  `agent/getAuthenticatedExtendedCard`) and `with_agent_card`.
- Stream resumption: `~reconnect:(Reconnect.make ())` re-attaches a broken
  stream with `SubscribeToTask` (with `Last-Event-ID` and backoff), and
  falls back to `GetTask` if the task ended meanwhile. Off by default.
- `Transport.pooled`: HTTP/1.1 keep-alive connection pool scoped to a
  `Switch`, with a retry on stale connections. Responses not read to the
  end are drained in the background so their connections can be reused.
- `Transport.meth` gains `` `DELETE ``; `Transport` has an interface file.
- Capability checks against the Agent Card also cover push notifications
  and the extended Agent Card.
- `Error.Code.to_string (Other n)` is now `"error n"`, as it also covers
  REST errors.
- Behaviour change: `connect`, `of_agent_card` and `select_interface`
  now also pick `HTTP+JSON` interfaces, in the card's order. Pass
  `~bindings:[ Jsonrpc ]` to keep JSON-RPC only.
- Breaking: `Send_message_configuration.t` has a new field
  `push_notification_config`; build the record with `make`.
- Backward compatibility with A2A v0.3. The protocol version is negotiated
  from the Agent Card (1.x preferred, then 0.3.x) or set with
  `~protocol_version`. Existing code needs no changes.
- Agent Cards in the v0.3 layout (`url`, `preferredTransport`,
  `additionalInterfaces`, `security`, `type`-tagged security schemes,
  `supportsAuthenticatedExtendedCard`) are decoded.
- New modules `Protocol_version` and `Codec_v0_3`; new `version` accessor.
- `select_interface` falls back to a v0.3 JSON-RPC interface instead of
  failing with `No_compatible_interface`.
- Breaking: the public API is narrowed to what applications use. `Jsonrpc`
  and `Sse` are no longer exported, and `Codec` exposes only the protocol
  conversions (internal helpers and `Codec.to_string` are gone; use
  `Codec.decode_json` / `decode_string`). `Lifecycle` exposes `Outcome` and
  `apply`.

## 0.1.0

Initial release.

- A2A protocol v1.0 client over the JSON-RPC binding (cohttp-eio, Eio).
- Agent Card discovery and JSON-RPC interface selection.
- `SendMessage`, `GetTask`, `CancelTask`, `SendStreamingMessage`, `SubscribeToTask`.
- Incremental Server-Sent Events parser.
- Task lifecycle helpers: `Outcome`, `wait_for_task`, `send_message_and_wait`.
