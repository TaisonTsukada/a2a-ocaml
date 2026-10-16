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
      Eio.Switch.run @@ fun sw ->
      let clock = Eio.Stdenv.mono_clock env in
      let transport = Transport.pooled ~sw ~clock (Eio.Stdenv.net env) in
      let auth = match Sys.getenv_opt "A2A_TOKEN" with Some t -> Auth.bearer t | None -> Auth.none in
      let result =
        let ( let* ) = Result.bind in
        let* client =
          connect ~clock ~transport ~auth ~reconnect:(Reconnect.make ()) (Uri.of_string url)
        in
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
        | "list" ->
            let context_id = if arg = "-" then None else Some arg in
            let rec page token =
              let* r = list_tasks client ?context_id ?page_token:token () in
              List.iter print_task r.tasks;
              if r.next_page_token = "" then Ok () else page (Some r.next_page_token)
            in
            page None
        | _ -> Ok (prerr_endline ("unknown command " ^ cmd))
      in
      (match result with
       | Ok () -> ()
       | Error e ->
           prerr_endline ("error: " ^ Error.to_string e);
           exit 1)
  | _ ->
      prerr_endline "usage: a2a_cli URL (send|wait|stream|get|cancel|list) ARG";
      exit 2
