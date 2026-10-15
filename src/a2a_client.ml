(** A2A (Agent2Agent) protocol v1.0 client for OCaml 5 / Eio.

    {[
      Eio_main.run @@ fun env ->
      let transport = A2a_client.Transport.cohttp (Eio.Stdenv.net env) in
      let clock = Eio.Stdenv.mono_clock env in
      match A2a_client.connect ~clock ~transport (Uri.of_string "http://localhost:9999") with
      | Error e -> prerr_endline (A2a_client.Error.to_string e)
      | Ok client -> (
          match A2a_client.send_text client "Hello" with
          | Ok (Message m) -> print_endline (A2a_client.Message.text m)
          | Ok (Task t) -> Printf.printf "task %s\n" t.id
          | Error e -> prerr_endline (A2a_client.Error.to_string e))
    ]}

    Layers, from the bottom:
    - {!Types} data model and {!Codec} ProtoJSON conversion;
    - {!Jsonrpc} envelopes and {!Sse} parsing;
    - {!Transport}, the replaceable HTTP layer (cohttp-eio by default);
    - the client operations below, and {!Lifecycle} helpers. *)

module Types = Types
include Types
module Codec = Codec
module Error = Error
module Jsonrpc = Jsonrpc
module Sse = Sse
module Transport = Transport
module Lifecycle = Lifecycle
module Outcome = Lifecycle.Outcome
include Client
