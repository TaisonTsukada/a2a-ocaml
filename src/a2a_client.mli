(** A2A (Agent2Agent) protocol client for OCaml 5 / Eio.

    Speaks protocol 1.0 over the JSON-RPC and HTTP+JSON (REST) bindings,
    and 0.3 over JSON-RPC with agents that have not moved to 1.0; the
    version and binding are negotiated from the Agent Card by {!connect}.

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
    ]} *)

(** {1 Data model} *)

module Types = Types

include module type of struct
  include Types
end

(** {1 Supporting modules} *)

module Protocol_version = Protocol_version
module Protocol_binding = Protocol_binding
module Error = Error
module Transport = Transport
module Lifecycle = Lifecycle
module Outcome = Lifecycle.Outcome
module Codec = Codec
module Codec_v0_3 = Codec_v0_3

(** {1 Client} *)

include module type of struct
  include Client
end
