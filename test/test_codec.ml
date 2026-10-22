open A2a_client

let json = Alcotest.testable Yojson.Safe.pp Yojson.Safe.equal
let parse = Yojson.Safe.from_string

let decode d s = Codec.decode_string d s

let contains ~sub s =
  let n = String.length sub and m = String.length s in
  let rec go i = i + n <= m && (String.sub s i n = sub || go (i + 1)) in
  go 0

let expect_error ~contains:sub = function
  | Ok _ -> Alcotest.fail "expected a decode error"
  | Error msg ->
      if not (contains ~sub msg) then
        Alcotest.failf "error %S does not mention %S" msg sub

let sample_message =
  Message.user ~message_id:"m-1" ~context_id:"ctx-1" ~task_id:"task-1"
    ~metadata:[ ("k", `Int 1) ]
    ~reference_task_ids:[ "t-0" ]
    [ Part.text "hello";
      Part.raw ~filename:"a.bin" ~media_type:"application/octet-stream" "\000\001\xff";
      Part.url ~media_type:"image/png" (Uri.of_string "https://example.com/a.png");
      Part.data (`Assoc [ ("x", `List [ `Int 1; `Null ]) ]) ]

let test_message_roundtrip () =
  let j = Codec.message_to_json sample_message in
  match decode Codec.message (Yojson.Safe.to_string j) with
  | Ok back -> Alcotest.(check bool) "roundtrip" true (back = sample_message)
  | Error e -> Alcotest.fail e

let test_message_wire_format () =
  let j = Codec.message_to_json sample_message in
  Alcotest.check json "wire"
    (parse
       {|{"messageId":"m-1","contextId":"ctx-1","taskId":"task-1","role":"ROLE_USER",
          "parts":[{"text":"hello"},
                   {"raw":"AAH/","filename":"a.bin","mediaType":"application/octet-stream"},
                   {"url":"https://example.com/a.png","mediaType":"image/png"},
                   {"data":{"x":[1,null]},"mediaType":"application/json"}],
          "metadata":{"k":1},"referenceTaskIds":["t-0"]}|})
    j

let test_request_omits_defaults () =
  let req =
    { Send_message_request.tenant = None;
      message = Message.user_text ~message_id:"m" "hi";
      configuration = Some (Send_message_configuration.make ());
      metadata = None }
  in
  Alcotest.check json "minimal"
    (parse {|{"message":{"messageId":"m","role":"ROLE_USER","parts":[{"text":"hi"}]},"configuration":{}}|})
    (Codec.send_message_request_to_json req);
  let req =
    { req with
      tenant = Some "acme";
      configuration =
        Some
          (Send_message_configuration.make ~accepted_output_modes:[ "text/plain" ]
             ~history_length:0 ~return_immediately:true ()) }
  in
  Alcotest.check json "full config"
    (parse
       {|{"tenant":"acme","message":{"messageId":"m","role":"ROLE_USER","parts":[{"text":"hi"}]},
          "configuration":{"acceptedOutputModes":["text/plain"],"historyLength":0,"returnImmediately":true}}|})
    (Codec.send_message_request_to_json req)

let spec_task =
  {|{
    "task": {
      "id": "task-uuid",
      "contextId": "context-uuid",
      "status": {"state": "TASK_STATE_COMPLETED", "timestamp": "2025-10-28T10:30:00.000Z"},
      "artifacts": [{
        "artifactId": "artifact-uuid",
        "name": "Weather Report",
        "parts": [{"text": "Today will be sunny with a high of 75°F"}]
      }],
      "unknownFutureField": {"ignored": true}
    }
  }|}

let test_send_message_response_task () =
  match decode Codec.send_message_response spec_task with
  | Ok (Send_message_response.Task t) ->
      Alcotest.(check string) "id" "task-uuid" t.id;
      Alcotest.(check (option string)) "context" (Some "context-uuid") t.context_id;
      Alcotest.(check bool) "completed" true (t.status.state = Task_state.Completed);
      Alcotest.(check bool) "timestamp" true (Option.is_some t.status.timestamp);
      Alcotest.(check string) "artifact text" "Today will be sunny with a high of 75°F"
        (Artifact.text (List.hd t.artifacts))
  | Ok (Message _) -> Alcotest.fail "expected a task"
  | Error e -> Alcotest.fail e

let test_send_message_response_message () =
  match
    decode Codec.send_message_response
      {|{"message":{"messageId":"r1","contextId":"c","role":"ROLE_AGENT","parts":[{"text":"hi there"}]}}|}
  with
  | Ok (Send_message_response.Message m) ->
      Alcotest.(check string) "text" "hi there" (Message.text m);
      Alcotest.(check bool) "role" true (m.role = Role.Agent)
  | Ok (Task _) -> Alcotest.fail "expected a message"
  | Error e -> Alcotest.fail e

let test_response_oneof_violations () =
  decode Codec.send_message_response {|{}|} |> expect_error ~contains:"none of task/message";
  decode Codec.send_message_response {|{"task":{"id":"t","status":{"state":"TASK_STATE_WORKING"}},"message":{"role":"ROLE_AGENT","parts":[]}}|}
  |> expect_error ~contains:"multiple payloads";
  decode Codec.send_message_response {|[1,2]|} |> expect_error ~contains:"expected object"

let test_task_state_enum () =
  List.iter
    (fun st ->
      let j = Codec.task_state_to_json st in
      match Codec.task_state j with
      | Ok st' -> Alcotest.(check bool) (Task_state.to_string st) true (st = st')
      | Error _ -> Alcotest.fail "enum roundtrip")
    Task_state.all;
  Alcotest.(check bool) "numeric" true (Codec.task_state (`Int 6) = Ok Task_state.Input_required);
  decode Codec.task {|{"id":"t","status":{"state":"completed"}}|}
  |> expect_error ~contains:"$.status.state: unknown TaskState";
  decode Codec.task {|{"id":"t","status":{"state":"working"}}|} |> expect_error ~contains:"unknown TaskState"

let test_task_state_predicates () =
  let open Task_state in
  List.iter
    (fun (st, terminal, interrupted) ->
      Alcotest.(check bool) (to_string st ^ " terminal") terminal (is_terminal st);
      Alcotest.(check bool) (to_string st ^ " interrupted") interrupted (is_interrupted st))
    [ (Submitted, false, false); (Working, false, false); (Completed, true, false);
      (Failed, true, false); (Canceled, true, false); (Rejected, true, false);
      (Input_required, false, true); (Auth_required, false, true); (Unspecified, false, false) ]

let test_part_errors () =
  decode Codec.part {|{"mediaType":"text/plain"}|} |> expect_error ~contains:"none of text/raw/url/data";
  decode Codec.part {|{"text":"a","url":"b"}|} |> expect_error ~contains:"multiple content";
  decode Codec.part {|{"raw":"***"}|} |> expect_error ~contains:"base64";
  decode Codec.part {|{"text":5}|} |> expect_error ~contains:"$.text: expected string";
  Alcotest.(check bool) "data null" true
    (match decode Codec.part {|{"data":null}|} with Ok { content = Data `Null; _ } -> true | _ -> false);
  Alcotest.(check bool) "urlsafe" true
    (match decode Codec.part {|{"raw":"AAH_"}|} with Ok { content = Raw "\000\001\xff"; _ } -> true | _ -> false)

let test_malformed_inputs () =
  decode Codec.task "{not json" |> expect_error ~contains:"invalid JSON";
  decode Codec.task {|{"status":{"state":"TASK_STATE_WORKING"}}|} |> expect_error ~contains:"$.id: missing";
  decode Codec.task {|{"id":"","status":{"state":"TASK_STATE_WORKING"}}|} |> expect_error ~contains:"$.id: must not be empty";
  decode Codec.task {|{"id":"t"}|} |> expect_error ~contains:"$.status: missing";
  decode Codec.task {|{"id":"t","status":{"state":"TASK_STATE_WORKING"},"history":[{"parts":"x"}]}|}
  |> expect_error ~contains:"$.history[0].parts: expected array";
  decode Codec.task {|{"id":"t","status":{"state":"TASK_STATE_WORKING","timestamp":"yesterday"}}|}
  |> expect_error ~contains:"invalid timestamp"

let test_stream_response_kinds () =
  let kind s =
    match decode Codec.stream_response s with
    | Ok (Stream_response.Task _) -> "task"
    | Ok (Message _) -> "message"
    | Ok (Status_update _) -> "status"
    | Ok (Artifact_update _) -> "artifact"
    | Error e -> "error: " ^ e
  in
  Alcotest.(check string) "task" "task" (kind {|{"task":{"id":"t","status":{"state":"TASK_STATE_WORKING"}}}|});
  Alcotest.(check string) "message" "message" (kind {|{"message":{"messageId":"m","role":"ROLE_AGENT","parts":[{"text":"x"}]}}|});
  Alcotest.(check string) "status" "status"
    (kind {|{"statusUpdate":{"taskId":"t","contextId":"c","status":{"state":"TASK_STATE_COMPLETED"}}}|});
  Alcotest.(check string) "artifact" "artifact"
    (kind {|{"artifactUpdate":{"taskId":"t","contextId":"c","artifact":{"artifactId":"a","parts":[{"text":"x"}]},"append":true,"lastChunk":false}}|});
  Alcotest.(check bool) "legacy kind rejected" true
    (String.starts_with ~prefix:"error"
       (kind {|{"kind":"status-update","taskId":"t","status":{"state":"completed"}}|}))

let spec_card =
  {|{
  "name": "GeoSpatial Route Planner Agent",
  "description": "Provides advanced route planning.",
  "supportedInterfaces": [
    {"url": "https://georoute-agent.example.com/a2a/v1", "protocolBinding": "JSONRPC", "protocolVersion": "1.0"},
    {"url": "https://georoute-agent.example.com/a2a/grpc", "protocolBinding": "GRPC", "protocolVersion": "1.0"},
    {"url": "https://georoute-agent.example.com/a2a/json", "protocolBinding": "HTTP+JSON", "protocolVersion": "1.0"}
  ],
  "provider": {"organization": "Example Geo Services Inc.", "url": "https://www.examplegeoservices.com"},
  "iconUrl": "https://georoute-agent.example.com/icon.png",
  "version": "1.2.0",
  "documentationUrl": "https://docs.examplegeoservices.com/georoute-agent/api",
  "capabilities": {"streaming": true, "pushNotifications": true, "extendedAgentCard": true},
  "securitySchemes": {
    "google": {"openIdConnectSecurityScheme": {"openIdConnectUrl": "https://accounts.google.com/.well-known/openid-configuration"}},
    "bearer": {"httpAuthSecurityScheme": {"scheme": "Bearer", "bearerFormat": "JWT"}},
    "oauth": {"oauth2SecurityScheme": {"flows": {"clientCredentials": {"tokenUrl": "https://auth.example.com/token", "scopes": {"read": "Read access"}}}}}
  },
  "securityRequirements": [{"schemes": {"google": {"list": ["openid", "profile"]}}}],
  "defaultInputModes": ["application/json", "text/plain"],
  "defaultOutputModes": ["application/json", "image/png"],
  "skills": [{
    "id": "route-optimizer-traffic", "name": "Traffic-Aware Route Optimizer",
    "description": "Calculates the optimal driving route.",
    "tags": ["maps", "routing"], "examples": ["Plan a route"],
    "inputModes": ["application/json", "text/plain"], "outputModes": ["application/json"]
  }],
  "signatures": [{"protected": "eyJhbGciOiJFUzI1NiJ9", "signature": "QFdk"}]
}|}

let test_agent_card () =
  match decode Codec.agent_card spec_card with
  | Error e -> Alcotest.fail e
  | Ok card ->
      Alcotest.(check string) "name" "GeoSpatial Route Planner Agent" card.name;
      Alcotest.(check int) "interfaces" 3 (List.length card.supported_interfaces);
      Alcotest.(check bool) "streaming" true (Agent_card.supports_streaming card);
      Alcotest.(check int) "skills" 1 (List.length card.skills);
      Alcotest.(check (list string)) "tags" [ "maps"; "routing" ] (List.hd card.skills).tags;
      Alcotest.(check int) "schemes" 3 (List.length card.security_schemes);
      (match List.assoc "bearer" card.security_schemes with
       | Security_scheme.Http_auth { scheme; bearer_format; _ } ->
           Alcotest.(check string) "scheme" "Bearer" scheme;
           Alcotest.(check (option string)) "fmt" (Some "JWT") bearer_format
       | _ -> Alcotest.fail "bearer scheme");
      (match List.assoc "oauth" card.security_schemes with
       | Security_scheme.Oauth2 { flows = Some (Oauth_flow.Client_credentials { token_url; scopes; _ }); _ } ->
           Alcotest.(check string) "token url" "https://auth.example.com/token" (Uri.to_string token_url);
           Alcotest.(check (list (pair string string))) "scopes" [ ("read", "Read access") ] scopes
       | _ -> Alcotest.fail "oauth scheme");
      Alcotest.(check (list (list (pair string (list string))))) "requirements"
        [ [ ("google", [ "openid"; "profile" ]) ] ] card.security_requirements;
      (match select_interface card with
       | Ok i -> Alcotest.(check string) "jsonrpc url" "https://georoute-agent.example.com/a2a/v1" (Uri.to_string i.url)
       | Error e -> Alcotest.fail (Error.to_string e))

let test_select_interface () =
  let card ifaces =
    match decode Codec.agent_card (Printf.sprintf {|{"name":"a","supportedInterfaces":%s}|} ifaces) with
    | Ok c -> c
    | Error e -> Alcotest.fail e
  in
  (match
     select_interface
       (card
          {|[{"url":"http://old","protocolBinding":"JSONRPC","protocolVersion":"0.3"},
             {"url":"http://grpc","protocolBinding":"GRPC","protocolVersion":"1.0"},
             {"url":"http://new","protocolBinding":"JSONRPC","protocolVersion":"1.0","tenant":"t1"},
             {"url":"http://later","protocolBinding":"JSONRPC","protocolVersion":"1.1"}]|})
   with
  | Ok i ->
      Alcotest.(check string) "url" "http://new" (Uri.to_string i.url);
      Alcotest.(check (option string)) "tenant" (Some "t1") i.tenant
  | Error e -> Alcotest.fail (Error.to_string e));
  let v03_only = card {|[{"url":"http://grpc","protocolBinding":"GRPC","protocolVersion":"1.0"},
                         {"url":"http://old","protocolBinding":"JSONRPC","protocolVersion":"0.3.0"}]|} in
  (match select_interface v03_only with
   | Ok i -> Alcotest.(check string) "0.3 fallback" "http://old" (Uri.to_string i.url)
   | Error e -> Alcotest.fail (Error.to_string e));
  (match select_interface ~protocol_version:V1_0 v03_only with
   | Error (Error.No_compatible_interface msg) ->
       Alcotest.(check bool) "pinned 1.0" true (contains ~sub:"protocol 1.0.x;" msg)
   | _ -> Alcotest.fail "expected No_compatible_interface");
  match
    select_interface
      (card {|[{"url":"http://older","protocolBinding":"JSONRPC","protocolVersion":"0.2.5"},
               {"url":"http://none","protocolBinding":"JSONRPC"}]|})
  with
  | Error (Error.No_compatible_interface msg) ->
      Alcotest.(check bool) "lists offers" true (contains ~sub:"JSONRPC 0.2.5" msg)
  | _ -> Alcotest.fail "expected No_compatible_interface"

(* Absence is decoded into the type once, never left as [""] for later
   checks. *)
let test_absent_values () =
  let get = function Ok v -> v | Error e -> Alcotest.fail e in
  let ev =
    get (decode Codec.stream_response
           {|{"statusUpdate":{"taskId":"t","contextId":"","status":{"state":"TASK_STATE_WORKING",
              "message":{"role":"ROLE_AGENT","parts":[{"text":"x"}]}}}}|})
  in
  (match ev with
   | Status_update { context_id = None; status = { message = Some { message_id = None; _ }; _ }; _ } -> ()
   | _ -> Alcotest.fail "empty contextId and absent messageId should be None");
  let r = get (decode Codec.list_tasks_response {|{"tasks":[],"nextPageToken":""}|}) in
  Alcotest.(check (option string)) "last page" None r.next_page_token;
  expect_error ~contains:"taskId"
    (decode Codec.task_push_notification_config {|{"url":"https://hook.test"}|});
  expect_error ~contains:"url"
    (decode Codec.task_push_notification_config {|{"taskId":"t","url":""}|});
  let card = get (decode Codec.agent_card {|{"name":"a","supportedInterfaces":[
      {"url":"http://h","protocolBinding":"GRPC","protocolVersion":"2.0"}]}|}) in
  (match card.supported_interfaces with
   | [ { protocol_binding = Unknown "GRPC"; protocol_version = Unknown "2.0"; _ } ] -> ()
   | _ -> Alcotest.fail "unknown binding and version are kept as text");
  Alcotest.(check bool) "absent capability is false" false card.capabilities.streaming

let test_protocol () =
  Alcotest.(check bool) "0.3 over REST is not a protocol" true
    (Protocol.make V0_3 Http_json = None);
  Alcotest.(check bool) "1.0 over REST" true (Protocol.make V1_0 Http_json = Some (V1_0 Http_json));
  Alcotest.check_raises "Poll.make" (Invalid_argument "Poll.make: need interval > 0 and backoff >= 1")
    (fun () -> ignore (Poll.make ~interval:0. ()))

let tests =
  [ ("message roundtrip", `Quick, test_message_roundtrip);
    ("absent values", `Quick, test_absent_values);
    ("protocol", `Quick, test_protocol);
    ("message wire format", `Quick, test_message_wire_format);
    ("request omits defaults", `Quick, test_request_omits_defaults);
    ("SendMessageResponse task (spec 6.1)", `Quick, test_send_message_response_task);
    ("SendMessageResponse message", `Quick, test_send_message_response_message);
    ("oneof violations", `Quick, test_response_oneof_violations);
    ("TaskState enum", `Quick, test_task_state_enum);
    ("TaskState predicates", `Quick, test_task_state_predicates);
    ("Part errors", `Quick, test_part_errors);
    ("malformed inputs", `Quick, test_malformed_inputs);
    ("StreamResponse kinds", `Quick, test_stream_response_kinds);
    ("Agent Card (spec 8.5)", `Quick, test_agent_card);
    ("interface selection", `Quick, test_select_interface) ]
