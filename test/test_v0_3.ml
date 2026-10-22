open A2a_client

let json = Test_codec.json
let parse = Test_codec.parse
let decode = Test_codec.decode
let contains = Test_codec.contains
let run = Test_client.run
let ok = Test_client.ok
let params = Test_client.params
let meth = Test_client.meth
let header = Test_client.header

let get name = function Ok v -> v | Error e -> Alcotest.failf "%s: %s" name e

let test_message_wire_format () =
  let m =
    Message.user ~message_id:"m-1" ~context_id:"c-1" ~task_id:"t-1"
      [ Part.text "hi";
        Part.raw ~filename:"a.bin" ~media_type:"application/octet-stream" "\000\001";
        Part.url ~media_type:"image/png" (Uri.of_string "https://example.com/a.png");
        Part.data (`Assoc [ ("k", `Int 1) ]) ]
  in
  Alcotest.check json "message"
    (parse
       {|{"kind":"message","messageId":"m-1","contextId":"c-1","taskId":"t-1","role":"user",
          "parts":[{"kind":"text","text":"hi"},
                   {"kind":"file","file":{"bytes":"AAE=","name":"a.bin","mimeType":"application/octet-stream"}},
                   {"kind":"file","file":{"uri":"https://example.com/a.png","mimeType":"image/png"}},
                   {"kind":"data","data":{"k":1}}]}|})
    (Codec_v0_3.message_to_json m)

let test_request_params () =
  let m = Message.user ~message_id:"m" [ Part.text "x" ] in
  let req ?configuration () =
    { Send_message_request.tenant = Some "dropped"; message = m; configuration; metadata = None }
  in
  Alcotest.check json "no configuration"
    (parse {|{"message":{"kind":"message","messageId":"m","role":"user","parts":[{"kind":"text","text":"x"}]}}|})
    (Codec_v0_3.send_message_request_to_json (req ()));
  let conf c =
    match Codec_v0_3.send_message_request_to_json (req ~configuration:c ()) with
    | `Assoc kvs -> List.assoc "configuration" kvs
    | _ -> assert false
  in
  Alcotest.check json "blocking by default" (parse {|{"blocking":true}|})
    (conf (Send_message_configuration.make ()));
  Alcotest.check json "returnImmediately -> blocking false"
    (parse {|{"acceptedOutputModes":["text/plain"],"historyLength":3,"blocking":false}|})
    (conf (Send_message_configuration.make ~accepted_output_modes:[ "text/plain" ] ~history_length:3
             ~return_immediately:true ()));
  Alcotest.check json "tasks/get"
    (parse {|{"id":"t","historyLength":2}|})
    (Codec_v0_3.get_task_request_to_json { tenant = Some "x"; id = "t"; history_length = Some 2 });
  Alcotest.check json "tasks/resubscribe" (parse {|{"id":"t"}|})
    (Codec_v0_3.subscribe_to_task_request_to_json { tenant = Some "x"; id = "t" })

let test_data_part_compat () =
  let p = Part.data ~metadata:[ ("m", `Int 1) ] (`List [ `Int 1; `Int 2 ]) in
  let j = Codec_v0_3.part_to_json p in
  Alcotest.check json "wrapped"
    (parse {|{"kind":"data","data":{"value":[1,2]},"metadata":{"m":1,"data_part_compat":true}}|})
    j;
  (match decode Codec_v0_3.part (Yojson.Safe.to_string j) with
   | Ok { content = Data v; metadata; _ } ->
       Alcotest.check json "unwrapped" (`List [ `Int 1; `Int 2 ]) v;
       Alcotest.(check bool) "marker removed" true (metadata = Some [ ("m", `Int 1) ])
   | _ -> Alcotest.fail "data part");
  match decode Codec_v0_3.part {|{"kind":"data","data":{"value":1}}|} with
  | Ok { content = Data (`Assoc [ ("value", `Int 1) ]); metadata = None; _ } -> ()
  | _ -> Alcotest.fail "plain object"

let test_roundtrip () =
  let task =
    Task.make ~context_id:"c" ~id:"t"
      ~artifacts:[ Artifact.make ~artifact_id:"a" ~name:"n" [ Part.text "x"; Part.make (Data (`String "s")) ] ]
      ~history:[ Message.user ~message_id:"m" [ Part.raw "\255" ] ]
      ~metadata:[ ("k", `Bool true) ]
      (Task_status.make ~message:(Message.make ~message_id:"s" ~role:Agent [ Part.text "ok" ])
         ~timestamp:(Option.get (Ptime.of_float_s 1.7e9)) Input_required)
  in
  let events =
    [ Stream_response.Task task;
      Message (Message.make ~message_id:"r" ~role:Agent [ Part.url (Uri.of_string "u") ]);
      Status_update { task_id = "t"; context_id = Some "c"; status = Task_status.make Working; metadata = None };
      Artifact_update
        { task_id = "t"; context_id = Some "c"; artifact = Artifact.make ~artifact_id:"a" [ Part.text "y" ];
          append = true; last_chunk = true; metadata = Some [ ("x", `Null) ] } ]
  in
  List.iter
    (fun ev ->
      match decode Codec_v0_3.stream_response (Yojson.Safe.to_string (Codec_v0_3.stream_response_to_json ev)) with
      | Ok ev' -> Alcotest.(check bool) "roundtrip" true (ev = ev')
      | Error e -> Alcotest.fail e)
    events

let test_decode_task () =
  let t =
    get "task"
      (decode Codec_v0_3.task
         {|{"id":"363422be","contextId":"c295ea44","kind":"task",
            "status":{"state":"completed","timestamp":"2025-04-02T16:59:35.331844"},
            "artifacts":[{"artifactId":"9b69","name":"joke",
                          "parts":[{"kind":"text","text":"Why did the chicken..."},
                                   {"kind":"file","file":{"name":"x.png","mimeType":"image/png","bytes":"iVBO"}},
                                   {"kind":"file","file":{"uri":"https://e.com/f.pdf"}}]}],
            "history":[{"role":"user","parts":[{"kind":"text","text":"tell me a joke"}],
                        "messageId":"9229e770","kind":"message"}],
            "metadata":{}}|})
  in
  Alcotest.(check bool) "state" true (Task.state t = Completed);
  Alcotest.(check bool) "zone-less timestamp as UTC" true
    (Option.map (Ptime.to_rfc3339 ~frac_s:0) t.status.timestamp = Some "2025-04-02T16:59:35-00:00");
  (match (List.hd t.artifacts).parts with
   | [ { content = Text _; _ };
       { content = Raw _; filename = Some "x.png"; media_type = Some "image/png"; _ };
       { content = Url u; _ } ] when Uri.to_string u = "https://e.com/f.pdf" -> ()
   | _ -> Alcotest.fail "parts");
  Alcotest.(check bool) "history role" true ((List.hd t.history).role = User);
  List.iter
    (fun (name, st) ->
      match decode Codec_v0_3.task_state (Printf.sprintf "%S" name) with
      | Ok s -> Alcotest.(check bool) name true (s = st)
      | Error e -> Alcotest.fail e)
    [ ("submitted", Task_state.Submitted); ("working", Working); ("input-required", Input_required);
      ("completed", Completed); ("canceled", Canceled); ("failed", Failed); ("rejected", Rejected);
      ("auth-required", Auth_required); ("unknown", Unspecified) ]

let test_decode_errors () =
  let bad d s sub = Test_codec.expect_error ~contains:sub (decode d s) in
  bad Codec_v0_3.task_state {|"TASK_STATE_WORKING"|} "unknown TaskState";
  bad Codec_v0_3.stream_response {|{"kind":"weird","id":"t"}|} "unknown result kind";
  bad Codec_v0_3.part {|{"kind":"video"}|} "unknown Part kind";
  bad Codec_v0_3.part {|{"kind":"file","file":{"bytes":"AA==","uri":"u"}}|} "both";
  bad Codec_v0_3.part {|{"kind":"file","file":{"name":"x"}}|} "neither";
  bad Codec_v0_3.part {|{"kind":"file","file":{"bytes":"!!"}}|} "$.file.bytes";
  bad Codec_v0_3.message {|{"messageId":"m","role":"ROLE_USER","parts":[]}|} "unknown Role";
  bad Codec_v0_3.send_message_response
    {|{"kind":"status-update","taskId":"t","contextId":"c","status":{"state":"working"},"final":false}|}
    "Task or a Message";
  match decode Codec_v0_3.stream_response {|{"taskId":"t","contextId":"c","status":{"state":"working"}}|} with
  | Ok (Status_update _) -> ()
  | _ -> Alcotest.fail "inferred status-update"

let v03_card =
  {|{
  "protocolVersion": "0.3.0",
  "name": "GeoSpatial Route Planner Agent",
  "description": "Provides advanced route planning.",
  "url": "https://georoute-agent.example.com/a2a/v1",
  "preferredTransport": "JSONRPC",
  "additionalInterfaces" : [
    {"url": "https://georoute-agent.example.com/a2a/v1", "transport": "JSONRPC"},
    {"url": "https://georoute-agent.example.com/a2a/grpc", "transport": "GRPC"},
    {"url": "https://georoute-agent.example.com/a2a/json", "transport": "HTTP+JSON"}
  ],
  "provider": {"organization": "Example Geo Services Inc.", "url": "https://www.examplegeoservices.com"},
  "iconUrl": "https://georoute-agent.example.com/icon.png",
  "version": "1.2.0",
  "capabilities": {"streaming": true, "pushNotifications": true, "stateTransitionHistory": false},
  "securitySchemes": {
    "google": {"type": "openIdConnect", "openIdConnectUrl": "https://accounts.google.com/.well-known/openid-configuration"},
    "key": {"type": "apiKey", "in": "header", "name": "X-API-Key"},
    "oauth": {"type": "oauth2", "flows": {
      "clientCredentials": {"tokenUrl": "https://auth.example.com/token", "scopes": {"read": "Read"}},
      "authorizationCode": {"authorizationUrl": "https://auth.example.com/a", "tokenUrl": "https://auth.example.com/t", "scopes": {}}}}
  },
  "security": [{ "google": ["openid", "profile", "email"] }],
  "defaultInputModes": ["application/json", "text/plain"],
  "defaultOutputModes": ["application/json", "image/png"],
  "skills": [{"id": "route-optimizer-traffic", "name": "Traffic-Aware Route Optimizer",
              "description": "Calculates the optimal driving route.", "tags": ["maps"],
              "security": [{"key": []}]}],
  "supportsAuthenticatedExtendedCard": true,
  "signatures": [{"protected": "eyJhbGciOiJFUzI1NiJ9", "signature": "QFdk"}]
}|}

let test_agent_card () =
  let card = get "card" (decode Codec.agent_card v03_card) in
  let ifaces =
    let show to_string = function Known x -> to_string x | Unknown s -> "?" ^ s in
    List.map
      (fun (i : Agent_interface.t) ->
        ( Uri.to_string i.url,
          show Protocol_binding.to_string i.protocol_binding,
          show Protocol_version.to_string i.protocol_version ))
      card.supported_interfaces
  in
  Alcotest.(check (list (triple string string string))) "interfaces (main first, deduplicated)"
    [ ("https://georoute-agent.example.com/a2a/v1", "JSONRPC", "0.3");
      ("https://georoute-agent.example.com/a2a/grpc", "?GRPC", "0.3");
      ("https://georoute-agent.example.com/a2a/json", "HTTP+JSON", "0.3") ]
    ifaces;
  Alcotest.(check bool) "extended card" true card.capabilities.extended_agent_card;
  Alcotest.(check (list (list (pair string (list string))))) "security"
    [ [ ("google", [ "openid"; "profile"; "email" ]) ] ] card.security_requirements;
  Alcotest.(check (list (list (pair string (list string))))) "skill security"
    [ [ ("key", []) ] ] (List.hd card.skills).security_requirements;
  (match List.assoc "key" card.security_schemes with
   | Security_scheme.Api_key { location = "header"; name = "X-API-Key"; _ } -> ()
   | _ -> Alcotest.fail "apiKey");
  (match List.assoc "google" card.security_schemes with
   | Security_scheme.Open_id_connect _ -> ()
   | _ -> Alcotest.fail "openIdConnect");
  (match List.assoc "oauth" card.security_schemes with
   | Security_scheme.Oauth2 { flows = Some (Oauth_flow.Authorization_code _); _ } -> ()
   | _ -> Alcotest.fail "oauth2");
  match select_interface card with
  | Ok i -> Alcotest.(check string) "0.3 JSON-RPC" "https://georoute-agent.example.com/a2a/v1" (Uri.to_string i.url)
  | Error e -> Alcotest.fail (Error.to_string e)

let test_negotiation () =
  let card s = get "card" (decode Codec.agent_card s) in
  let both =
    card
      {|{"name":"a","supportedInterfaces":[
          {"url":"http://h/v03","protocolBinding":"JSONRPC","protocolVersion":"0.3"},
          {"url":"http://h/v1","protocolBinding":"JSONRPC","protocolVersion":"1.0"}]}|}
  in
  let url ?protocol_version c =
    match select_interface ?protocol_version c with
    | Ok i -> (Uri.to_string i.url)
    | Error e -> Alcotest.fail (Error.to_string e)
  in
  Alcotest.(check string) "prefers 1.0" "http://h/v1" (url both);
  Alcotest.(check string) "pinned 0.3" "http://h/v03" (url ~protocol_version:V0_3 both);
  let mixed =
    card
      {|{"name":"a","url":"http://h/legacy","protocolVersion":"0.3.0",
         "supportedInterfaces":[{"url":"http://h/v1","protocolBinding":"JSONRPC","protocolVersion":"1.0"}]}|}
  in
  Alcotest.(check int) "only supportedInterfaces" 1 (List.length mixed.supported_interfaces);
  let bare = card {|{"name":"a","url":"http://h/x"}|} in
  match bare.supported_interfaces with
  | [ { protocol_binding = Known Jsonrpc; protocol_version = Known V0_3; _ } ] -> ()
  | _ -> Alcotest.fail "defaults"

let v03_task ?(state = "working") id : Yojson.Safe.t =
  `Assoc
    [ ("kind", `String "task"); ("id", `String id); ("contextId", `String "c");
      ("status", `Assoc [ ("state", `String state) ]) ]

let v03_client ?extensions ~clock transport =
  create ~clock ~transport ?extensions ~tenant:"never-sent" ~protocol:V0_3
    (Uri.of_string "http://agent.test/a2a")

let test_client_unary () =
  run @@ fun clock ->
  let transport, rec_ =
    Mock.transport ~clock (fun req ->
        let id = Mock.request_id req in
        match meth req with
        | "message/send" ->
            Mock.json_reply
              (Mock.result_envelope ~id
                 (`Assoc
                    [ ("kind", `String "message"); ("messageId", `String "r"); ("role", `String "agent");
                      ("parts", `List [ `Assoc [ ("kind", `String "text"); ("text", `String "pong") ] ]) ]))
        | "tasks/get" -> Mock.json_reply (Mock.result_envelope ~id (v03_task ~state:"completed" "t-1"))
        | "tasks/cancel" -> Mock.json_reply (Mock.error_envelope ~id:(`String id) (-32002) "not cancelable")
        | m -> Alcotest.failf "unexpected method %s" m)
  in
  let client = v03_client ~extensions:[ "urn:x" ] ~clock transport in
  Alcotest.(check bool) "version" true (version client = V0_3);
  (match ok "send" (send_text client "ping") with
   | Send_message_response.Message m -> Alcotest.(check string) "reply" "pong" (Message.text m)
   | Task _ -> Alcotest.fail "expected message");
  let req = List.hd rec_.requests in
  Alcotest.(check (option string)) "A2A-Version" (Some "0.3") (header "a2a-version" req);
  Alcotest.(check (option string)) "A2A-Extensions" (Some "urn:x") (header "a2a-extensions" req);
  Alcotest.(check (option string)) "X-A2A-Extensions" (Some "urn:x") (header "x-a2a-extensions" req);
  let p = params req in
  Alcotest.(check bool) "no tenant" true (match p with `Assoc kvs -> not (List.mem_assoc "tenant" kvs) | _ -> false);
  Alcotest.(check bool) "kind" true (Test_client.member [ "message"; "kind" ] p = `String "message");
  Alcotest.(check bool) "role" true (Test_client.member [ "message"; "role" ] p = `String "user");
  let t = ok "get" (get_task client ~history_length:1 "t-1") in
  Alcotest.(check bool) "completed" true (Task.state t = Completed);
  Alcotest.check json "get params" (parse {|{"id":"t-1","historyLength":1}|}) (params (List.hd rec_.requests));
  (match cancel_task client "t-1" with
   | Error (Error.Rpc_error { code = Task_not_cancelable; _ }) -> ()
   | _ -> Alcotest.fail "expected TaskNotCancelable");
  Alcotest.(check (list string)) "methods" [ "message/send"; "tasks/get"; "tasks/cancel" ]
    (List.rev_map meth rec_.requests)

let test_client_streaming () =
  run @@ fun clock ->
  let transport, rec_ =
    Mock.transport ~clock (fun req ->
        let id = Mock.request_id req in
        let ev j = Mock.sse_data (Mock.result_envelope ~id (parse j)) in
        let text =
          ev {|{"id":"225d","contextId":"0521","status":{"state":"submitted","timestamp":"2025-04-02T16:59:25.331844"},
               "history":[{"role":"user","parts":[{"kind":"text","text":"write a long paper"}],"messageId":"bbb7","taskId":"225d","contextId":"0521"}],
               "kind":"task","metadata":{}}|}
          ^ ev {|{"taskId":"225d","contextId":"0521","artifact":{"artifactId":"9b69","parts":[{"kind":"text","text":"<section 1...>"}]},
                 "append":false,"lastChunk":false,"kind":"artifact-update"}|}
          ^ ev {|{"taskId":"225d","contextId":"0521","artifact":{"artifactId":"9b69","parts":[{"kind":"text","text":"<section 2...>"}]},
                 "append":true,"lastChunk":true,"kind":"artifact-update"}|}
          ^ ev {|{"taskId":"225d","contextId":"0521","status":{"state":"completed","timestamp":"2025-04-02T16:59:35.331844"},
                 "final":true,"kind":"status-update"}|}
        in
        let half = String.length text / 2 in
        Mock.sse_reply
          [ Mock.Chunk (String.sub text 0 half); Mock.Sleep 0.1;
            Mock.Chunk (String.sub text half (String.length text - half)); Mock.Block ])
  in
  let client = v03_client ~clock transport in
  let n = ref 0 in
  (match ok "stream" (send_streaming_message client ~on_event:(fun _ -> incr n) (Message.user_text "go")) with
   | Outcome.Completed t ->
       Alcotest.(check int) "events" 4 !n;
       Alcotest.(check string) "appended" "<section 1...><section 2...>" (Artifact.text (List.hd t.artifacts))
   | _ -> Alcotest.fail "expected Completed");
  Alcotest.(check string) "method" "message/stream" (meth (List.hd rec_.requests));
  Alcotest.(check (option string)) "accept" (Some "text/event-stream") (header "accept" (List.hd rec_.requests))

let test_client_resubscribe () =
  run @@ fun clock ->
  let transport, rec_ =
    Mock.transport ~clock (fun req ->
        let id = Mock.request_id req in
        Mock.sse_reply
          [ Mock.Chunk
              (Mock.sse_data
                 (Mock.result_envelope ~id
                    (parse
                       {|{"kind":"status-update","taskId":"t-1","contextId":"c","final":true,
                          "status":{"state":"input-required","message":{"kind":"message","messageId":"q","role":"agent",
                                    "parts":[{"kind":"text","text":"Where to?"}]}}}|}))) ])
  in
  let client = v03_client ~clock transport in
  (match ok "resubscribe" (subscribe_to_task client "t-1") with
   | Outcome.Input_required t -> Alcotest.(check string) "question" "Where to?" (Message.text (Option.get t.status.message))
   | _ -> Alcotest.fail "expected Input_required");
  let req = List.hd rec_.requests in
  Alcotest.(check string) "method" "tasks/resubscribe" (meth req);
  Alcotest.check json "params" (parse {|{"id":"t-1"}|}) (params req)

let test_client_polling () =
  run @@ fun clock ->
  let polls = ref 0 in
  let transport, _ =
    Mock.transport ~clock (fun req ->
        let id = Mock.request_id req in
        match meth req with
        | "message/send" -> Mock.json_reply (Mock.result_envelope ~id (v03_task ~state:"submitted" "t-1"))
        | "tasks/get" ->
            incr polls;
            let state = if !polls < 3 then "working" else "completed" in
            Mock.json_reply (Mock.result_envelope ~id (v03_task ~state "t-1"))
        | m -> Alcotest.failf "unexpected %s" m)
  in
  let client = v03_client ~clock transport in
  match ok "wait" (send_message_and_wait client ~timeout:60. (Message.user_text "x")) with
  | Outcome.Completed _ -> Alcotest.(check int) "polls" 3 !polls
  | _ -> Alcotest.fail "expected Completed"

let test_connect_v03_card () =
  run @@ fun clock ->
  let transport, rec_ =
    Mock.transport ~clock (fun req ->
        match req.meth with
        | `GET -> Mock.json_reply v03_card
        | _ -> Mock.json_reply (Mock.result_envelope ~id:(Mock.request_id req) (v03_task ~state:"completed" "t")))
  in
  let client = ok "connect" (connect ~clock ~transport (Uri.of_string "https://georoute-agent.example.com")) in
  Alcotest.(check bool) "negotiated 0.3" true (version client = V0_3);
  Alcotest.(check string) "endpoint" "https://georoute-agent.example.com/a2a/v1" (Uri.to_string (endpoint client));
  ignore (ok "send" (send_text client "hi"));
  Alcotest.(check string) "0.3 method" "message/send" (meth (List.hd rec_.requests));
  match connect ~protocol_version:V1_0 ~clock ~transport (Uri.of_string "https://georoute-agent.example.com") with
  | Error (Error.No_compatible_interface _) -> ()
  | _ -> Alcotest.fail "expected No_compatible_interface"

let tests =
  [ ("message wire format", `Quick, test_message_wire_format);
    ("request params", `Quick, test_request_params);
    ("non-object data parts", `Quick, test_data_part_compat);
    ("roundtrip", `Quick, test_roundtrip);
    ("decode task (spec samples)", `Quick, test_decode_task);
    ("decode errors", `Quick, test_decode_errors);
    ("Agent Card (spec 5.7)", `Quick, test_agent_card);
    ("version negotiation", `Quick, test_negotiation);
    ("client unary calls", `Quick, test_client_unary);
    ("client streaming (spec 9.3)", `Quick, test_client_streaming);
    ("client tasks/resubscribe", `Quick, test_client_resubscribe);
    ("client polling", `Quick, test_client_polling);
    ("connect to a 0.3 agent", `Quick, test_connect_v03_card) ]
