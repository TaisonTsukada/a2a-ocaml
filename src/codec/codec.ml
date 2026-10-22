open Types
open Codec_base
module D = Json_decode

let ( let* ) = Result.bind

type 'a decoder = 'a D.t

let role_to_json r = `String (Role.to_string r)
let role = enum "Role" Role.of_string Role.of_int
let task_state_to_json s = `String (Task_state.to_string s)
let task_state = enum "TaskState" Task_state.of_string Task_state.of_int

let part_to_json (p : Part.t) : json =
  let content =
    match p.content with
    | Text s -> ("text", `String s)
    | Raw b -> ("raw", `String (Base64.encode_string b))
    | Url u -> ("url", uri_json u)
    | Data v -> ("data", v)
  in
  `Assoc
    ((content :: meta "metadata" p.metadata)
    @ str "filename" p.filename @ str "mediaType" p.media_type)

let part : Part.t decoder =
  D.obj @@ fun kvs ->
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
    | [ "url" ] -> D.field "url" D.uri kvs |> Result.map (fun u -> Part.Url u)
    | [ "data" ] -> Ok (Part.Data (List.assoc "data" kvs))
    | [] -> D.fail "Part has none of text/raw/url/data"
    | names ->
        D.fail ("Part has multiple content fields: " ^ String.concat ", " names)
  in
  let* metadata = meta_field "metadata" kvs in
  let* filename = D.string_opt_field "filename" kvs in
  let* media_type = D.string_opt_field "mediaType" kvs in
  Ok { Part.content; metadata; filename; media_type }

include Objects (struct
  let tag _ = []
  let part_to_json = part_to_json
  let part = part
  let role_field r = [ ("role", role_to_json r) ]
  let role = role
  let task_state_to_json = task_state_to_json
  let task_state = task_state
  let timestamp j = Result.map Option.some (timestamp j)
  let status_update_fields _ = []
end)

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

let authentication_info_to_json (a : Authentication_info.t) : json =
  `Assoc ([ ("scheme", `String a.scheme) ] @ str "credentials" a.credentials)

let authentication_info : Authentication_info.t decoder =
  D.obj @@ fun kvs ->
  let* scheme = D.string_field_default "scheme" kvs in
  let* credentials = D.string_opt_field "credentials" kvs in
  Ok { Authentication_info.scheme; credentials }

(* 1.0 has one flat message for both: a config sent with a message has no
   [taskId]. *)
let push_notification_config_fields (c : Push_notification_config.t) =
  str "id" c.id
  @ [ ("url", uri_json c.url) ]
  @ str "token" c.token
  @ opt "authentication" authentication_info_to_json c.authentication

let push_notification_config_to_json c : json = `Assoc (push_notification_config_fields c)

let task_push_notification_config_to_json (c : Task_push_notification_config.t) : json =
  `Assoc
    (str "tenant" c.tenant @ [ ("taskId", `String c.task_id) ]
    @ push_notification_config_fields c.config)

let task_push_notification_config : Task_push_notification_config.t decoder =
  D.obj @@ fun kvs ->
  let* tenant = D.string_opt_field "tenant" kvs in
  let* id = D.string_opt_field "id" kvs in
  let* task_id = non_empty "taskId" D.string kvs in
  let* url = D.uri_field "url" kvs in
  let* token = D.string_opt_field "token" kvs in
  let* authentication = D.field_opt "authentication" authentication_info kvs in
  Ok
    { Task_push_notification_config.tenant; task_id;
      config = { Push_notification_config.id; url; token; authentication } }

let list_task_push_notification_configs_response :
    List_task_push_notification_configs_response.t decoder =
  D.obj @@ fun kvs ->
  let* configs = D.list_field "configs" task_push_notification_config kvs in
  let* next_page_token = D.string_opt_field "nextPageToken" kvs in
  Ok { List_task_push_notification_configs_response.configs; next_page_token }

let list_tasks_response : List_tasks_response.t decoder =
  D.obj @@ fun kvs ->
  let* tasks = D.list_field "tasks" task kvs in
  let* next_page_token = D.string_opt_field "nextPageToken" kvs in
  let* page_size = D.field_default "pageSize" D.int ~default:0 kvs in
  let* total_size = D.field_default "totalSize" D.int ~default:0 kvs in
  Ok { List_tasks_response.tasks; next_page_token; page_size; total_size }

let send_message_configuration_to_json (c : Send_message_configuration.t) : json =
  `Assoc
    (str_list "acceptedOutputModes" c.accepted_output_modes
    @ opt "taskPushNotificationConfig" push_notification_config_to_json
        c.push_notification_config
    @ int "historyLength" c.history_length
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
    @ int "historyLength" r.history_length)

let cancel_task_request_to_json (r : Cancel_task_request.t) : json =
  `Assoc (str "tenant" r.tenant @ [ ("id", `String r.id) ] @ meta "metadata" r.metadata)

let subscribe_to_task_request_to_json (r : Subscribe_to_task_request.t) : json =
  `Assoc (str "tenant" r.tenant @ [ ("id", `String r.id) ])


let list_tasks_request_to_json (r : List_tasks_request.t) : json =
  `Assoc
    (str "tenant" r.tenant @ str "contextId" r.context_id
    @ opt "status" task_state_to_json r.status
    @ int "pageSize" r.page_size @ str "pageToken" r.page_token
    @ int "historyLength" r.history_length
    @ opt "statusTimestampAfter" timestamp_to_json r.status_timestamp_after
    @ opt "includeArtifacts" (fun b -> `Bool b) r.include_artifacts)

let task_push_notification_config_request_to_json
    (r : Task_push_notification_config_request.t) : json =
  `Assoc (str "tenant" r.tenant @ [ ("taskId", `String r.task_id); ("id", `String r.id) ])

let list_task_push_notification_configs_request_to_json
    (r : List_task_push_notification_configs_request.t) : json =
  `Assoc
    (str "tenant" r.tenant @ [ ("taskId", `String r.task_id) ]
    @ int "pageSize" r.page_size @ str "pageToken" r.page_token)

let get_extended_agent_card_request_to_json (r : Get_extended_agent_card_request.t) : json =
  `Assoc (str "tenant" r.tenant)

let known of_string s = match of_string s with Some v -> Known v | None -> Unknown s

let interface ~url ~binding ~version ~tenant =
  { Agent_interface.url; tenant; protocol_binding = known Protocol_binding.of_string binding;
    protocol_version = known Protocol_version.of_string version }

let agent_interface : Agent_interface.t decoder =
  D.obj @@ fun kvs ->
  let* url = D.uri_field "url" kvs in
  let* binding = D.field "protocolBinding" D.string kvs in
  let* tenant = D.string_opt_field "tenant" kvs in
  let* version = D.string_field_default "protocolVersion" kvs in
  Ok (interface ~url ~binding ~version ~tenant)

let agent_provider : Agent_provider.t decoder =
  D.obj @@ fun kvs ->
  let* url = D.uri_field_default "url" kvs in
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
  let* streaming = D.bool_field "streaming" kvs in
  let* push_notifications = D.bool_field "pushNotifications" kvs in
  let* extensions = D.list_field "extensions" agent_extension kvs in
  let* extended_agent_card = D.bool_field "extendedAgentCard" kvs in
  Ok { Agent_capabilities.streaming; push_notifications; extensions; extended_agent_card }

let security_requirement : Security_requirement.t decoder =
  D.obj @@ fun kvs ->
  let string_list = D.obj (fun kvs -> D.list_field "list" D.string kvs) in
  D.field_default "schemes" (D.string_map string_list) ~default:[] kvs

let scopes kvs = D.field_default "scopes" (D.string_map D.string) ~default:[] kvs

let authorization_code_flow =
  D.obj @@ fun kvs ->
  let* authorization_url = D.uri_field_default "authorizationUrl" kvs in
  let* token_url = D.uri_field_default "tokenUrl" kvs in
  let* refresh_url = D.uri_opt_field "refreshUrl" kvs in
  let* scopes = scopes kvs in
  let* pkce_required = D.bool_field "pkceRequired" kvs in
  Ok (Oauth_flow.Authorization_code
        { authorization_url; token_url; refresh_url; scopes; pkce_required })

let client_credentials_flow =
  D.obj @@ fun kvs ->
  let* token_url = D.uri_field_default "tokenUrl" kvs in
  let* refresh_url = D.uri_opt_field "refreshUrl" kvs in
  let* scopes = scopes kvs in
  Ok (Oauth_flow.Client_credentials { token_url; refresh_url; scopes })

let implicit_flow =
  D.obj @@ fun kvs ->
  let* authorization_url = D.uri_opt_field "authorizationUrl" kvs in
  let* refresh_url = D.uri_opt_field "refreshUrl" kvs in
  let* scopes = scopes kvs in
  Ok (Oauth_flow.Implicit { authorization_url; refresh_url; scopes })

let password_flow =
  D.obj @@ fun kvs ->
  let* token_url = D.uri_opt_field "tokenUrl" kvs in
  let* refresh_url = D.uri_opt_field "refreshUrl" kvs in
  let* scopes = scopes kvs in
  Ok (Oauth_flow.Password { token_url; refresh_url; scopes })

let device_code_flow =
  D.obj @@ fun kvs ->
  let* device_authorization_url = D.uri_field_default "deviceAuthorizationUrl" kvs in
  let* token_url = D.uri_field_default "tokenUrl" kvs in
  let* refresh_url = D.uri_opt_field "refreshUrl" kvs in
  let* scopes = scopes kvs in
  Ok (Oauth_flow.Device_code { device_authorization_url; token_url; refresh_url; scopes })

let oauth_flows =
  [ ("authorizationCode", authorization_code_flow);
    ("clientCredentials", client_credentials_flow); ("implicit", implicit_flow);
    ("password", password_flow); ("deviceCode", device_code_flow) ]

let oauth_flow : Oauth_flow.t decoder = oneof "OAuthFlows" oauth_flows

let legacy_oauth_flow : Oauth_flow.t decoder =
  D.obj @@ fun kvs ->
  match List.find_opt (fun (name, _) -> D.lookup name kvs <> None) oauth_flows with
  | Some (name, d) -> D.field name d kvs
  | None -> D.fail "OAuthFlows has no flow"

let security_scheme : Security_scheme.t decoder =
  let description kvs = D.string_opt_field "description" kvs in
  let api_key ~location_field =
    D.obj @@ fun kvs ->
    let* description = description kvs in
    let* location = D.string_field_default location_field kvs in
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
  let oauth2 ~flows =
    D.obj @@ fun kvs ->
    let* description = description kvs in
    let* flows = D.field_opt "flows" flows kvs in
    let* oauth2_metadata_url = D.uri_opt_field "oauth2MetadataUrl" kvs in
    Ok (Security_scheme.Oauth2 { description; flows; oauth2_metadata_url })
  in
  let oidc =
    D.obj @@ fun kvs ->
    let* description = description kvs in
    let* open_id_connect_url = D.uri_field_default "openIdConnectUrl" kvs in
    Ok (Security_scheme.Open_id_connect { description; open_id_connect_url })
  in
  let mtls =
    D.obj @@ fun kvs ->
    let* description = description kvs in
    Ok (Security_scheme.Mutual_tls { description })
  in
  let legacy kvs =
    let* typ = D.field "type" D.string kvs in
    let j = `Assoc kvs in
    match typ with
    | "apiKey" -> api_key ~location_field:"in" j
    | "http" -> http_auth j
    | "oauth2" -> oauth2 ~flows:legacy_oauth_flow j
    | "openIdConnect" -> oidc j
    | "mutualTLS" -> mtls j
    | other -> D.fail (Printf.sprintf "unknown security scheme type %S" other) |> D.in_path "type"
  in
  D.obj @@ fun kvs ->
  if D.lookup "type" kvs <> None then legacy kvs
  else
    oneof "SecurityScheme"
      [ ("apiKeySecurityScheme", api_key ~location_field:"location");
        ("httpAuthSecurityScheme", http_auth); ("oauth2SecurityScheme", oauth2 ~flows:oauth_flow);
        ("openIdConnectSecurityScheme", oidc); ("mtlsSecurityScheme", mtls) ]
      (`Assoc kvs)

let legacy_security_requirement : Security_requirement.t decoder =
  D.string_map (D.list D.string)

let security_requirements kvs =
  if D.lookup "securityRequirements" kvs <> None then
    D.list_field "securityRequirements" security_requirement kvs
  else D.list_field "security" legacy_security_requirement kvs

let agent_skill : Agent_skill.t decoder =
  D.obj @@ fun kvs ->
  let* id = D.string_field_default "id" kvs in
  let* name = D.string_field_default "name" kvs in
  let* description = D.string_field_default "description" kvs in
  let* tags = D.list_field "tags" D.string kvs in
  let* examples = D.list_field "examples" D.string kvs in
  let* input_modes = D.list_field "inputModes" D.string kvs in
  let* output_modes = D.list_field "outputModes" D.string kvs in
  let* security_requirements = security_requirements kvs in
  Ok
    { Agent_skill.id; name; description; tags; examples; input_modes;
      output_modes; security_requirements }

let agent_card_signature : Agent_card_signature.t decoder =
  D.obj @@ fun kvs ->
  let* protected = D.string_field_default "protected" kvs in
  let* signature = D.string_field_default "signature" kvs in
  let* header = meta_field "header" kvs in
  Ok { Agent_card_signature.protected; signature; header }

let legacy_interfaces kvs =
  let* url = D.string_opt_field "url" kvs in
  match url with
  | None -> Ok []
  | Some url ->
      let url = Uri.of_string url in
      let* binding = D.field_default "preferredTransport" D.string ~default:"JSONRPC" kvs in
      let* version = D.field_default "protocolVersion" D.string ~default:"0.3.0" kvs in
      let additional =
        D.obj @@ fun kvs ->
        let* url = D.uri_field "url" kvs in
        let* transport = D.field "transport" D.string kvs in
        Ok (url, transport)
      in
      let* more = D.list_field "additionalInterfaces" additional kvs in
      let iface (url, binding) = interface ~url ~binding ~version ~tenant:None in
      let more = List.filter (fun (u, b) -> not (Uri.equal u url && b = binding)) more in
      Ok (List.map iface ((url, binding) :: more))

let agent_card : Agent_card.t decoder =
  D.obj @@ fun kvs ->
  let* name = D.field "name" D.string kvs in
  let* description = D.string_field_default "description" kvs in
  let* supported_interfaces =
    if D.lookup "supportedInterfaces" kvs <> None then
      D.list_field "supportedInterfaces" agent_interface kvs
    else legacy_interfaces kvs
  in
  let* provider = D.field_opt "provider" agent_provider kvs in
  let* version = D.string_field_default "version" kvs in
  let* documentation_url = D.uri_opt_field "documentationUrl" kvs in
  let* capabilities =
    D.field_default "capabilities" agent_capabilities ~default:Agent_capabilities.empty kvs
  in
  let* legacy_extended = D.bool_field "supportsAuthenticatedExtendedCard" kvs in
  let capabilities =
    { capabilities with extended_agent_card = capabilities.extended_agent_card || legacy_extended }
  in
  let* security_schemes =
    D.field_default "securitySchemes" (D.string_map security_scheme) ~default:[] kvs
  in
  let* security_requirements = security_requirements kvs in
  let* default_input_modes = D.list_field "defaultInputModes" D.string kvs in
  let* default_output_modes = D.list_field "defaultOutputModes" D.string kvs in
  let* skills = D.list_field "skills" agent_skill kvs in
  let* signatures = D.list_field "signatures" agent_card_signature kvs in
  let* icon_url = D.uri_opt_field "iconUrl" kvs in
  Ok
    { Agent_card.name; description; supported_interfaces; provider; version;
      documentation_url; capabilities; security_schemes; security_requirements;
      default_input_modes; default_output_modes; skills; signatures; icon_url }

let decode_string d s = D.of_string d s
let decode_json d j = Result.map_error D.error_to_string (d j)
