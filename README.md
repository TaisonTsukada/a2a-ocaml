# a2a-ocaml

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![A2A](https://img.shields.io/badge/A2A-v1.0%20%7C%20v0.3-green.svg)](https://github.com/a2aproject/A2A/blob/v1.0.1/docs/specification.md)
![OCaml](https://img.shields.io/badge/OCaml-%E2%89%A5%205.1-orange.svg)

A type-safe [A2A (Agent2Agent) Protocol](https://github.com/a2aproject/A2A) **v1.0** client for OCaml 5, built on [Eio](https://github.com/ocaml-multicore/eio) and [cohttp-eio](https://github.com/mirage/ocaml-cohttp). It speaks the JSON-RPC and HTTP+JSON (REST) bindings, and is backward compatible with **v0.3** agents: the version and binding are negotiated from the Agent Card, and your code stays the same.

```ocaml
match A2a_client.send_text client "Summarize this company's latest filings" with
| Ok (Message m) -> print_endline (A2a_client.Message.text m)
| Ok (Task t) -> Printf.printf "task %s is %s\n" t.id (A2a_client.Task_state.to_string t.status.state)
| Error e -> prerr_endline (A2a_client.Error.to_string e)
```

## Features

- **All A2A v1.0 operations**: `SendMessage`, `SendStreamingMessage`, `GetTask`, `ListTasks`, `CancelTask`, `SubscribeToTask`, the four push notification config operations and `GetExtendedAgentCard`.
- **Two bindings**: JSON-RPC 2.0 and HTTP+JSON (REST), with the same API. REST errors (`google.rpc.Status`) map to the same error codes as JSON-RPC errors.
- **Backward compatible with v0.3**: the same operations against v0.3 agents (`message/send`, `tasks/pushNotificationConfig/set`, `agent/getAuthenticatedExtendedCard`, …), with the same types and results.
- **Agent discovery**: fetches `/.well-known/agent-card.json` (v1.0 or v0.3 layout) and picks the interface, binding and protocol version, including its `tenant`.
- **Typed data model**: records for `AgentCard`, `Message`, `Part`, `Task`, `Artifact` and the streaming events, and variants for `TaskState`, `Role`, `Part` content and error codes.
- **No exceptions on bad input**: every operation returns a `result`. Malformed JSON, schema violations and mismatched JSON-RPC ids become `Error`s that include the JSON path of the problem.
- **Incremental SSE streaming**: each event reaches your callback as soon as it arrives, whatever the TCP chunking. Status and artifact updates are folded into a final `Task`.
- **Stream resumption**: an optional reconnect policy re-attaches a broken stream with `SubscribeToTask` (sending `Last-Event-ID`), with backoff, and falls back to `GetTask` if the task ended meanwhile.
- **Connection reuse**: `Transport.pooled` keeps HTTP/1.1 connections alive between requests, scoped to an Eio `Switch`.
- **Task lifecycle helpers**: an `Outcome` variant (`Completed`, `Failed`, `Input_required`, …), bounded polling with backoff, and follow-up messages that keep the `taskId` and `contextId`.
- **Eio native**: timeouts, cancellation and guaranteed connection cleanup through `Switch`. No Lwt or Async.
- **Pluggable transport**: the HTTP layer is a single function type, so you can reuse your own HTTP stack or a mock.
- **Secret-safe logging**: logs (via `Logs`) never contain headers, credentials or message bodies.

## Installation

The package is not on the public opam repository yet. Install it straight from GitHub; opam resolves the dependencies:

```sh
opam pin add a2a-client https://github.com/TaisonTsukada/a2a-ocaml.git
```

To install a specific release, append its tag, for example `…/a2a-ocaml.git#v0.1.0`. To install from a local checkout, run `opam install .` in the repository root.

Then add the library to your `dune` file:

```dune
(executable
 (name main)
 (libraries a2a-client eio_main))
```

**Requirements:** OCaml ≥ 5.1, eio ≥ 1.0, cohttp-eio ≥ 6.2.1, yojson ≥ 3.0.

## Quick start

```ocaml
let () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.mono_clock env in
  let transport = A2a_client.Transport.cohttp (Eio.Stdenv.net env) in
  match A2a_client.connect ~clock ~transport (Uri.of_string "http://localhost:9999") with
  | Error e -> prerr_endline (A2a_client.Error.to_string e)
  | Ok client -> (
      match A2a_client.send_text client "Hello" with
      | Ok (Message m) -> print_endline (A2a_client.Message.text m)
      | Ok (Task t) -> print_endline t.id
      | Error e -> prerr_endline (A2a_client.Error.to_string e))
```

`connect` reads the Agent Card from `<base>/.well-known/agent-card.json` and chooses the protocol version and binding (see [Protocol versions and bindings](#protocol-versions-and-bindings)). If you already know the endpoint, use `A2a_client.create ~clock ~transport endpoint` instead.

`Transport.cohttp` opens a connection per request. For a long-lived process, use `Transport.pooled` (see [Connection reuse](#connection-reuse)).

## Usage

### Sending messages

`send_text` is a shortcut for the common case. `send_message` accepts any `Message.t`:

```ocaml
open A2a_client

let message =
  Message.user
    [ Part.text "Describe this image";
      Part.url ~media_type:"image/png" "https://example.com/chart.png";
      Part.data (`Assoc [ ("locale", `String "en-US") ]) ]

let response =
  send_message client message
    ~configuration:(Send_message_configuration.make ~accepted_output_modes:[ "text/plain" ] ())
```

The agent replies with either a `Message` or a `Task`, and the task may still be running.

### Task lifecycle

`send_message_and_wait` sends a message and then polls `GetTask` until the task is terminal (completed, failed, canceled or rejected) or interrupted (input-required or auth-required):

```ocaml
match send_message_and_wait client ~timeout:300. (Message.user_text "Research ACME Corp") with
| Ok (Outcome.Message m) -> (* direct answer, no task *) ...
| Ok (Outcome.Completed task) -> List.iter (fun a -> print_endline (Artifact.text a)) task.artifacts
| Ok (Outcome.Failed task | Outcome.Rejected task | Outcome.Canceled task) -> ...
| Ok (Outcome.Input_required task) ->
    (* continue the same task; taskId and contextId are carried over *)
    send_message client (Task.follow_up_text task "The one headquartered in Tokyo")
| Ok (Outcome.Auth_required task) -> ...
| Ok (Outcome.In_progress _) -> assert false (* never returned by send_message_and_wait *)
| Error (Error.Poll_timeout { last_task }) -> (* still running after 300 s *) ...
| Error e -> ...
```

- `wait_for_task client ~timeout task_id` polls a task that already exists. The delay starts at `interval` (default 1 s), grows by `backoff` (default 1.5×) and is capped at `max_interval` (default 10 s). Sleeping uses `Eio.Time`, so it never blocks the domain.
- `~timeout` is mandatory, so polling cannot run forever.
- `get_task` and `cancel_task` are available directly.
- `Task_state.is_terminal`, `is_interrupted` and `is_active` classify raw states.

### Listing tasks

`list_tasks` returns one page of the tasks visible to the client, most recently updated first, with optional filters:

```ocaml
let rec all_working ?page_token acc =
  match list_tasks client ~status:Working ~context_id:"ctx-1" ~page_size:50 ?page_token () with
  | Error e -> Error e
  | Ok { tasks; next_page_token = ""; _ } -> Ok (acc @ tasks)
  | Ok { tasks; next_page_token; _ } -> all_working ~page_token:next_page_token (acc @ tasks)
```

`next_page_token` is `""` on the last page. The other filters are `history_length`, `status_timestamp_after` and `include_artifacts`. Protocol 0.3 has no `ListTasks`; there the call fails locally with `Unsupported_capability`.

### Push notifications

An agent can POST task updates to a webhook while no stream is open. Register the webhook with the message:

```ocaml
let push =
  Task_push_notification_config.make ~token:"check-me"
    ~authentication:(Authentication_info.make ~credentials:secret "Bearer")
    "https://my-service.example.com/a2a/webhook"

let configuration = Send_message_configuration.make ~push_notification_config:push ~return_immediately:true ()
```

or for an existing task:

```ocaml
create_task_push_notification_config client (Task_push_notification_config.make ~task_id ~token url)
get_task_push_notification_config client ~task_id config_id
list_task_push_notification_configs client task_id
delete_task_push_notification_config client ~task_id config_id
```

The agent sends `token` back in the `X-A2A-Notification-Token` header so the webhook can check where a notification came from. When the client was built from an Agent Card that does not declare `capabilities.pushNotifications`, these calls fail locally with `Unsupported_capability`. Receiving the notifications is up to your HTTP server.

### Extended Agent Card

An agent may show more (skills, interfaces) to authenticated clients:

```ocaml
match get_extended_agent_card client () with
| Ok card -> let client = with_agent_card client card in ...
| Error e -> ...
```

The request carries the client's `auth`. `with_agent_card` returns the same client checking capabilities against the new card. If the client's card does not declare `capabilities.extendedAgentCard` (`supportsAuthenticatedExtendedCard` in 0.3), the call fails locally with `Unsupported_capability`.

### Streaming

```ocaml
send_streaming_message client (Message.user_text "Write a report")
  ~on_event:(function
    | Stream_response.Task t -> Printf.printf "task %s\n%!" t.id
    | Message m -> print_endline (Message.text m)
    | Status_update e -> Printf.printf "[%s]\n%!" (Task_state.to_string e.status.state)
    | Artifact_update e -> print_string (Artifact.text e.artifact))
(* : (Outcome.t, Error.t) result, with all updates folded into the final task *)
```

- **Delivery:** events are parsed from the socket as bytes arrive and passed to `on_event` one at a time. The response is never buffered as a whole.
- **Normal end:** the stream finishes after a `Message`, or when the task reaches a terminal state. In input-required or auth-required, the client keeps reading, as the spec asks (§7.6.1). If the server closes the stream in one of those states, that counts as a normal end.
- **Early close:** if the stream closes at any other point, you get `Error (Stream_ended { last_task })`. You can resume with `subscribe_to_task` or `wait_for_task`, or let the client do it (below).
- **Stopping and cleanup:** to stop early, cancel the calling fiber, for example with `Eio.Fiber.first` or `Eio.Time.with_timeout`. If `on_event` raises, the exception propagates to the caller. In every case the connection is closed.
- **Capability check:** when the client was built from an Agent Card that does not declare `capabilities.streaming`, the call fails locally with `Unsupported_capability`.

#### Resuming broken streams

With a `Reconnect` policy, a stream that breaks before the task settles is re-attached with `SubscribeToTask`:

```ocaml
connect ~clock ~transport base
  ~stream_idle_timeout:60.
  ~reconnect:(Reconnect.make ~max_attempts:5 ~delay:1. ~max_delay:30. ())
```

- **Triggers:** the server closing the stream early, a transport error, or `stream_idle_timeout`. Agent errors, HTTP errors and malformed events are returned as they are.
- **State:** `SubscribeToTask` starts with a snapshot of the task, delivered to `on_event` as a `Task` event. Events missed while disconnected are not replayed, but their effect is in the snapshot. `Last-Event-ID` is sent when the server gave event ids.
- **Task already over:** if the agent refuses to subscribe (`Unsupported_operation`, for example because the task ended meanwhile), the client fetches the task with `GetTask` and returns its final state; if it is still running, later attempts poll with `GetTask` instead of subscribing.
- **Backoff:** the delay starts at `delay`, is multiplied by `backoff` (default 2) after each failed attempt up to `max_delay`, and is at least the server's SSE `retry` hint. An attempt that receives events resets the count. After `max_attempts` failures in a row, the last error is returned.
- **Not resumable:** a stream that closes before naming a task. The default policy, `Reconnect.none`, never reconnects.

### Protocol versions and bindings

The client speaks A2A 1.0 over JSON-RPC and HTTP+JSON (REST), and A2A 0.3 over JSON-RPC. The version and binding only change the wire format; requests, results and errors use the same OCaml types, so the code above works with all of them.

`connect` (and `of_agent_card`) picks the first interface in the Agent Card for protocol 1.x whose binding is `JSONRPC` or `HTTP+JSON`; the card's order is the agent's preference. If the card has none, it picks the first `JSONRPC` interface for 0.3.x. Cards in the v0.3 layout (`url`, `preferredTransport`, `additionalInterfaces`, `protocolVersion`) are read as well. Other versions and bindings (gRPC) are never used; the call fails with `No_compatible_interface`.

```ocaml
let client = connect ~clock ~transport base |> Result.get_ok in
match A2a_client.version client with
| V1_0 -> print_endline "talking A2A 1.0"
| V0_3 -> print_endline "talking A2A 0.3"

(* Only accept 1.0: *)
connect ~protocol_version:V1_0 ~clock ~transport base

(* Only use JSON-RPC: *)
connect ~bindings:[ Jsonrpc ] ~clock ~transport base

(* Known REST endpoint, no Agent Card: *)
create ~binding:Http_json ~clock ~transport (Uri.of_string "https://agent.example.com/a2a/rest")

(* Known v0.3 endpoint, no Agent Card: *)
create ~protocol_version:V0_3 ~clock ~transport (Uri.of_string "https://agent.example.com/a2a")
```

With HTTP+JSON, operations map to resource paths under the endpoint (`POST /message:send`, `GET /tasks/{id}`, `GET /tasks?status=…`, `POST /tasks/{id}:cancel`, …), prefixed with `/{tenant}` when a tenant is set. Bodies use `application/a2a+json`. Errors are `google.rpc.Status` objects; the `reason` of their `google.rpc.ErrorInfo` detail (`TASK_NOT_FOUND`, …) gives the error code.

With protocol 0.3:

- the methods are `message/send`, `message/stream`, `tasks/get`, `tasks/cancel` and `tasks/resubscribe`;
- `return_immediately` is sent as `blocking` (its negation);
- extensions go in both `A2A-Extensions` and `X-A2A-Extensions`;
- `tenant` is not sent, because 0.3 has no such field;
- the media type of text and data parts is not sent, because 0.3 has no field for it;
- non-object data parts are wrapped as `{"value": …}` with metadata `data_part_compat: true`, the convention of the official SDKs. They are unwrapped on the way back;
- push notification configs use the 0.3 layout (`pushNotificationConfig` nested, `authentication.schemes`), and are listed without pagination;
- `list_tasks` is not available.

### Configuration and authentication

```ocaml
A2a_client.create ~clock ~transport
  ~auth:(Auth.bearer token)                   (* or Auth.header "X-API-Key" key, Auth.dynamic f *)
  ~headers:[ ("X-Request-Source", "my-service") ]
  ~extensions:[ "https://example.com/ext/v1" ]  (* sent as A2A-Extensions *)
  ~protocol_version:V1_0                      (* or V0_3; default V1_0 *)
  ~binding:Jsonrpc                            (* or Http_json; default Jsonrpc *)
  ~tenant:"acme"
  ~timeout:30.                                (* unary calls and stream headers; default 30 s *)
  ~stream_idle_timeout:120.                   (* max silence on a stream; default none *)
  ~max_response_size:(16 * 1024 * 1024)       (* per body or SSE event; default 16 MiB *)
  ~reconnect:(Reconnect.make ())              (* resume broken streams; default Reconnect.none *)
  endpoint
```

- `Auth.dynamic` runs before every request, so it can refresh OAuth tokens.
- Every request carries the client's protocol version in `A2A-Version` (`1.0` or `0.3`).

### HTTPS

The library does not depend on a TLS implementation. Pass a TLS wrapper to `Transport.cohttp`; it has the same type as the one `Cohttp_eio.Client.make` takes. With [tls-eio](https://github.com/mirleft/ocaml-tls) and [ca-certs](https://github.com/mirage/ca-certs):

```ocaml
let () = Mirage_crypto_rng_unix.use_default ()  (* TLS needs a seeded RNG *)

let https =
  let authenticator = Ca_certs.authenticator () |> Result.get_ok in
  let config = Tls.Config.client ~authenticator () |> Result.get_ok in
  fun uri raw ->
    let host = Uri.host uri |> Option.map (fun h -> Domain_name.(host_exn (of_string_exn h))) in
    Tls_eio.client_of_flow ?host config raw

let transport = A2a_client.Transport.cohttp ~https (Eio.Stdenv.net env)
```

`Transport.pooled` takes the same `~https` argument. If you use an `https://` URL without a wrapper, the call returns a `Transport_error`. The error message never contains the URL.

### Connection reuse

`Transport.pooled` keeps connections open between requests (HTTP/1.1 keep-alive):

```ocaml
Eio.Switch.run @@ fun sw ->
let transport = A2a_client.Transport.pooled ~sw ~clock (Eio.Stdenv.net env) in
...
```

- **Lifetime:** connections belong to `sw`, typically your application's switch, and are all closed when it finishes. Each request still holds its connection only for its own duration, so concurrent requests and open streams each use their own.
- **Reuse:** a connection goes back to the pool once its response has been read to the end. A response left unfinished (a stream whose server has not closed it yet, cancellation, an error) is drained in the background for up to 0.1 s, without delaying the caller; if it does not end, the connection is closed.
- **Expiry:** idle connections older than `idle_timeout` are closed at the next request.
- **Limits:** `~max_idle_per_host` (default 8) idle connections per scheme, host and port, each kept for `~idle_timeout` seconds (default 30).
- **Stale connections:** a request that fails on a reused connection (the server may have closed it in the meantime) is retried once on a new one.
- Proxies (`Cohttp_eio.Client.set_proxies`) apply to `Transport.cohttp` only.

### Embedding in an existing service

- `Transport.t` and `A2a_client.t` are immutable. Create them once at startup and share them across request handlers.
- Each call runs inside its own `Switch`. When a handler's fiber is cancelled (for example, because its client disconnected), the A2A call is cancelled too and its connection is released (closed, never returned to a pool).
- To reuse an existing HTTP stack, implement `Transport.t`:

  ```ocaml
  type t = sw:Eio.Switch.t -> Transport.request -> Transport.response
  ```

  Attach any connection you open to `sw`. The same interface makes the client easy to mock in tests (see `test/mock.ml`).

### Logging

The library logs to the `Logs` source `A2a_client.src` (named `"a2a-client"`). Log lines contain method names, request ids, URLs without userinfo or query, and errors. They never contain headers, credentials or message bodies.

## Errors

Every operation returns `(_, A2a_client.Error.t) result`. The only exception that can escape is Eio cancellation.

| Constructor | Meaning |
| --- | --- |
| `Rpc_error { code; message; details }` | The agent returned an A2A error: a JSON-RPC error, or with REST a `google.rpc.Status`. `code` is a variant such as `Task_not_found`, `Task_not_cancelable` or `Version_not_supported`, or one of the standard JSON-RPC codes; a REST error with an unknown `reason` is `Other status`. `Error.error_info` extracts a `google.rpc.ErrorInfo` detail |
| `Http_error { status; body }` | Non-2xx HTTP status that is not an A2A error. `body` is an excerpt of up to 1 KiB |
| `Transport_error msg` | Connection, DNS, reset or TLS failure |
| `Timeout what` | `timeout` or `stream_idle_timeout` elapsed |
| `Invalid_response msg` | Bad JSON, a JSON-RPC envelope violation, a schema violation (for example `at $.result.task.status.state: unknown TaskState "done"`) or an oversized body |
| `Stream_ended { last_task }` | The stream closed before the task settled |
| `Poll_timeout { last_task }` | Polling gave up |
| `No_compatible_interface`, `Unsupported_capability` | Checked locally. `No_compatible_interface`: the Agent Card has no usable interface. `Unsupported_capability`: the card does not declare a capability the call needs, or the protocol version lacks the operation |

## Protocol compatibility

| | |
| --- | --- |
| Protocol | A2A **1.0**: [specification v1.0.1](https://github.com/a2aproject/A2A/blob/v1.0.1/docs/specification.md), [`a2a.proto`](https://github.com/a2aproject/A2A/blob/v1.0.1/specification/a2a.proto) (`lf.a2a.v1`) |
| Backward compatibility | A2A **0.3**: [specification v0.3.0](https://github.com/a2aproject/A2A/blob/v0.3.0/docs/specification.md), [JSON schema](https://github.com/a2aproject/A2A/blob/v0.3.0/specification/json/a2a.json) |
| Bindings | 1.0: JSON-RPC 2.0 and HTTP+JSON (REST). 0.3: JSON-RPC 2.0. Both stream with Server-Sent Events |
| Wire format | 1.0: ProtoJSON (camelCase fields, `TASK_STATE_*` / `ROLE_*` enum names, oneofs discriminated by member name). 0.3: `kind`-tagged objects and lowercase enums (`working`, `input-required`, `user`) |
| Older versions | v0.2 and earlier are not supported. Agents that only offer them get `No_compatible_interface`; the client never falls back to a version it does not implement (spec §3.6.3) |

These choices follow the official SDKs:

- **Decoding:** unknown fields are ignored and absent scalars take their default value, as in ProtoJSON. The fields the client depends on are validated: task `id` and `status.state`, event `taskId`, exactly one kind of `Part` content, and exactly one payload in `SendMessageResponse` and `StreamResponse`.
- **Enums:** in 1.0, both enum names and enum numbers are accepted. In 0.3, the state `unknown` maps to `Unspecified`.
- **0.3 leniency:** a missing `kind` is inferred from the fields. A timestamp without a time zone is read as UTC; one that cannot be parsed is dropped instead of failing the event. `final` on status updates is ignored, because the end of a stream follows from the task state, as in 1.0. A v0.3 `OAuthFlows` with several flows keeps the first, in the order authorization code, client credentials, implicit, password.
- **SSE event types:** SSE events of types other than `message` or `error` are ignored. The payload of an `event: error` is decoded as a JSON-RPC error, or with REST as a `google.rpc.Status`.
- **Non-SSE replies:** if a streaming request gets a JSON reply, the client treats it as a single response. This is usually an error raised before the stream started.
- **REST requests:** like the official SDKs, `POST` bodies carry the whole request message (path parameters included) and `GET`/`DELETE` send the remaining fields as camelCase query parameters. `SubscribeToTask` uses `POST /tasks/{id}:subscribe`.

## Module overview

| Module | Purpose |
| --- | --- |
| `A2a_client` | Client operations, discovery and polling. Also re-exports the data model |
| `Types` | Protocol data model |
| `Codec` | JSON conversion for the 1.0 wire format; Agent Cards in either layout |
| `Codec_v0_3` | JSON conversion for the 0.3 wire format |
| `Protocol_version` | `V1_0` / `V0_3` |
| `Protocol_binding` | `Jsonrpc` / `Http_json` |
| `Transport` | HTTP abstraction, and the cohttp-eio implementations (`cohttp`, `pooled`) |
| `Lifecycle` | `Outcome` classification and folding stream events into a task |
| `Error` | Error type and A2A error codes |

The API reference is generated from the `.mli` files with `dune build @doc`.

## Examples

[`examples/a2a_cli.ml`](examples/a2a_cli.ml) is a small command-line client:

```sh
dune exec examples/a2a_cli.exe -- http://localhost:9999 send   "Hello"
dune exec examples/a2a_cli.exe -- http://localhost:9999 wait   "Research this company"
dune exec examples/a2a_cli.exe -- http://localhost:9999 stream "Write a report"
dune exec examples/a2a_cli.exe -- http://localhost:9999 get    TASK_ID
A2A_TOKEN=... dune exec examples/a2a_cli.exe -- http://localhost:9999 cancel TASK_ID
dune exec examples/a2a_cli.exe -- http://localhost:9999 list   CONTEXT_ID   # or - for all
```

## Limitations

Not supported yet:

- the gRPC binding, and the HTTP+JSON binding of protocol 0.3
- Agent Card signature (JWS) verification; `signatures` are parsed but not checked
- HTTP caching of Agent Cards
- receiving push notifications (that is your HTTP server's job)
- HTTP/2, and proxies with `Transport.pooled`
- A2A v0.2 and earlier
- server-side components (agent executor, task store); this is a client library

## License

[MIT](LICENSE)
