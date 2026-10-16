open A2a_client
open Report

let artifact id (t : Task.t) = List.find_opt (fun (a : Artifact.t) -> a.artifact_id = id) t.artifacts

let check_artifacts name (t : Task.t) =
  (match artifact "a1" t with
   | Some a -> check (name ^ ": chunked text artifact") (Artifact.text a = "chunk-1 chunk-2") (Artifact.text a)
   | None -> check (name ^ ": chunked text artifact") false "missing");
  match artifact "f1" t with
  | Some { parts = [ p1; p2; p3 ]; _ } ->
      check (name ^ ": file bytes part")
        (p1.content = Raw "\000tck\255" && p1.filename = Some "o.bin"
        && p1.media_type = Some "application/octet-stream")
        "content";
      check (name ^ ": file uri part") (p2.content = Url "https://example.com/o.txt") "content";
      check (name ^ ": data part") (p3.content = Data (`Assoc [ ("key", `String "value") ])) "content"
  | _ -> check (name ^ ": file/data artifact") false "missing or wrong shape"

let run ~clock ~transport base =
  let client =
    match connect ~clock ~transport base with
    | Ok c -> c
    | Error e -> failwith ("connect: " ^ err e)
  in
  check "Agent Card (0.3 layout) parsed" ((Option.get (agent_card client)).name <> "") "";
  check "negotiated protocol 0.3" (version client = V0_3) (Protocol_version.to_string (version client));
  let send ?configuration text = send_message client ?configuration (Message.user_text text) in

  (match send "message hi" with
   | Ok (Message m) -> check "message/send -> Message" (Message.text m = "Direct: message hi") (Message.text m)
   | Ok (Task t) -> check "message/send -> Message" false ("task " ^ t.id)
   | Error e -> check "message/send -> Message" false (err e));

  let completed = ref None in
  (match send "work" with
   | Ok (Task t) ->
       check "message/send -> completed Task" (Task.state t = Completed) (Task_state.to_string t.status.state);
       check "status message" (Option.map Message.text t.status.message = Some "done") "";
       check_artifacts "message/send" t;
       completed := Some t
   | Ok (Message _) -> check "message/send -> Task" false "message"
   | Error e -> check "message/send -> Task" false (err e));

  let parts =
    [ Part.text "echo";
      Part.raw ~filename:"b.bin" ~media_type:"application/octet-stream" "\001\002\255";
      Part.url ~filename:"c.txt" ~media_type:"text/plain" "https://example.com/c.txt";
      Part.make (Data (`Assoc [ ("n", `Int 1) ]));
      Part.make (Data (`List [ `String "not"; `String "an object" ])) ]
  in
  (match send_message client (Message.user parts) with
   | Ok (Task t) -> (
       match artifact "echo" t with
       | Some a ->
           let strip (p : Part.t) = { p with metadata = None } in
           check "all part kinds round-trip through the agent" (List.map strip a.parts = parts)
             (Yojson.Safe.to_string (Codec_v0_3.artifact_to_json a))
       | None -> check "echo artifact" false "missing")
   | Ok _ -> check "echo" false "no task"
   | Error e -> check "echo" false (err e));

  (match send "input please" with
   | Ok (Task t) when Task.state t = Input_required -> (
       check "input-required" true "";
       match send_message client (Task.follow_up_text t "to Tokyo") with
       | Ok (Task t') ->
           check "follow-up continues the task"
             (t'.id = t.id && t'.context_id = t.context_id && Task.state t' = Completed)
             (Task_state.to_string t'.status.state)
       | Ok _ -> check "follow-up" false "message"
       | Error e -> check "follow-up" false (err e))
   | Ok _ -> check "input-required" false "unexpected response"
   | Error e -> check "input-required" false (err e));

  (match send "fail" with
   | Ok (Task t) -> check "failed task" (Task.state t = Failed) (Task_state.to_string t.status.state)
   | _ -> check "failed task" false "unexpected");

  (match !completed with
   | Some t -> (
       (match get_task client ~history_length:5 t.id with
        | Ok t' -> check "tasks/get" (t'.id = t.id && Task.state t' = Completed) (Task_state.to_string t'.status.state)
        | Error e -> check "tasks/get" false (err e));
       match cancel_task client t.id with
       | Error (Rpc_error { code = Task_not_cancelable; _ }) -> check "tasks/cancel terminal -> TaskNotCancelable" true ""
       | Ok t' -> check "tasks/cancel terminal" false (Task_state.to_string t'.status.state)
       | Error e -> check "tasks/cancel terminal" false (err e))
   | None -> check "tasks/get" false "setup failed");

  (match get_task client "does-not-exist" with
   | Error (Rpc_error { code = Task_not_found; _ }) -> check "tasks/get unknown -> TaskNotFound" true ""
   | Ok _ -> check "tasks/get unknown" false "found?"
   | Error e -> check "tasks/get unknown" false (err e));

  let immediately = Send_message_configuration.make ~return_immediately:true () in
  (match send ~configuration:immediately "slow" with
   | Ok (Task t) -> (
       check "blocking=false returns an active task" (Task_state.is_active (Task.state t))
         (Task_state.to_string t.status.state);
       match cancel_task client t.id with
       | Ok t' -> check "tasks/cancel running -> canceled" (Task.state t' = Canceled) (Task_state.to_string t'.status.state)
       | Error e -> check "tasks/cancel running" false (err e))
   | _ -> check "blocking=false" false "no task");

  (match send ~configuration:immediately "slow" with
   | Ok (Task t) -> (
       match wait_for_task client ~interval:0.5 ~timeout:20. t.id with
       | Ok t' -> check "wait_for_task polls to completion" (Task.state t' = Completed) (Task_state.to_string t'.status.state)
       | Error e -> check "wait_for_task" false (err e))
   | _ -> check "wait_for_task" false "no task");

  let stream name text expect =
    let n = ref 0 in
    match send_streaming_message client ~on_event:(fun _ -> incr n) (Message.user_text text) with
    | Ok o -> check (Printf.sprintf "%s (%d events)" name !n) (expect o) (describe o)
    | Error e -> check name false (err e)
  in
  stream "message/stream lifecycle" "work" (function
    | Outcome.Completed t -> check_artifacts "message/stream" t; true
    | _ -> false);
  stream "message/stream -> Message" "message hi" (function
    | Outcome.Message m -> Message.text m = "Direct: message hi"
    | _ -> false);
  stream "message/stream -> input-required" "input please" (function
    | Outcome.Input_required _ -> true
    | _ -> false);

  (match send ~configuration:immediately "slow" with
   | Ok (Task t) -> (
       match subscribe_to_task client t.id with
       | Ok (Outcome.Completed t') -> check "tasks/resubscribe -> completed" (t'.id = t.id) t'.id
       | Ok o -> check "tasks/resubscribe" false (describe o)
       | Error e -> check "tasks/resubscribe" false (err e))
   | _ -> check "tasks/resubscribe" false "setup failed");

  match send_message_and_wait client ~timeout:20. (Message.user_text "slow") with
  | Ok (Outcome.Completed _) -> check "send_message_and_wait" true ""
  | Ok o -> check "send_message_and_wait" false (describe o)
  | Error e -> check "send_message_and_wait" false (err e)

let () =
  let base = if Array.length Sys.argv > 1 then Sys.argv.(1) else "http://127.0.0.1:9993" in
  Eio_main.run (fun env ->
      run ~clock:(Eio.Stdenv.mono_clock env) ~transport:(Transport.cohttp (Eio.Stdenv.net env))
        (Uri.of_string base));
  finish ()
