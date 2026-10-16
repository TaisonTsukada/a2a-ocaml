open A2a_client
open Report

module Id_gen = struct
  let n = ref 0
  let next () = incr n; Printf.sprintf "%d-%.0f" !n (Unix.gettimeofday () *. 1000.)
end

let xfail name = function
  | Error.Rpc_error { code = Invalid_agent_response; message; _ } ->
      Printf.printf "XFAIL %s: reference agent error: %s\n%!" name message;
      true
  | _ -> false

let msg prefix text = Message.user ~message_id:(prefix ^ "-" ^ Id_gen.next ()) [ Part.text text ]

let expect_task name r pred =
  match r with
  | Ok (Send_message_response.Task t) -> check name (pred t) (Task_state.to_string t.status.state)
  | Ok (Message m) -> check name false ("got message " ^ Message.text m)
  | Error e -> check name false (Error.to_string e)

let run ?protocol_version ?bindings ~clock ~transport base =
  let client =
    match connect ?bindings ~clock ~transport base with
    | Ok c -> c
    | Error e -> failwith ("connect: " ^ Error.to_string e)
  in
  let client =
    match protocol_version with
    | Some v when v <> version client ->
        create ~clock ~transport ~protocol_version:v ?card:(agent_card client) (A2a_client.endpoint client)
    | _ -> client
  in
  Printf.printf "protocol %s\n%!" (Protocol_version.to_string (version client));
  let card = Option.get (agent_card client) in
  check "Agent Card fetched and parsed" (card.name <> "") card.name;
  check (Protocol_binding.to_string (A2a_client.binding client) ^ " endpoint selected") true (Uri.to_string (A2a_client.endpoint client));

  (match send_message client (msg "tck-message-response" "hi") with
   | Ok (Send_message_response.Message m) ->
       check "SendMessage -> Message" (Message.text m = "Direct message response") (Message.text m)
   | Ok (Task t) -> check "SendMessage -> Message" false ("got task " ^ t.id)
   | Error e when xfail "SendMessage -> Message" e -> ()
   | Error e -> check "SendMessage -> Message" false (Error.to_string e));

  expect_task "SendMessage -> completed Task" (send_message client (msg "tck-complete-task" "hi"))
    (fun t -> Task.state t = Completed);

  let artifact_part prefix =
    match send_message client (msg prefix "hi") with
    | Ok (Send_message_response.Task { artifacts = [ { parts = [ p ]; _ } ]; _ }) -> Some p
    | _ -> None
  in
  (match artifact_part "tck-artifact-text" with
   | Some { content = Text "Generated text content"; _ } -> check "text artifact" true ""
   | _ -> check "text artifact" false "unexpected");
  (match artifact_part "tck-artifact-file" with
   | Some { content = Raw "tck"; filename = Some "output.txt"; media_type = Some "text/plain"; _ } ->
       check "raw (base64) artifact" true ""
   | _ -> check "raw (base64) artifact" false "unexpected");
  (match artifact_part "tck-artifact-file-url" with
   | Some { content = Url "https://example.com/output.txt"; _ } -> check "url artifact" true ""
   | _ -> check "url artifact" false "unexpected");
  (match artifact_part "tck-artifact-data" with
   | Some { content = Data (`Assoc kvs); _ } ->
       check "data artifact" (List.assoc_opt "key" kvs = Some (`String "value")) "content"
   | _ -> check "data artifact" false "unexpected");

  (match send_message client (msg "tck-input-required" "book a flight") with
   | Ok (Send_message_response.Task t) when Task.state t = Input_required ->
       check "input-required state" true "";
       let follow = Task.follow_up t [ Part.text "from SFO" ] in
       let follow = { follow with message_id = "tck-complete-task-" ^ Id_gen.next () } in
       expect_task "follow-up keeps taskId/contextId" (send_message client follow) (fun t' ->
           t'.id = t.id && t'.context_id = t.context_id)
   | Ok _ -> check "input-required state" false "unexpected response"
   | Error e -> check "input-required state" false (Error.to_string e));

  (match send_message client (msg "tck-reject-task" "x") with
   | Error (Error.Rpc_error e) -> check "agent error -> Rpc_error" true (Error.Code.to_string e.code)
   | Ok (Send_message_response.Task t) ->
       check "agent error -> failed/rejected task" (Task.is_terminal t) (Task_state.to_string t.status.state)
   | r ->
       check "agent error handled" false
         (match r with Error e -> Error.to_string e | Ok _ -> "message"));

  (match send_message client (msg "tck-complete-task" "hi") with
   | Ok (Send_message_response.Task t) -> (
       match get_task client ~history_length:10 t.id with
       | Ok t' -> check "GetTask" (t'.id = t.id && Task.state t' = Completed) (Task_state.to_string t'.status.state)
       | Error e -> check "GetTask" false (Error.to_string e))
   | _ -> check "GetTask" false "setup failed");

  (match get_task client "does-not-exist" with
   | Error (Error.Rpc_error { code = Task_not_found; _ }) -> check "GetTask unknown -> TaskNotFoundError" true ""
   | Ok _ -> check "GetTask unknown -> TaskNotFoundError" false "found?"
   | Error e -> check "GetTask unknown -> TaskNotFoundError" false (Error.to_string e));

  (match send_message client (msg "tck-complete-task" "hi") with
   | Ok (Send_message_response.Task t) -> (
       match cancel_task client t.id with
       | Error (Error.Rpc_error { code = Task_not_cancelable; _ }) -> check "CancelTask terminal -> TaskNotCancelableError" true ""
       | Ok t' -> check "CancelTask terminal -> TaskNotCancelableError" false (Task_state.to_string t'.status.state)
       | Error e -> check "CancelTask terminal -> TaskNotCancelableError" false (Error.to_string e))
   | _ -> check "CancelTask terminal" false "setup failed");

  let config = Send_message_configuration.make ~return_immediately:true () in
  (match send_message client ~configuration:config (msg "test-resubscribe-message-id" "slow") with
   | Ok (Send_message_response.Task t) -> (
       match cancel_task client t.id with
       | Ok t' -> check "CancelTask running -> canceled" (Task.state t' = Canceled) (Task_state.to_string t'.status.state)
       | Error e -> check "CancelTask running" false (Error.to_string e))
   | Ok _ -> check "CancelTask running" false "no task"
   | Error e -> check "CancelTask running" false (Error.to_string e));

  (match send_message client ~configuration:config (msg "test-resubscribe-message-id" "slow") with
   | Ok (Send_message_response.Task t) -> (
       check "returnImmediately -> active task" (Task_state.is_active (Task.state t)) (Task_state.to_string t.status.state);
       match wait_for_task client ~interval:0.5 ~timeout:20. t.id with
       | Ok t' -> check "wait_for_task polls to completion" (Task.state t' = Completed) (Task_state.to_string t'.status.state)
       | Error e -> check "wait_for_task" false (Error.to_string e))
   | _ -> check "returnImmediately" false "no task");

  let stream name prefix expect =
    let kinds = ref [] in
    let r =
      send_streaming_message client (msg prefix "stream")
        ~on_event:(fun ev ->
          kinds :=
            (match ev with
             | Stream_response.Task _ -> "task"
             | Message _ -> "message"
             | Status_update e -> "status(" ^ Task_state.to_string e.status.state ^ ")"
             | Artifact_update _ -> "artifact")
            :: !kinds)
    in
    let kinds = String.concat " " (List.rev !kinds) in
    match r with
    | Ok o -> check name (expect o) (kinds ^ " => " ^ describe o)
    | Error e when xfail name e -> ()
    | Error e -> check name false (kinds ^ " => " ^ Error.to_string e)
  in
  stream "SendStreamingMessage lifecycle" "tck-stream-001" (function
    | Outcome.Completed t -> List.exists (fun a -> Artifact.text a = "Stream hello from TCK") t.artifacts
    | _ -> false);
  stream "SendStreamingMessage chunked artifact (append)" "tck-stream-artifact-chunked" (function
    | Outcome.Completed { artifacts = [ a ]; _ } -> Artifact.text a = "chunk-1 chunk-2"
    | _ -> false);
  stream "SendStreamingMessage message-only" "tck-message-response" (function
    | Outcome.Message m -> Message.text m = "Direct message response"
    | _ -> false);
  stream "SendStreamingMessage input-required" "tck-input-required" (function
    | Outcome.Input_required _ -> true
    | _ -> false);

  (match send_message client ~configuration:config (msg "test-resubscribe-message-id" "slow") with
   | Ok (Send_message_response.Task t) -> (
       match subscribe_to_task client t.id with
       | Ok (Outcome.Completed t') -> check "SubscribeToTask -> completed" (t'.id = t.id) t'.id
       | Ok o -> check "SubscribeToTask" false (describe o)
       | Error e -> check "SubscribeToTask" false (Error.to_string e))
   | _ -> check "SubscribeToTask" false "setup failed");

  (match send_message_and_wait client ~timeout:20. (msg "tck-complete-task" "hi") with
   | Ok (Outcome.Completed _) -> check "send_message_and_wait" true ""
   | Ok o -> check "send_message_and_wait" false (describe o)
   | Error e -> check "send_message_and_wait" false (Error.to_string e))

let () =
  let base = if Array.length Sys.argv > 1 then Sys.argv.(1) else "http://localhost:9999" in
  let protocol_version, bindings =
    if Array.length Sys.argv > 2 then
      let arg = Sys.argv.(2) in
      match (Protocol_binding.of_string arg, Protocol_version.of_string arg) with
      | Some b, _ -> (None, Some [ b ])
      | None, Some v -> (Some v, None)
      | None, None -> failwith ("expected a protocol version or binding, got " ^ arg)
    else (None, None)
  in
  Eio_main.run (fun env ->
      run ?protocol_version ?bindings ~clock:(Eio.Stdenv.mono_clock env)
        ~transport:(Transport.cohttp (Eio.Stdenv.net env))
        (Uri.of_string base));
  finish ()
