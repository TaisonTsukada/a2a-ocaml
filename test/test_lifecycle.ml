open A2a_client

(* The list-based fold from 0.2.2, kept as the reference semantics. *)
module Reference = struct
  let replace_or_add_artifact (artifacts : Artifact.t list) (a : Artifact.t) =
    if List.exists (fun (x : Artifact.t) -> x.artifact_id = a.artifact_id) artifacts then
      List.map (fun (x : Artifact.t) -> if x.artifact_id = a.artifact_id then a else x) artifacts
    else artifacts @ [ a ]

  let apply_artifact_update (task : Task.t) (e : Task_artifact_update_event.t) =
    let a = e.artifact in
    let artifacts =
      match List.find_opt (fun (x : Artifact.t) -> x.artifact_id = a.artifact_id) task.artifacts with
      | Some existing when e.append ->
          let merged =
            { existing with
              parts = existing.parts @ a.parts;
              metadata = (match a.metadata with Some _ -> a.metadata | None -> existing.metadata) }
          in
          replace_or_add_artifact task.artifacts merged
      | _ -> replace_or_add_artifact task.artifacts a
    in
    { task with artifacts }

  let merge_metadata old upd =
    match (old, upd) with
    | None, m | m, None -> m
    | Some o, Some u -> Some (List.filter (fun (k, _) -> not (List.mem_assoc k u)) o @ u)

  let apply_status_update (task : Task.t) (e : Task_status_update_event.t) =
    let history =
      match e.status.message with
      | Some m
        when not
               (List.exists
                  (fun (h : Message.t) -> h.message_id = m.message_id && m.message_id <> "")
                  task.history) ->
          task.history @ [ m ]
      | _ -> task.history
    in
    { task with
      status = e.status;
      history;
      metadata = merge_metadata task.metadata e.metadata;
      context_id =
        (match task.context_id with None when e.context_id <> "" -> Some e.context_id | c -> c) }

  let apply (current : Task.t option) (ev : Stream_response.t) : Task.t option =
    match ev with
    | Task t -> Some t
    | Message _ -> current
    | Status_update e -> (
        match current with
        | Some t when t.id = e.task_id -> Some (apply_status_update t e)
        | _ ->
            let context_id = if e.context_id = "" then None else Some e.context_id in
            Some (apply_status_update (Task.make ?context_id ~id:e.task_id e.status) e))
    | Artifact_update e -> (
        match current with
        | Some t when t.id = e.task_id -> Some (apply_artifact_update t e)
        | _ ->
            let context_id = if e.context_id = "" then None else Some e.context_id in
            Some
              (apply_artifact_update
                 (Task.make ?context_id ~id:e.task_id (Task_status.make Task_state.Unspecified))
                 e))
end

let msg ?(id = "") text = Message.make ~message_id:id ~role:Agent [ Part.text text ]

let status ?(task = "t-1") ?(ctx = "ctx-1") ?message ?metadata state =
  Stream_response.Status_update
    { task_id = task; context_id = ctx; status = Task_status.make ?message state; metadata }

let artifact ?(task = "t-1") ?(append = false) ?metadata ?name id text =
  Stream_response.Artifact_update
    { task_id = task; context_id = "ctx-1";
      artifact = Artifact.make ?name ?metadata ~artifact_id:id [ Part.text text ];
      append; last_chunk = false; metadata = None }

let events =
  let base =
    Task.make ~context_id:"ctx-1" ~id:"t-1"
      ~history:[ msg ~id:"h1" "earlier" ]
      ~artifacts:
        [ Artifact.make ~artifact_id:"d" [ Part.text "x" ];
          Artifact.make ~artifact_id:"k" [ Part.text "k" ];
          Artifact.make ~artifact_id:"d" [ Part.text "y" ] ]
      (Task_status.make Submitted)
  in
  [ status ~task:"t-0" ~ctx:"" Working;
    Stream_response.Task base;
    status ~message:(msg ~id:"h1" "dup of base history") Working;
    status ~message:(msg ~id:"m1" "one") ~metadata:[ ("a", `Int 1) ] Working;
    status ~message:(msg ~id:"m1" "dup") ~metadata:[ ("a", `Int 2); ("b", `Int 3) ] Working;
    status ~message:(msg "no id") Working;
    status ~message:(msg "no id again") Working;
    Stream_response.Message (msg ~id:"r" "direct");
    artifact ~append:true "d" "z";
    artifact ~name:"report" "a1" "Hello, ";
    artifact ~append:true "a1" "world";
    artifact ~append:true ~metadata:[ ("m", `Bool true) ] "a1" "!";
    artifact "k" "replaced";
    artifact ~append:true "new" "appended to nothing";
    artifact ~task:"t-2" "x" "other task";
    status ~task:"t-2" ~message:(msg ~id:"m2" "two") Completed;
    status ~task:"t-2" Completed ]

let task_eq = Alcotest.testable (fun ppf _ -> Format.pp_print_string ppf "<task>") ( = )

let test_matches_reference () =
  ignore
    (List.fold_left
       (fun (i, cur, expected) ev ->
         let cur = Lifecycle.apply cur ev and expected = Reference.apply expected ev in
         Alcotest.(check (option task_eq)) (Printf.sprintf "after event %d" i) expected cur;
         (i + 1, cur, expected))
       (0, None, None) events)

let test_stream_matches_reference () =
  Eio_mock.Backend.run_full @@ fun env ->
  let clock = env#mono_clock in
  (* Only the events from the [Task] up to before the switch to t-2, so the
     stream stays on one task and ends when it completes. *)
  let evs =
    List.filteri (fun i _ -> i >= 1 && i <= 13) events
    @ [ status ~message:(msg ~id:"m9" "done") Completed ]
  in
  let transport, _ =
    Mock.transport ~clock (fun req ->
        let id = Mock.request_id req in
        Mock.sse_reply
          (List.map
             (fun ev ->
               Mock.Chunk
                 (Mock.sse_data (Mock.result_envelope ~id (Codec.stream_response_to_json ev))))
             evs))
  in
  let client = create ~clock ~transport (Uri.of_string "http://agent.test/a2a") in
  let decoded = ref [] in
  match send_streaming_message client (Message.user_text "go") ~on_event:(fun ev -> decoded := ev :: !decoded) with
  | Ok (Outcome.Completed t) ->
      let expected = List.fold_left Reference.apply None (List.rev !decoded) in
      Alcotest.(check (option task_eq)) "final task" expected (Some t);
      Alcotest.(check int) "history" 5 (List.length t.history)
  | Ok _ -> Alcotest.fail "expected Completed"
  | Error e -> Alcotest.fail (Error.to_string e)

(* Many status messages, as A2UI agents send. 0.2.2 copied the whole
   history on each one (quadratic); timing is not asserted to keep CI
   stable. *)
let test_long_stream () =
  Eio_mock.Backend.run_full @@ fun env ->
  let clock = env#mono_clock in
  let n = 20_000 in
  let body id =
    let b = Buffer.create (n * 200) in
    for i = 1 to n do
      let ev =
        if i = n then status Completed
        else status ~message:(msg ~id:(string_of_int i) "ui") Working
      in
      Buffer.add_string b
        (Mock.sse_data (Mock.result_envelope ~id (Codec.stream_response_to_json ev)))
    done;
    Buffer.contents b
  in
  let transport, _ =
    Mock.transport ~clock (fun req -> Mock.sse_reply [ Mock.Chunk (body (Mock.request_id req)) ])
  in
  let client = create ~clock ~transport (Uri.of_string "http://agent.test/a2a") in
  (match send_streaming_message client (Message.user_text "go") with
   | Ok (Outcome.Completed t) -> Alcotest.(check int) "history" (n - 1) (List.length t.history)
   | Ok _ -> Alcotest.fail "expected Completed"
   | Error e -> Alcotest.fail (Error.to_string e))

let tests =
  [ Alcotest.test_case "apply matches the reference fold" `Quick test_matches_reference;
    Alcotest.test_case "streaming fold matches the reference" `Quick test_stream_matches_reference;
    Alcotest.test_case "long stream of status messages" `Quick test_long_stream ]
