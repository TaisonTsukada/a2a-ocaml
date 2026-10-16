open Types
module D = Json_decode

let ( let* ) = Result.bind

type 'a decoder = 'a D.t

let opt name f = function None -> [] | Some v -> [ (name, f v) ]
let str name = opt name (fun s -> `String s)
let str_list name = function [] -> [] | l -> [ (name, `List (List.map (fun s -> `String s) l)) ]
let lst name f = function [] -> [] | l -> [ (name, `List (List.map f l)) ]
let flag name b = if b then [ (name, `Bool true) ] else []
let metadata_json (m : metadata) : json = `Assoc m
let meta name = opt name metadata_json

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

let timestamp_to_json t = `String (Ptime.to_rfc3339 ~tz_offset_s:0 ~frac_s:3 t)

let timestamp : Ptime.t decoder = function
  | `String s -> (
      match Ptime.of_rfc3339 ~strict:false s with
      | Ok (t, _, _) -> Ok t
      | Error _ -> D.fail (Printf.sprintf "invalid timestamp %S" s))
  | j -> D.expected "RFC 3339 timestamp string" j

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

module type FORMAT = sig
  val tag : string -> (string * json) list

  val part_to_json : Part.t -> json
  val part : Part.t decoder
  val role_field : Role.t -> (string * json) list
  val role : Role.t decoder
  val task_state_to_json : Task_state.t -> json
  val task_state : Task_state.t decoder

  val timestamp : Ptime.t option decoder

  val status_update_fields : Task_status_update_event.t -> (string * json) list
end

let non_empty name d kvs =
  let* s = D.field name d kvs in
  if s = "" then Error { D.path = [ name ]; message = "must not be empty" } else Ok s

module Objects (F : FORMAT) = struct
  let message_to_json (m : Message.t) : json =
    `Assoc
      (F.tag "message"
      @ [ ("messageId", `String m.message_id) ]
      @ str "contextId" m.context_id @ str "taskId" m.task_id
      @ F.role_field m.role
      @ [ ("parts", `List (List.map F.part_to_json m.parts)) ]
      @ meta "metadata" m.metadata
      @ str_list "extensions" m.extensions
      @ str_list "referenceTaskIds" m.reference_task_ids)

  let message : Message.t decoder =
    D.obj @@ fun kvs ->
    let* message_id = D.string_field_default "messageId" kvs in
    let* context_id = D.string_opt_field "contextId" kvs in
    let* task_id = D.string_opt_field "taskId" kvs in
    let* role = D.field_default "role" F.role ~default:Role.Unspecified kvs in
    let* parts = D.list_field "parts" F.part kvs in
    let* metadata = meta_field "metadata" kvs in
    let* extensions = D.list_field "extensions" D.string kvs in
    let* reference_task_ids = D.list_field "referenceTaskIds" D.string kvs in
    Ok
      { Message.message_id; context_id; task_id; role; parts; metadata;
        extensions; reference_task_ids }

  let task_status_to_json (s : Task_status.t) : json =
    `Assoc
      ([ ("state", F.task_state_to_json s.state) ]
      @ opt "message" message_to_json s.message
      @ opt "timestamp" timestamp_to_json s.timestamp)

  let task_status : Task_status.t decoder =
    D.obj @@ fun kvs ->
    let* state = D.field "state" F.task_state kvs in
    let* message = D.field_opt "message" message kvs in
    let* timestamp = D.field_default "timestamp" F.timestamp ~default:None kvs in
    Ok { Task_status.state; message; timestamp }

  let artifact_to_json (a : Artifact.t) : json =
    `Assoc
      ([ ("artifactId", `String a.artifact_id) ]
      @ str "name" a.name @ str "description" a.description
      @ [ ("parts", `List (List.map F.part_to_json a.parts)) ]
      @ meta "metadata" a.metadata
      @ str_list "extensions" a.extensions)

  let artifact : Artifact.t decoder =
    D.obj @@ fun kvs ->
    let* artifact_id = D.string_field_default "artifactId" kvs in
    let* name = D.string_opt_field "name" kvs in
    let* description = D.string_opt_field "description" kvs in
    let* parts = D.list_field "parts" F.part kvs in
    let* metadata = meta_field "metadata" kvs in
    let* extensions = D.list_field "extensions" D.string kvs in
    Ok { Artifact.artifact_id; name; description; parts; metadata; extensions }

  let task_to_json (t : Task.t) : json =
    `Assoc
      (F.tag "task"
      @ [ ("id", `String t.id) ]
      @ str "contextId" t.context_id
      @ [ ("status", task_status_to_json t.status) ]
      @ lst "artifacts" artifact_to_json t.artifacts
      @ lst "history" message_to_json t.history
      @ meta "metadata" t.metadata)

  let task : Task.t decoder =
    D.obj @@ fun kvs ->
    let* id = non_empty "id" D.string kvs in
    let* context_id = D.string_opt_field "contextId" kvs in
    let* status = D.field "status" task_status kvs in
    let* artifacts = D.list_field "artifacts" artifact kvs in
    let* history = D.list_field "history" message kvs in
    let* metadata = meta_field "metadata" kvs in
    Ok { Task.id; context_id; status; artifacts; history; metadata }

  let status_update_to_json (e : Task_status_update_event.t) : json =
    `Assoc
      (F.tag "status-update"
      @ [ ("taskId", `String e.task_id); ("contextId", `String e.context_id);
          ("status", task_status_to_json e.status) ]
      @ F.status_update_fields e
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
      (F.tag "artifact-update"
      @ [ ("taskId", `String e.task_id); ("contextId", `String e.context_id);
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
end

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
