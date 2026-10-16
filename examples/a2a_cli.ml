open A2a_client

let print_task (t : Task.t) =
  Printf.printf "task %s [%s]\n" t.id (Task_state.to_string t.status.state);
  Option.iter (fun m -> Printf.printf "  status: %s\n" (Message.text m)) t.status.message;
  List.iter
    (fun (a : Artifact.t) ->
      Printf.printf "  artifact %s: %s\n" (Option.value a.name ~default:a.artifact_id) (Artifact.text a))
    t.artifacts

let print_outcome = function
  | Outcome.Message m -> print_endline (Message.text m)
  | o -> Option.iter print_task (Outcome.task o)

let print_event = function
  | Stream_response.Task t -> Printf.printf "[task %s %s]\n%!" t.id (Task_state.to_string t.status.state)
  | Message m -> Printf.printf "[message] %s\n%!" (Message.text m)
  | Status_update e ->
      Printf.printf "[status %s]%s\n%!" (Task_state.to_string e.status.state)
        (match e.status.message with Some m -> " " ^ Message.text m | None -> "")
  | Artifact_update e -> Printf.printf "[artifact %s] %s\n%!" e.artifact.artifact_id (Artifact.text e.artifact)

let () =
  match Array.to_list Sys.argv with
  | [ _; url; cmd; arg ] ->
      Eio_main.run @@ fun env ->
      let clock = Eio.Stdenv.mono_clock env in
      let transport = Transport.cohttp (Eio.Stdenv.net env) in
      let auth = match Sys.getenv_opt "A2A_TOKEN" with Some t -> Auth.bearer t | None -> Auth.none in
      let result =
        let ( let* ) = Result.bind in
        let* client = connect ~clock ~transport ~auth (Uri.of_string url) in
        match cmd with
        | "send" ->
            let* r = send_text client arg in
            Ok (print_outcome (Outcome.of_send_message_response r))
        | "wait" ->
            let* o = send_message_and_wait client ~timeout:300. (Message.user_text arg) in
            Ok (print_outcome o)
        | "stream" ->
            let* o = send_streaming_message client ~on_event:print_event (Message.user_text arg) in
            Ok (print_outcome o)
        | "get" ->
            let* t = get_task client arg in
            Ok (print_task t)
        | "cancel" ->
            let* t = cancel_task client arg in
            Ok (print_task t)
        | _ -> Ok (prerr_endline ("unknown command " ^ cmd))
      in
      (match result with
       | Ok () -> ()
       | Error e ->
           prerr_endline ("error: " ^ Error.to_string e);
           exit 1)
  | _ ->
      prerr_endline "usage: a2a_cli URL (send|wait|stream|get|cancel) ARG";
      exit 2
