open Types
open Codec_base
module D = Json_decode

let ( let* ) = Result.bind

type 'a decoder = 'a D.t

let kind k = ("kind", `String k)

let kind_of what ~infer kvs =
  let* k = D.field_opt "kind" D.string kvs in
  match k with
  | Some k -> Ok k
  | None -> (
      match List.find_opt (fun (_, fields) -> List.for_all (fun f -> D.lookup f kvs <> None) fields) infer with
      | Some (k, _) -> Ok k
      | None -> D.fail (Printf.sprintf "%s has no \"kind\"" what))

let unknown_kind what k = D.fail (Printf.sprintf "unknown %s kind %S" what k) |> D.in_path "kind"

let role_to_string : Role.t -> string option = function
  | User -> Some "user"
  | Agent -> Some "agent"
  | Unspecified -> None

let role =
  enum "Role"
    (function "user" -> Some Role.User | "agent" -> Some Role.Agent | _ -> None)
    (fun _ -> None)

let task_state_to_string : Task_state.t -> string = function
  | Unspecified -> "unknown"
  | Submitted -> "submitted"
  | Working -> "working"
  | Completed -> "completed"
  | Failed -> "failed"
  | Canceled -> "canceled"
  | Input_required -> "input-required"
  | Rejected -> "rejected"
  | Auth_required -> "auth-required"

let task_state =
  enum "TaskState"
    (fun s -> List.find_opt (fun st -> task_state_to_string st = s) Task_state.all)
    (fun _ -> None)

let timestamp : Ptime.t option decoder = function
  | `String s -> (
      match timestamp (`String s) with
      | Ok t -> Ok (Some t)
      | Error _ -> Ok (Result.to_option (timestamp (`String (s ^ "Z")))))
  | j -> D.expected "timestamp string" j

let data_part_compat = "data_part_compat"

let part_to_json (p : Part.t) : json =
  let file payload =
    `Assoc (payload :: (str "name" p.filename @ str "mimeType" p.media_type))
  in
  let fields, metadata =
    match p.content with
    | Text s -> ([ kind "text"; ("text", `String s) ], p.metadata)
    | Raw b -> ([ kind "file"; ("file", file ("bytes", `String (Base64.encode_string b))) ], p.metadata)
    | Url u -> ([ kind "file"; ("file", file ("uri", uri_json u)) ], p.metadata)
    | Data (`Assoc _ as v) -> ([ kind "data"; ("data", v) ], p.metadata)
    | Data v ->
        let m = Option.value p.metadata ~default:[] in
        ( [ kind "data"; ("data", `Assoc [ ("value", v) ]) ],
          Some (List.remove_assoc data_part_compat m @ [ (data_part_compat, `Bool true) ]) )
  in
  `Assoc (fields @ meta "metadata" metadata)

let file_content kvs =
  let* filename = D.string_opt_field "name" kvs in
  let* media_type = D.string_opt_field "mimeType" kvs in
  let* content =
    match (D.lookup "bytes" kvs, D.lookup "uri" kvs) with
    | Some _, Some _ -> D.fail "file has both \"bytes\" and \"uri\""
    | Some _, None ->
        let* s = D.field "bytes" D.string kvs in
        base64_decode s |> D.in_path "bytes" |> Result.map (fun b -> Part.Raw b)
    | None, Some _ -> D.field "uri" D.uri kvs |> Result.map (fun u -> Part.Url u)
    | None, None -> D.fail "file has neither \"bytes\" nor \"uri\""
  in
  Ok (content, filename, media_type)

let part : Part.t decoder =
  D.obj @@ fun kvs ->
  let* metadata = meta_field "metadata" kvs in
  let* k = kind_of "Part" ~infer:[ ("text", [ "text" ]); ("file", [ "file" ]); ("data", [ "data" ]) ] kvs in
  match k with
  | "text" ->
      let* s = D.field "text" D.string kvs in
      Ok (Part.make ?metadata (Text s))
  | "file" ->
      let* content, filename, media_type = D.field "file" (D.obj file_content) kvs in
      Ok (Part.make ?metadata ?filename ?media_type content)
  | "data" -> (
      let* data = D.field "data" D.json kvs in
      let compat = Option.bind metadata (List.assoc_opt data_part_compat) = Some (`Bool true) in
      match data with
      | `Assoc [ ("value", v) ] when compat ->
          let metadata =
            match List.remove_assoc data_part_compat (Option.get metadata) with
            | [] -> None
            | m -> Some m
          in
          Ok (Part.make ?metadata (Data v))
      | v -> Ok (Part.make ?metadata (Data v)))
  | other -> unknown_kind "Part" other

let task_state_to_json s = `String (task_state_to_string s)

include Objects (struct
  let tag k = [ kind k ]
  let part_to_json = part_to_json
  let part = part
  let role_field r = opt "role" (fun r -> `String r) (role_to_string r)
  let role = role
  let task_state_to_json = task_state_to_json
  let task_state = task_state
  let timestamp = timestamp

  let status_update_fields (e : Task_status_update_event.t) =
    [ ("final", `Bool (Task_state.is_terminal e.status.state)) ]
end)

let stream_response : Stream_response.t decoder =
  D.obj @@ fun kvs ->
  let* k =
    kind_of "result"
      ~infer:
        [ ("message", [ "messageId"; "parts" ]); ("artifact-update", [ "taskId"; "artifact" ]);
          ("status-update", [ "taskId"; "status" ]); ("task", [ "id"; "status" ]) ]
      kvs
  in
  let j = `Assoc kvs in
  match k with
  | "task" -> Result.map (fun t -> Stream_response.Task t) (task j)
  | "message" -> Result.map (fun m -> Stream_response.Message m) (message j)
  | "status-update" -> Result.map (fun e -> Stream_response.Status_update e) (status_update j)
  | "artifact-update" -> Result.map (fun e -> Stream_response.Artifact_update e) (artifact_update j)
  | other -> unknown_kind "result" other

let stream_response_to_json : Stream_response.t -> json = function
  | Task t -> task_to_json t
  | Message m -> message_to_json m
  | Status_update e -> status_update_to_json e
  | Artifact_update e -> artifact_update_to_json e

let send_message_response : Send_message_response.t decoder =
 fun j ->
  let* r = stream_response j in
  match r with
  | Task t -> Ok (Send_message_response.Task t)
  | Message m -> Ok (Send_message_response.Message m)
  | Status_update _ | Artifact_update _ -> D.fail "expected a Task or a Message"

let send_message_response_to_json : Send_message_response.t -> json = function
  | Task t -> task_to_json t
  | Message m -> message_to_json m

let push_notification_config_to_json (c : Push_notification_config.t) : json =
  let auth (a : Authentication_info.t) =
    `Assoc ([ ("schemes", `List [ `String a.scheme ]) ] @ str "credentials" a.credentials)
  in
  `Assoc
    (str "id" c.id @ [ ("url", uri_json c.url) ] @ str "token" c.token
    @ opt "authentication" auth c.authentication)

let task_push_notification_config_to_json (c : Task_push_notification_config.t) : json =
  `Assoc
    [ ("taskId", `String c.task_id);
      ("pushNotificationConfig", push_notification_config_to_json c.config) ]

let task_push_notification_config : Task_push_notification_config.t decoder =
  let auth =
    D.obj @@ fun kvs ->
    let* schemes = D.list_field "schemes" D.string kvs in
    let* credentials = D.string_opt_field "credentials" kvs in
    Ok { Authentication_info.scheme = String.concat "," schemes; credentials }
  in
  D.obj @@ fun kvs ->
  let* task_id = non_empty "taskId" D.string kvs in
  let* config =
    D.field "pushNotificationConfig"
      (D.obj @@ fun kvs ->
       let* id = D.string_opt_field "id" kvs in
       let* url = D.uri_field "url" kvs in
       let* token = D.string_opt_field "token" kvs in
       let* authentication = D.field_opt "authentication" auth kvs in
       Ok { Push_notification_config.id; url; token; authentication })
      kvs
  in
  Ok { Task_push_notification_config.tenant = None; task_id; config }

let list_task_push_notification_configs_response :
    List_task_push_notification_configs_response.t decoder =
 fun j ->
  let* configs = D.list task_push_notification_config j in
  Ok { List_task_push_notification_configs_response.configs; next_page_token = None }

let send_message_configuration_to_json (c : Send_message_configuration.t) : json =
  `Assoc
    (str_list "acceptedOutputModes" c.accepted_output_modes
    @ opt "pushNotificationConfig" push_notification_config_to_json c.push_notification_config
    @ int "historyLength" c.history_length
    @ [ ("blocking", `Bool (not c.return_immediately)) ])

let send_message_request_to_json (r : Send_message_request.t) : json =
  `Assoc
    ([ ("message", message_to_json r.message) ]
    @ opt "configuration" send_message_configuration_to_json r.configuration
    @ meta "metadata" r.metadata)

let get_task_request_to_json (r : Get_task_request.t) : json =
  `Assoc ([ ("id", `String r.id) ] @ int "historyLength" r.history_length)

let cancel_task_request_to_json (r : Cancel_task_request.t) : json =
  `Assoc ([ ("id", `String r.id) ] @ meta "metadata" r.metadata)

let subscribe_to_task_request_to_json (r : Subscribe_to_task_request.t) : json =
  `Assoc [ ("id", `String r.id) ]

let task_push_notification_config_request_to_json
    (r : Task_push_notification_config_request.t) : json =
  `Assoc [ ("id", `String r.task_id); ("pushNotificationConfigId", `String r.id) ]

let list_task_push_notification_configs_request_to_json
    (r : List_task_push_notification_configs_request.t) : json =
  `Assoc [ ("id", `String r.task_id) ]
