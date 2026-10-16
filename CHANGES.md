## 0.2.0 (unreleased)

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
