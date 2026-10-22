let state_key = Domain.DLS.new_key (fun () -> Random.State.make_self_init ())

let uuid_v4 () =
  let st = Domain.DLS.get state_key in
  Uuidm.to_string (Uuidm.v4_gen st ())
