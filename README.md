# a2a-ocaml

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![A2A](https://img.shields.io/badge/A2A-v1.0-green.svg)](https://github.com/a2aproject/A2A/blob/v1.0.1/docs/specification.md)
![OCaml](https://img.shields.io/badge/OCaml-%E2%89%A5%205.1-orange.svg)

A type-safe [A2A (Agent2Agent) Protocol](https://github.com/a2aproject/A2A) **v1.0** client for OCaml 5, built on [Eio](https://github.com/ocaml-multicore/eio) and [cohttp-eio](https://github.com/mirage/ocaml-cohttp).

[日本語版 README](README.ja.md)

```ocaml
match A2a_client.send_text client "Summarize this company's latest filings" with
| Ok (Message m) -> print_endline (A2a_client.Message.text m)
| Ok (Task t) -> Printf.printf "task %s is %s\n" t.id (A2a_client.Task_state.to_string t.status.state)
| Error e -> prerr_endline (A2a_client.Error.to_string e)
```

## Features

- **A2A v1.0 over JSON-RPC 2.0**: `SendMessage`, `SendStreamingMessage`, `GetTask`, `CancelTask`, `SubscribeToTask`.
- **Agent discovery**: fetches `/.well-known/agent-card.json` and picks the JSON-RPC interface, including its `tenant`.
- **Typed data model**: records for `AgentCard`, `Message`, `Part`, `Task`, `Artifact` and the streaming events, and variants for `TaskState`, `Role`, `Part` content and error codes.
- **No exceptions on bad input**: every operation returns a `result`. Malformed JSON, schema violations and mismatched JSON-RPC ids become `Error`s that include the JSON path of the problem.
- **Incremental SSE streaming**: each event reaches your callback as soon as it arrives, whatever the TCP chunking. Status and artifact updates are folded into a final `Task`.
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

**Requirements:** OCaml ≥ 5.1, eio ≥ 1.0, cohttp-eio ≥ 6.0, yojson ≥ 3.0.

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

`connect` reads the Agent Card from `<base>/.well-known/agent-card.json`. If you already know the JSON-RPC endpoint, use `A2a_client.create ~clock ~transport endpoint` instead.

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
- **Early close:** if the stream closes at any other point, you get `Error (Stream_ended { last_task })`. You can resume with `subscribe_to_task` or `wait_for_task`.
- **Stopping and cleanup:** to stop early, cancel the calling fiber, for example with `Eio.Fiber.first` or `Eio.Time.with_timeout`. If `on_event` raises, the exception propagates to the caller. In every case the connection is closed.
- **Capability check:** when the client was built from an Agent Card that does not declare `capabilities.streaming`, the call fails locally with `Unsupported_capability`.

### Configuration and authentication

```ocaml
A2a_client.create ~clock ~transport
  ~auth:(Auth.bearer token)                   (* or Auth.header "X-API-Key" key, Auth.dynamic f *)
  ~headers:[ ("X-Request-Source", "my-service") ]
  ~extensions:[ "https://example.com/ext/v1" ]  (* sent as A2A-Extensions *)
  ~tenant:"acme"
  ~timeout:30.                                (* unary calls and stream headers; default 30 s *)
  ~stream_idle_timeout:120.                   (* max silence on a stream; default none *)
  ~max_response_size:(16 * 1024 * 1024)       (* per body or SSE event; default 16 MiB *)
  endpoint
```

- `Auth.dynamic` runs before every request, so it can refresh OAuth tokens.
- `A2A-Version: 1.0` is always sent.

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

If you use an `https://` URL without a wrapper, the call returns a `Transport_error`. The error message never contains the URL.

### Embedding in an existing service

- `Transport.t` and `A2a_client.t` are immutable. Create them once at startup and share them across request handlers.
- Each call opens its connection inside its own `Switch`. When a handler's fiber is cancelled (for example, because its client disconnected), the A2A call is cancelled too and its connection is released.
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
| `Rpc_error { code; message; details }` | The agent returned a JSON-RPC error. `code` is a variant such as `Task_not_found`, `Task_not_cancelable` or `Version_not_supported`, or one of the standard JSON-RPC codes. `Error.error_info` extracts a `google.rpc.ErrorInfo` detail |
| `Http_error { status; body }` | Non-2xx HTTP status. `body` is an excerpt of up to 1 KiB |
| `Transport_error msg` | Connection, DNS, reset or TLS failure |
| `Timeout what` | `timeout` or `stream_idle_timeout` elapsed |
| `Invalid_response msg` | Bad JSON, a JSON-RPC envelope violation, a schema violation (for example `at $.result.task.status.state: unknown TaskState "done"`) or an oversized body |
| `Stream_ended { last_task }` | The stream closed before the task settled |
| `Poll_timeout { last_task }` | Polling gave up |
| `No_compatible_interface`, `Unsupported_capability` | Checked locally against the Agent Card |

## Protocol compatibility

| | |
| --- | --- |
| Protocol | A2A **1.0**: [specification v1.0.1](https://github.com/a2aproject/A2A/blob/v1.0.1/docs/specification.md), [`a2a.proto`](https://github.com/a2aproject/A2A/blob/v1.0.1/specification/a2a.proto) (`lf.a2a.v1`) |
| Binding | JSON-RPC 2.0 over HTTP, with Server-Sent Events for streaming |
| Wire format | ProtoJSON: camelCase fields, `TASK_STATE_*` / `ROLE_*` enum names, oneofs discriminated by member name |
| Older versions | Not supported. v0.2/v0.3 shapes (`message/send`, `kind`, lowercase states) are rejected. Agents that only offer v0.3 get `No_compatible_interface`; the client never falls back silently (spec §3.6.3) |

These choices follow the official SDKs:

- **Decoding:** unknown fields are ignored and absent scalars take their default value, as in ProtoJSON. The fields the client depends on are validated: task `id` and `status.state`, event `taskId`, exactly one kind of `Part` content, and exactly one payload in `SendMessageResponse` and `StreamResponse`.
- **Enums:** both enum names and enum numbers are accepted.
- **SSE event types:** SSE events of types other than `message` or `error` are ignored. The payload of an `event: error` is decoded as a JSON-RPC error.
- **Non-SSE replies:** if a streaming request gets an `application/json` reply, the client treats it as a single JSON-RPC response. This is usually an error raised before the stream started.

## Module overview

| Module | Purpose |
| --- | --- |
| `A2a_client` | Client operations, discovery and polling. Also re-exports the data model |
| `Types` | Protocol data model |
| `Codec` | ProtoJSON encoders and decoders |
| `Jsonrpc` | JSON-RPC 2.0 envelopes and response validation |
| `Sse` | Pure, incremental Server-Sent Events parser (WHATWG rules) |
| `Transport` | HTTP abstraction and the cohttp-eio implementation |
| `Lifecycle` | `Outcome` classification and folding stream events into a task |
| `Error` | Error type and A2A error codes |

The full API is documented in [`src/client.mli`](src/client.mli). To build HTML docs, run `dune build @doc`.

## Examples

[`examples/a2a_cli.ml`](examples/a2a_cli.ml) is a small command-line client:

```sh
dune exec examples/a2a_cli.exe -- http://localhost:9999 send   "Hello"
dune exec examples/a2a_cli.exe -- http://localhost:9999 wait   "Research this company"
dune exec examples/a2a_cli.exe -- http://localhost:9999 stream "Write a report"
dune exec examples/a2a_cli.exe -- http://localhost:9999 get    TASK_ID
A2A_TOKEN=... dune exec examples/a2a_cli.exe -- http://localhost:9999 cancel TASK_ID
```

## Development

```sh
dune build
dune runtest
```

The test suite covers:

- codecs, JSON-RPC envelopes and the SSE parser, including every possible chunk split;
- every client operation against a mock transport, on Eio's mock clock, including timeouts, polling, disconnects, cancellation and malformed responses;
- an end-to-end run over loopback sockets with a cohttp-eio server.

### Interoperability check

The [A2A TCK](https://github.com/a2aproject/a2a-tck) validates agents, not clients. To check this client against an official implementation, `interop/` runs a set of scenarios against the TCK's reference agent, which is built on the [official Python SDK](https://github.com/a2aproject/a2a-python):

```sh
git clone https://github.com/a2aproject/a2a-python
git clone https://github.com/a2aproject/a2a-tck
(cd a2a-tck/sut/a2a-python && SUT_HOST=localhost:9999 uv run python sut_agent.py) &
dune exec interop/interop.exe -- http://localhost:9999
```

Three scenarios are reported as XFAIL: the reference agent's own SDK rejects them with `InvalidAgentResponseError`. Mock tests cover those cases instead.

### Releasing

1. Update [`CHANGES.md`](CHANGES.md).
2. Tag the release (`git tag v0.1.0 && git push --tags`).
3. Publish it to [opam-repository](https://github.com/ocaml/opam-repository) with [`dune-release`](https://github.com/tarides/dune-release) (`dune-release tag`, `dune-release`) or [`opam-publish`](https://github.com/ocaml-opam/opam-publish).

The `.opam` file is generated from `dune-project`; edit that file, not `a2a-client.opam`.

## Limitations

Not supported yet:

- HTTP+JSON (REST) and gRPC bindings
- push notification configuration, including `taskPushNotificationConfig` in `SendMessageConfiguration`
- `ListTasks` and `GetExtendedAgentCard`
- Agent Card signature (JWS) verification; `signatures` are parsed but not checked
- HTTP caching of Agent Cards
- connection pooling and keep-alive
- automatic SSE reconnection with `Last-Event-ID`; use `subscribe_to_task` instead
- server-side components (agent executor, task store); this is a client library

Contributions are welcome.

## License

[MIT](LICENSE)
