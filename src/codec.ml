(* ProtoJSON encoding / decoding of the A2A v1.0 data model.

   - Field names are lowerCamelCase (spec §5.5).
   - Enums are their proto names, e.g. "TASK_STATE_COMPLETED"; decoders
     also accept enum numbers as ProtoJSON parsers do.
   - oneofs use the member name as discriminator (no "kind" field, §A.2.1).
   - Default values (absent options, empty lists, false) are omitted when
     encoding.
   - Timestamps are RFC 3339 / ISO 8601 UTC strings (§5.6.1).
   - [bytes] are base64 (standard or URL-safe, padding optional). *)

open Types
module D = Json_decode

let ( let* ) = Result.bind

type 'a decoder = 'a D.t

(* ---------- encoding helpers ---------- *)

let opt name f = function None -> [] | Some v -> [ (name, f v) ]
let str name = opt name (fun s -> `String s)
let str_list name = function [] -> [] | l -> [ (name, `List (List.map (fun s -> `String s) l)) ]
let lst name f = function [] -> [] | l -> [ (name, `List (List.map f l)) ]
let flag name b = if b then [ (name, `Bool true) ] else []
let metadata_json (m : metadata) : json = `Assoc m
let meta name = opt name metadata_json

(* ---------- decoding helpers ---------- *)

let metadata : metadata decoder = D.assoc
let meta_field name kvs = D.field_opt name metadata kvs

let enum what of_string of_int : 'a decoder = function
  | `String s as j -> (
      match of_string s with
      | Some v -> Ok v
      | None -> D.fail (Printf.sprintf "unknown %s %s" what (Yojson.Safe.to_string j)))
  | `Int i -> (
      match of_int i with
      | Some v -> Ok v
      | None -> D.fail (Printf.sprintf "unknown %s %d" what i))
  | j -> D.expected (what ^ " enum") j

(* ---------- Timestamp ---------- *)

let timestamp_to_json t = `String (Ptime.to_rfc3339 ~tz_offset_s:0 ~frac_s:3 t)

let timestamp : Ptime.t decoder = function
  | `String s -> (
      match Ptime.of_rfc3339 ~strict:false s with
      | Ok (t, _, _) -> Ok t
      | Error _ -> D.fail (Printf.sprintf "invalid timestamp %S" s))
  | j -> D.expected "RFC 3339 timestamp string" j

(* ---------- bytes ---------- *)

let base64_decode s =
  let try_alpha alphabet =
    Base64.decode ~pad:false ~alphabet s |> Result.to_option
  in
  match try_alpha Base64.default_alphabet with
  | Some b -> Ok b
  | None -> (
      match try_alpha Base64.uri_safe_alphabet with
      | Some b -> Ok b
      | None -> D.fail "invalid base64 in bytes field")

(* ---------- Role / TaskState ---------- *)

let role_to_json r = `String (Role.to_string r)
let role = enum "Role" Role.of_string Role.of_int
let task_state_to_json s = `String (Task_state.to_string s)
let task_state = enum "TaskState" Task_state.of_string Task_state.of_int

(* ---------- Part ---------- *)

let part_to_json (p : Part.t) : json =
  let content =
    match p.content with
    | Text s -> ("text", `String s)
    | Raw b -> ("raw", `String (Base64.encode_string b))
    | Url u -> ("url", `String u)
    | Data v -> ("data", v)
  in
  `Assoc
    ((content :: meta "metadata" p.metadata)
    @ str "filename" p.filename @ str "mediaType" p.media_type)

let part : Part.t decoder =
  D.obj @@ fun kvs ->
  (* [data] may legitimately be JSON null, so look it up directly. *)
  let present name = List.mem_assoc name kvs in
  let candidates =
    List.filter present [ "text"; "raw"; "url"; "data" ]
    |> List.filter (fun n -> n = "data" || List.assoc n kvs <> `Null)
  in
  let* content =
    match candidates with
    | [ "text" ] -> D.field "text" D.string kvs |> Result.map (fun s -> Part.Text s)
    | [ "raw" ] ->
        let* s = D.field "raw" D.string kvs in
        base64_decode s |> D.in_path "raw" |> Result.map (fun b -> Part.Raw b)
    | [ "url" ] -> D.field "url" D.string kvs |> Result.map (fun s -> Part.Url s)
    | [ "data" ] -> Ok (Part.Data (List.assoc "data" kvs))
    | [] -> D.fail "Part has none of text/raw/url/data"
    | names ->
        D.fail ("Part has multiple content fields: " ^ String.concat ", " names)
  in
  let* metadata = meta_field "metadata" kvs in
  let* filename = D.string_opt_field "filename" kvs in
  let* media_type = D.string_opt_field "mediaType" kvs in
  Ok { Part.content; metadata; filename; media_type }

(* ---------- Message ---------- *)

let message_to_json (m : Message.t) : json =
  `Assoc
    ([ ("messageId", `String m.message_id) ]
    @ str "contextId" m.context_id @ str "taskId" m.task_id
    @ [ ("role", role_to_json m.role); ("parts", `List (List.map part_to_json m.parts)) ]
    @ meta "metadata" m.metadata
    @ str_list "extensions" m.extensions
    @ str_list "referenceTaskIds" m.reference_task_ids)

let message : Message.t decoder =
  D.obj @@ fun kvs ->
  let* message_id = D.string_field_default "messageId" kvs in
  let* context_id = D.string_opt_field "contextId" kvs in
  let* task_id = D.string_opt_field "taskId" kvs in
  let* role = D.field_default "role" role ~default:Role.Unspecified kvs in
  let* parts = D.list_field "parts" part kvs in
  let* metadata = meta_field "metadata" kvs in
  let* extensions = D.list_field "extensions" D.string kvs in
  let* reference_task_ids = D.list_field "referenceTaskIds" D.string kvs in
  Ok
    { Message.message_id; context_id; task_id; role; parts; metadata;
      extensions; reference_task_ids }

(* ---------- TaskStatus / Artifact / Task ---------- *)

let task_status_to_json (s : Task_status.t) : json =
  `Assoc
    ([ ("state", task_state_to_json s.state) ]
    @ opt "message" message_to_json s.message
    @ opt "timestamp" timestamp_to_json s.timestamp)

let task_status : Task_status.t decoder =
  D.obj @@ fun kvs ->
  let* state = D.field "state" task_state kvs in
  let* message = D.field_opt "message" message kvs in
  let* timestamp = D.field_opt "timestamp" timestamp kvs in
  Ok { Task_status.state; message; timestamp }

let artifact_to_json (a : Artifact.t) : json =
  `Assoc
    ([ ("artifactId", `String a.artifact_id) ]
    @ str "name" a.name @ str "description" a.description
    @ [ ("parts", `List (List.map part_to_json a.parts)) ]
    @ meta "metadata" a.metadata
    @ str_list "extensions" a.extensions)

let artifact : Artifact.t decoder =
  D.obj @@ fun kvs ->
  let* artifact_id = D.string_field_default "artifactId" kvs in
  let* name = D.string_opt_field "name" kvs in
  let* description = D.string_opt_field "description" kvs in
  let* parts = D.list_field "parts" part kvs in
  let* metadata = meta_field "metadata" kvs in
  let* extensions = D.list_field "extensions" D.string kvs in
  Ok { Artifact.artifact_id; name; description; parts; metadata; extensions }

let task_to_json (t : Task.t) : json =
  `Assoc
    ([ ("id", `String t.id) ]
    @ str "contextId" t.context_id
    @ [ ("status", task_status_to_json t.status) ]
    @ lst "artifacts" artifact_to_json t.artifacts
    @ lst "history" message_to_json t.history
    @ meta "metadata" t.metadata)

let non_empty name d kvs =
  let* s = D.field name d kvs in
  if s = "" then Error { D.path = [ name ]; message = "must not be empty" } else Ok s

let task : Task.t decoder =
  D.obj @@ fun kvs ->
  let* id = non_empty "id" D.string kvs in
  let* context_id = D.string_opt_field "contextId" kvs in
  let* status = D.field "status" task_status kvs in
  let* artifacts = D.list_field "artifacts" artifact kvs in
  let* history = D.list_field "history" message kvs in
  let* metadata = meta_field "metadata" kvs in
  Ok { Task.id; context_id; status; artifacts; history; metadata }

(* ---------- streaming events ---------- *)

let status_update_to_json (e : Task_status_update_event.t) : json =
  `Assoc
    ([ ("taskId", `String e.task_id); ("contextId", `String e.context_id);
       ("status", task_status_to_json e.status) ]
    @ meta "metadata" e.metadata)

let status_update : Task_status_update_event.t decoder =
  D.obj @@ fun kvs ->
  let* task_id = non_empty "taskId" D.string kvs in
  let* context_id = D.string_field_default "contextId" kvs in
  let* status = D.field "status" task_status kvs in
  let* metadata = meta_field "metadata" kvs in
  Ok { Task_status_update_event.task_id; context_id; status; metadata }

let artifact_update_to_json (e : Task_artifact_update_event.t) : json =
  `Assoc
    ([ ("taskId", `String e.task_id); ("contextId", `String e.context_id);
       ("artifact", artifact_to_json e.artifact) ]
    @ flag "append" e.append @ flag "lastChunk" e.last_chunk
    @ meta "metadata" e.metadata)

let artifact_update : Task_artifact_update_event.t decoder =
  D.obj @@ fun kvs ->
  let* task_id = non_empty "taskId" D.string kvs in
  let* context_id = D.string_field_default "contextId" kvs in
  let* artifact = D.field "artifact" artifact kvs in
  let* append = D.bool_field "append" kvs in
  let* last_chunk = D.bool_field "lastChunk" kvs in
  let* metadata = meta_field "metadata" kvs in
  Ok
    { Task_artifact_update_event.task_id; context_id; artifact; append;
      last_chunk; metadata }

(* Decode a proto oneof: exactly one of [cases] must be present. *)
let oneof what cases : 'a decoder =
  D.obj @@ fun kvs ->
  match List.filter (fun (name, _) -> D.lookup name kvs <> None) cases with
  | [ (name, d) ] -> D.field name d kvs
  | [] ->
      D.fail
        (Printf.sprintf "%s has none of %s" what
           (String.concat "/" (List.map fst cases)))
  | many ->
      D.fail
        (Printf.sprintf "%s has multiple payloads: %s" what
           (String.concat ", " (List.map fst many)))

let send_message_response : Send_message_response.t decoder =
  oneof "SendMessageResponse"
    [ ("task", fun j -> Result.map (fun t -> Send_message_response.Task t) (task j));
      ("message", fun j -> Result.map (fun m -> Send_message_response.Message m) (message j)) ]

let send_message_response_to_json : Send_message_response.t -> json = function
  | Task t -> `Assoc [ ("task", task_to_json t) ]
  | Message m -> `Assoc [ ("message", message_to_json m) ]

let stream_response : Stream_response.t decoder =
  let map f d j = Result.map f (d j) in
  oneof "StreamResponse"
    [ ("task", map (fun t -> Stream_response.Task t) task);
      ("message", map (fun m -> Stream_response.Message m) message);
      ("statusUpdate", map (fun e -> Stream_response.Status_update e) status_update);
      ("artifactUpdate", map (fun e -> Stream_response.Artifact_update e) artifact_update) ]

let stream_response_to_json : Stream_response.t -> json = function
  | Task t -> `Assoc [ ("task", task_to_json t) ]
  | Message m -> `Assoc [ ("message", message_to_json m) ]
  | Status_update e -> `Assoc [ ("statusUpdate", status_update_to_json e) ]
  | Artifact_update e -> `Assoc [ ("artifactUpdate", artifact_update_to_json e) ]

(* ---------- requests ---------- *)

let send_message_configuration_to_json (c : Send_message_configuration.t) : json =
  `Assoc
    (str_list "acceptedOutputModes" c.accepted_output_modes
    @ opt "historyLength" (fun n -> `Int n) c.history_length
    @ flag "returnImmediately" c.return_immediately)

let send_message_request_to_json (r : Send_message_request.t) : json =
  `Assoc
    (str "tenant" r.tenant
    @ [ ("message", message_to_json r.message) ]
    @ opt "configuration" send_message_configuration_to_json r.configuration
    @ meta "metadata" r.metadata)

let get_task_request_to_json (r : Get_task_request.t) : json =
  `Assoc
    (str "tenant" r.tenant @ [ ("id", `String r.id) ]
    @ opt "historyLength" (fun n -> `Int n) r.history_length)

let cancel_task_request_to_json (r : Cancel_task_request.t) : json =
  `Assoc (str "tenant" r.tenant @ [ ("id", `String r.id) ] @ meta "metadata" r.metadata)

let subscribe_to_task_request_to_json (r : Subscribe_to_task_request.t) : json =
  `Assoc (str "tenant" r.tenant @ [ ("id", `String r.id) ])

(* ---------- Agent card ---------- *)

let agent_interface : Agent_interface.t decoder =
  D.obj @@ fun kvs ->
  let* url = D.field "url" D.string kvs in
  let* protocol_binding = D.field "protocolBinding" D.string kvs in
  let* tenant = D.string_opt_field "tenant" kvs in
  let* protocol_version = D.string_field_default "protocolVersion" kvs in
  Ok { Agent_interface.url; protocol_binding; tenant; protocol_version }

let agent_interface_to_json (i : Agent_interface.t) : json =
  `Assoc
    ([ ("url", `String i.url); ("protocolBinding", `String i.protocol_binding) ]
    @ str "tenant" i.tenant
    @ [ ("protocolVersion", `String i.protocol_version) ])

let agent_provider : Agent_provider.t decoder =
  D.obj @@ fun kvs ->
  let* url = D.string_field_default "url" kvs in
  let* organization = D.string_field_default "organization" kvs in
  Ok { Agent_provider.url; organization }

let agent_extension : Agent_extension.t decoder =
  D.obj @@ fun kvs ->
  let* uri = D.string_field_default "uri" kvs in
  let* description = D.string_opt_field "description" kvs in
  let* required = D.bool_field "required" kvs in
  let* params = meta_field "params" kvs in
  Ok { Agent_extension.uri; description; required; params }

let agent_capabilities : Agent_capabilities.t decoder =
  D.obj @@ fun kvs ->
  let* streaming = D.field_opt "streaming" D.bool kvs in
  let* push_notifications = D.field_opt "pushNotifications" D.bool kvs in
  let* extensions = D.list_field "extensions" agent_extension kvs in
  let* extended_agent_card = D.field_opt "extendedAgentCard" D.bool kvs in
  Ok { Agent_capabilities.streaming; push_notifications; extensions; extended_agent_card }

(* SecurityRequirement: {"schemes": {"name": {"list": ["scope"]}}} *)
let security_requirement : Security_requirement.t decoder =
  D.obj @@ fun kvs ->
  let string_list = D.obj (fun kvs -> D.list_field "list" D.string kvs) in
  D.field_default "schemes" (D.string_map string_list) ~default:[] kvs

let scopes kvs = D.field_default "scopes" (D.string_map D.string) ~default:[] kvs

let oauth_flow : Oauth_flow.t decoder =
  let authorization_code =
    D.obj @@ fun kvs ->
    let* authorization_url = D.string_field_default "authorizationUrl" kvs in
    let* token_url = D.string_field_default "tokenUrl" kvs in
    let* refresh_url = D.string_opt_field "refreshUrl" kvs in
    let* scopes = scopes kvs in
    let* pkce_required = D.bool_field "pkceRequired" kvs in
    Ok (Oauth_flow.Authorization_code
          { authorization_url; token_url; refresh_url; scopes; pkce_required })
  in
  let client_credentials =
    D.obj @@ fun kvs ->
    let* token_url = D.string_field_default "tokenUrl" kvs in
    let* refresh_url = D.string_opt_field "refreshUrl" kvs in
    let* scopes = scopes kvs in
    Ok (Oauth_flow.Client_credentials { token_url; refresh_url; scopes })
  in
  let implicit =
    D.obj @@ fun kvs ->
    let* authorization_url = D.string_opt_field "authorizationUrl" kvs in
    let* refresh_url = D.string_opt_field "refreshUrl" kvs in
    let* scopes = scopes kvs in
    Ok (Oauth_flow.Implicit { authorization_url; refresh_url; scopes })
  in
  let password =
    D.obj @@ fun kvs ->
    let* token_url = D.string_opt_field "tokenUrl" kvs in
    let* refresh_url = D.string_opt_field "refreshUrl" kvs in
    let* scopes = scopes kvs in
    Ok (Oauth_flow.Password { token_url; refresh_url; scopes })
  in
  let device_code =
    D.obj @@ fun kvs ->
    let* device_authorization_url = D.string_field_default "deviceAuthorizationUrl" kvs in
    let* token_url = D.string_field_default "tokenUrl" kvs in
    let* refresh_url = D.string_opt_field "refreshUrl" kvs in
    let* scopes = scopes kvs in
    Ok (Oauth_flow.Device_code { device_authorization_url; token_url; refresh_url; scopes })
  in
  oneof "OAuthFlows"
    [ ("authorizationCode", authorization_code);
      ("clientCredentials", client_credentials); ("implicit", implicit);
      ("password", password); ("deviceCode", device_code) ]

let security_scheme : Security_scheme.t decoder =
  let description kvs = D.string_opt_field "description" kvs in
  let api_key =
    D.obj @@ fun kvs ->
    let* description = description kvs in
    let* location = D.string_field_default "location" kvs in
    let* name = D.string_field_default "name" kvs in
    Ok (Security_scheme.Api_key { description; location; name })
  in
  let http_auth =
    D.obj @@ fun kvs ->
    let* description = description kvs in
    let* scheme = D.string_field_default "scheme" kvs in
    let* bearer_format = D.string_opt_field "bearerFormat" kvs in
    Ok (Security_scheme.Http_auth { description; scheme; bearer_format })
  in
  let oauth2 =
    D.obj @@ fun kvs ->
    let* description = description kvs in
    let* flows = D.field_opt "flows" oauth_flow kvs in
    let* oauth2_metadata_url = D.string_opt_field "oauth2MetadataUrl" kvs in
    Ok (Security_scheme.Oauth2 { description; flows; oauth2_metadata_url })
  in
  let oidc =
    D.obj @@ fun kvs ->
    let* description = description kvs in
    let* open_id_connect_url = D.string_field_default "openIdConnectUrl" kvs in
    Ok (Security_scheme.Open_id_connect { description; open_id_connect_url })
  in
  let mtls =
    D.obj @@ fun kvs ->
    let* description = description kvs in
    Ok (Security_scheme.Mutual_tls { description })
  in
  oneof "SecurityScheme"
    [ ("apiKeySecurityScheme", api_key); ("httpAuthSecurityScheme", http_auth);
      ("oauth2SecurityScheme", oauth2); ("openIdConnectSecurityScheme", oidc);
      ("mtlsSecurityScheme", mtls) ]

let agent_skill : Agent_skill.t decoder =
  D.obj @@ fun kvs ->
  let* id = D.string_field_default "id" kvs in
  let* name = D.string_field_default "name" kvs in
  let* description = D.string_field_default "description" kvs in
  let* tags = D.list_field "tags" D.string kvs in
  let* examples = D.list_field "examples" D.string kvs in
  let* input_modes = D.list_field "inputModes" D.string kvs in
  let* output_modes = D.list_field "outputModes" D.string kvs in
  let* security_requirements = D.list_field "securityRequirements" security_requirement kvs in
  Ok
    { Agent_skill.id; name; description; tags; examples; input_modes;
      output_modes; security_requirements }

let agent_card_signature : Agent_card_signature.t decoder =
  D.obj @@ fun kvs ->
  let* protected = D.string_field_default "protected" kvs in
  let* signature = D.string_field_default "signature" kvs in
  let* header = meta_field "header" kvs in
  Ok { Agent_card_signature.protected; signature; header }

let agent_card : Agent_card.t decoder =
  D.obj @@ fun kvs ->
  let* name = D.field "name" D.string kvs in
  let* description = D.string_field_default "description" kvs in
  let* supported_interfaces = D.list_field "supportedInterfaces" agent_interface kvs in
  let* provider = D.field_opt "provider" agent_provider kvs in
  let* version = D.string_field_default "version" kvs in
  let* documentation_url = D.string_opt_field "documentationUrl" kvs in
  let* capabilities =
    D.field_default "capabilities" agent_capabilities ~default:Agent_capabilities.empty kvs
  in
  let* security_schemes =
    D.field_default "securitySchemes" (D.string_map security_scheme) ~default:[] kvs
  in
  let* security_requirements = D.list_field "securityRequirements" security_requirement kvs in
  let* default_input_modes = D.list_field "defaultInputModes" D.string kvs in
  let* default_output_modes = D.list_field "defaultOutputModes" D.string kvs in
  let* skills = D.list_field "skills" agent_skill kvs in
  let* signatures = D.list_field "signatures" agent_card_signature kvs in
  let* icon_url = D.string_opt_field "iconUrl" kvs in
  Ok
    { Agent_card.name; description; supported_interfaces; provider; version;
      documentation_url; capabilities; security_schemes; security_requirements;
      default_input_modes; default_output_modes; skills; signatures; icon_url }

(* ---------- string-level entry points ---------- *)

let decode_string d s = D.of_string d s
let to_string json = Yojson.Safe.to_string json
