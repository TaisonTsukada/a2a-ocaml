(* Identifier generation (message ids, JSON-RPC request ids).

   The stdlib default Random state is domain-local but deterministically
   seeded, so each domain lazily gets its own self-initialised state. *)

let state_key = Domain.DLS.new_key (fun () -> Random.State.make_self_init ())

let uuid_v4 () =
  let st = Domain.DLS.get state_key in
  Uuidm.to_string (Uuidm.v4_gen st ())
