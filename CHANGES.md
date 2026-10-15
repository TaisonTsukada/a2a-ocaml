## 0.1.0

Initial release.

- A2A protocol v1.0 client over the JSON-RPC binding (cohttp-eio, Eio).
- Agent Card discovery and JSON-RPC interface selection.
- `SendMessage`, `GetTask`, `CancelTask`, `SendStreamingMessage`, `SubscribeToTask`.
- Incremental Server-Sent Events parser.
- Task lifecycle helpers: `Outcome`, `wait_for_task`, `send_message_and_wait`.
