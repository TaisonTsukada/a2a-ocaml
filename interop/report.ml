open A2a_client

let failures = ref 0

let check name cond detail =
  if cond then Printf.printf "PASS  %s\n%!" name
  else begin
    incr failures;
    Printf.printf "FAIL  %s: %s\n%!" name detail
  end

let err = Error.to_string

let describe = function
  | Outcome.Message m -> "message: " ^ Message.text m
  | o -> (
      match Outcome.task o with
      | Some t -> Printf.sprintf "task %s %s" t.id (Task_state.to_string t.status.state)
      | None -> "?")

let finish () =
  if !failures > 0 then begin
    Printf.printf "%d check(s) failed\n" !failures;
    exit 1
  end
  else print_endline "all interop checks passed"
