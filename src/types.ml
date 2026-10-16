type json = Yojson.Safe.t

type metadata = (string * json) list

module Role = struct
  type t = Unspecified | User | Agent

  let to_string = function
    | Unspecified -> "ROLE_UNSPECIFIED"
    | User -> "ROLE_USER"
    | Agent -> "ROLE_AGENT"

  let of_string = function
    | "ROLE_UNSPECIFIED" -> Some Unspecified
    | "ROLE_USER" -> Some User
    | "ROLE_AGENT" -> Some Agent
    | _ -> None

  let of_int = function
    | 0 -> Some Unspecified
    | 1 -> Some User
    | 2 -> Some Agent
    | _ -> None
end

module Task_state = struct
  type t =
    | Unspecified
    | Submitted
    | Working
    | Completed
    | Failed
    | Canceled
    | Input_required
    | Rejected
    | Auth_required

  let to_string = function
    | Unspecified -> "TASK_STATE_UNSPECIFIED"
    | Submitted -> "TASK_STATE_SUBMITTED"
    | Working -> "TASK_STATE_WORKING"
    | Completed -> "TASK_STATE_COMPLETED"
    | Failed -> "TASK_STATE_FAILED"
    | Canceled -> "TASK_STATE_CANCELED"
    | Input_required -> "TASK_STATE_INPUT_REQUIRED"
    | Rejected -> "TASK_STATE_REJECTED"
    | Auth_required -> "TASK_STATE_AUTH_REQUIRED"

  let all =
    [ Unspecified; Submitted; Working; Completed; Failed; Canceled;
      Input_required; Rejected; Auth_required ]

  let of_string s = List.find_opt (fun st -> to_string st = s) all

  let of_int = function
    | 0 -> Some Unspecified
    | 1 -> Some Submitted
    | 2 -> Some Working
    | 3 -> Some Completed
    | 4 -> Some Failed
    | 5 -> Some Canceled
    | 6 -> Some Input_required
    | 7 -> Some Rejected
    | 8 -> Some Auth_required
    | _ -> None

  let pp ppf t = Format.pp_print_string ppf (to_string t)

  let is_terminal = function
    | Completed | Failed | Canceled | Rejected -> true
    | Unspecified | Submitted | Working | Input_required | Auth_required ->
        false

  let is_interrupted = function
    | Input_required | Auth_required -> true
    | _ -> false

  let is_active t = not (is_terminal t || is_interrupted t)
end

module Part = struct
  type content =
    | Text of string
    | Raw of string
    | Url of string
    | Data of json

  type t = {
    content : content;
    metadata : metadata option;
    filename : string option;
    media_type : string option;
  }

  let make ?metadata ?filename ?media_type content =
    { content; metadata; filename; media_type }

  let text ?metadata ?media_type s = make ?metadata ?media_type (Text s)

  let raw ?metadata ?filename ?media_type bytes =
    make ?metadata ?filename ?media_type (Raw bytes)

  let url ?metadata ?filename ?media_type u =
    make ?metadata ?filename ?media_type (Url u)

  let data ?metadata ?(media_type = "application/json") v =
    make ?metadata ~media_type (Data v)

  let as_text t = match t.content with Text s -> Some s | _ -> None
end

module Message = struct
  type t = {
    message_id : string;
    context_id : string option;
    task_id : string option;
    role : Role.t;
    parts : Part.t list;
    metadata : metadata option;
    extensions : string list;
    reference_task_ids : string list;
  }

  let make ?message_id ?context_id ?task_id ?metadata ?(extensions = [])
      ?(reference_task_ids = []) ~role parts =
    let message_id =
      match message_id with Some id -> id | None -> Id.uuid_v4 ()
    in
    { message_id; context_id; task_id; role; parts; metadata; extensions;
      reference_task_ids }

  let user ?message_id ?context_id ?task_id ?metadata ?extensions
      ?reference_task_ids parts =
    make ?message_id ?context_id ?task_id ?metadata ?extensions
      ?reference_task_ids ~role:Role.User parts

  let user_text ?message_id ?context_id ?task_id ?metadata text =
    user ?message_id ?context_id ?task_id ?metadata [ Part.text text ]

  let text t =
    List.filter_map Part.as_text t.parts |> String.concat "\n"
end

module Task_status = struct
  type t = {
    state : Task_state.t;
    message : Message.t option;
    timestamp : Ptime.t option;
  }

  let make ?message ?timestamp state = { state; message; timestamp }
end

module Artifact = struct
  type t = {
    artifact_id : string;
    name : string option;
    description : string option;
    parts : Part.t list;
    metadata : metadata option;
    extensions : string list;
  }

  let make ?name ?description ?metadata ?(extensions = []) ~artifact_id parts
      =
    { artifact_id; name; description; parts; metadata; extensions }

  let text t = List.filter_map Part.as_text t.parts |> String.concat ""
end

module Task = struct
  type t = {
    id : string;
    context_id : string option;
    status : Task_status.t;
    artifacts : Artifact.t list;
    history : Message.t list;
    metadata : metadata option;
  }

  let make ?context_id ?(artifacts = []) ?(history = []) ?metadata ~id status =
    { id; context_id; status; artifacts; history; metadata }

  let state t = t.status.state
  let is_terminal t = Task_state.is_terminal (state t)
  let is_interrupted t = Task_state.is_interrupted (state t)

  let follow_up ?message_id ?metadata t parts =
    Message.user ?message_id ?metadata ~task_id:t.id ?context_id:t.context_id
      parts

  let follow_up_text ?message_id ?metadata t text =
    follow_up ?message_id ?metadata t [ Part.text text ]
end

module Task_status_update_event = struct
  type t = {
    task_id : string;
    context_id : string;
    status : Task_status.t;
    metadata : metadata option;
  }
end

module Task_artifact_update_event = struct
  type t = {
    task_id : string;
    context_id : string;
    artifact : Artifact.t;
    append : bool;
    last_chunk : bool;
    metadata : metadata option;
  }
end

module Authentication_info = struct
  type t = { scheme : string; credentials : string option }

  let make ?credentials scheme = { scheme; credentials }
end

module Task_push_notification_config = struct
  type t = {
    tenant : string option;
    id : string option;
    task_id : string;
    url : string;
    token : string option;
    authentication : Authentication_info.t option;
  }

  let make ?tenant ?id ?(task_id = "") ?token ?authentication url =
    { tenant; id; task_id; url; token; authentication }
end

module Send_message_configuration = struct
  type t = {
    accepted_output_modes : string list;
    push_notification_config : Task_push_notification_config.t option;
    history_length : int option;
    return_immediately : bool;
  }

  let make ?(accepted_output_modes = []) ?push_notification_config
      ?history_length ?(return_immediately = false) () =
    { accepted_output_modes; push_notification_config; history_length;
      return_immediately }
end

module Send_message_request = struct
  type t = {
    tenant : string option;
    message : Message.t;
    configuration : Send_message_configuration.t option;
    metadata : metadata option;
  }
end

module Send_message_response = struct
  type t = Task of Task.t | Message of Message.t
end

module Stream_response = struct
  type t =
    | Task of Task.t
    | Message of Message.t
    | Status_update of Task_status_update_event.t
    | Artifact_update of Task_artifact_update_event.t
end

module Get_task_request = struct
  type t = { tenant : string option; id : string; history_length : int option }
end

module Cancel_task_request = struct
  type t = { tenant : string option; id : string; metadata : metadata option }
end

module Subscribe_to_task_request = struct
  type t = { tenant : string option; id : string }
end

module List_tasks_request = struct
  type t = {
    tenant : string option;
    context_id : string option;
    status : Task_state.t option;
    page_size : int option;
    page_token : string option;
    history_length : int option;
    status_timestamp_after : Ptime.t option;
    include_artifacts : bool option;
  }

  let make ?tenant ?context_id ?status ?page_size ?page_token ?history_length
      ?status_timestamp_after ?include_artifacts () =
    { tenant; context_id; status; page_size; page_token; history_length;
      status_timestamp_after; include_artifacts }
end

module List_tasks_response = struct
  type t = {
    tasks : Task.t list;
    next_page_token : string;
    page_size : int;
    total_size : int;
  }
end

module Task_push_notification_config_request = struct
  type t = { tenant : string option; task_id : string; id : string }
end

module List_task_push_notification_configs_request = struct
  type t = {
    tenant : string option;
    task_id : string;
    page_size : int option;
    page_token : string option;
  }
end

module List_task_push_notification_configs_response = struct
  type t = {
    configs : Task_push_notification_config.t list;
    next_page_token : string;
  }
end

module Get_extended_agent_card_request = struct
  type t = { tenant : string option }
end

module Agent_interface = struct
  type t = {
    url : string;
    protocol_binding : string;
    tenant : string option;
    protocol_version : string;
  }
end

module Agent_provider = struct
  type t = { url : string; organization : string }
end

module Agent_extension = struct
  type t = {
    uri : string;
    description : string option;
    required : bool;
    params : metadata option;
  }
end

module Agent_capabilities = struct
  type t = {
    streaming : bool option;
    push_notifications : bool option;
    extensions : Agent_extension.t list;
    extended_agent_card : bool option;
  }

  let empty =
    { streaming = None; push_notifications = None; extensions = [];
      extended_agent_card = None }
end

module Security_requirement = struct
  type t = (string * string list) list
end

module Agent_skill = struct
  type t = {
    id : string;
    name : string;
    description : string;
    tags : string list;
    examples : string list;
    input_modes : string list;
    output_modes : string list;
    security_requirements : Security_requirement.t list;
  }
end

module Agent_card_signature = struct
  type t = { protected : string; signature : string; header : metadata option }
end

module Oauth_flow = struct
  type scopes = (string * string) list

  type t =
    | Authorization_code of {
        authorization_url : string;
        token_url : string;
        refresh_url : string option;
        scopes : scopes;
        pkce_required : bool;
      }
    | Client_credentials of {
        token_url : string;
        refresh_url : string option;
        scopes : scopes;
      }
    | Implicit of {
        authorization_url : string option;
        refresh_url : string option;
        scopes : scopes;
      }
    | Password of {
        token_url : string option;
        refresh_url : string option;
        scopes : scopes;
      }
    | Device_code of {
        device_authorization_url : string;
        token_url : string;
        refresh_url : string option;
        scopes : scopes;
      }
end

module Security_scheme = struct
  type t =
    | Api_key of { description : string option; location : string; name : string }
    | Http_auth of {
        description : string option;
        scheme : string;
        bearer_format : string option;
      }
    | Oauth2 of {
        description : string option;
        flows : Oauth_flow.t option;
        oauth2_metadata_url : string option;
      }
    | Open_id_connect of {
        description : string option;
        open_id_connect_url : string;
      }
    | Mutual_tls of { description : string option }
end

module Agent_card = struct
  type t = {
    name : string;
    description : string;
    supported_interfaces : Agent_interface.t list;
    provider : Agent_provider.t option;
    version : string;
    documentation_url : string option;
    capabilities : Agent_capabilities.t;
    security_schemes : (string * Security_scheme.t) list;
    security_requirements : Security_requirement.t list;
    default_input_modes : string list;
    default_output_modes : string list;
    skills : Agent_skill.t list;
    signatures : Agent_card_signature.t list;
    icon_url : string option;
  }

  let supports_streaming t = t.capabilities.streaming = Some true
end
