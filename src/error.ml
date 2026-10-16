module Code = struct
  type t =
    | Parse_error
    | Invalid_request
    | Method_not_found
    | Invalid_params
    | Internal_error
    | Task_not_found
    | Task_not_cancelable
    | Push_notification_not_supported
    | Unsupported_operation
    | Content_type_not_supported
    | Invalid_agent_response
    | Extended_agent_card_not_configured
    | Extension_support_required
    | Version_not_supported
    | Other of int

  let of_int = function
    | -32700 -> Parse_error
    | -32600 -> Invalid_request
    | -32601 -> Method_not_found
    | -32602 -> Invalid_params
    | -32603 -> Internal_error
    | -32001 -> Task_not_found
    | -32002 -> Task_not_cancelable
    | -32003 -> Push_notification_not_supported
    | -32004 -> Unsupported_operation
    | -32005 -> Content_type_not_supported
    | -32006 -> Invalid_agent_response
    | -32007 -> Extended_agent_card_not_configured
    | -32008 -> Extension_support_required
    | -32009 -> Version_not_supported
    | n -> Other n

  let to_int = function
    | Parse_error -> -32700
    | Invalid_request -> -32600
    | Method_not_found -> -32601
    | Invalid_params -> -32602
    | Internal_error -> -32603
    | Task_not_found -> -32001
    | Task_not_cancelable -> -32002
    | Push_notification_not_supported -> -32003
    | Unsupported_operation -> -32004
    | Content_type_not_supported -> -32005
    | Invalid_agent_response -> -32006
    | Extended_agent_card_not_configured -> -32007
    | Extension_support_required -> -32008
    | Version_not_supported -> -32009
    | Other n -> n

  let to_string = function
    | Parse_error -> "JSONParseError"
    | Invalid_request -> "InvalidRequestError"
    | Method_not_found -> "MethodNotFoundError"
    | Invalid_params -> "InvalidParamsError"
    | Internal_error -> "InternalError"
    | Task_not_found -> "TaskNotFoundError"
    | Task_not_cancelable -> "TaskNotCancelableError"
    | Push_notification_not_supported -> "PushNotificationNotSupportedError"
    | Unsupported_operation -> "UnsupportedOperationError"
    | Content_type_not_supported -> "ContentTypeNotSupportedError"
    | Invalid_agent_response -> "InvalidAgentResponseError"
    | Extended_agent_card_not_configured -> "ExtendedAgentCardNotConfiguredError"
    | Extension_support_required -> "ExtensionSupportRequiredError"
    | Version_not_supported -> "VersionNotSupportedError"
    | Other n -> Printf.sprintf "JSON-RPC error %d" n
end

type error_info = {
  reason : string;
  domain : string;
  info_metadata : (string * string) list;
}

type rpc_error = {
  code : Code.t;
  message : string;
  details : Yojson.Safe.t list;
}

type t =
  | Rpc_error of rpc_error
  | Http_error of { status : int; body : string }
  | Transport_error of string
  | Timeout of string
  | Invalid_response of string
  | Stream_ended of { last_task : Types.Task.t option }
  | Poll_timeout of { last_task : Types.Task.t option }
  | No_compatible_interface of string
  | Unsupported_capability of string

let error_info e =
  List.find_map
    (function
      | `Assoc kvs when List.assoc_opt "@type" kvs
                        = Some (`String "type.googleapis.com/google.rpc.ErrorInfo") ->
          let str k = match List.assoc_opt k kvs with Some (`String s) -> s | _ -> "" in
          let info_metadata =
            match List.assoc_opt "metadata" kvs with
            | Some (`Assoc m) ->
                List.filter_map (function k, `String v -> Some (k, v) | _ -> None) m
            | _ -> []
          in
          Some { reason = str "reason"; domain = str "domain"; info_metadata }
      | _ -> None)
    e.details

let pp ppf = function
  | Rpc_error { code; message; _ } ->
      Format.fprintf ppf "%s (%d): %s" (Code.to_string code) (Code.to_int code) message
  | Http_error { status; body } ->
      Format.fprintf ppf "HTTP %d%s" status (if body = "" then "" else ": " ^ body)
  | Transport_error msg -> Format.fprintf ppf "transport error: %s" msg
  | Timeout what -> Format.fprintf ppf "timeout: %s" what
  | Invalid_response msg -> Format.fprintf ppf "invalid response: %s" msg
  | Stream_ended { last_task } ->
      Format.fprintf ppf "stream ended before the task settled%s"
        (match last_task with
         | Some t -> Printf.sprintf " (task %s, %s)" t.id (Types.Task_state.to_string t.status.state)
         | None -> "")
  | Poll_timeout { last_task } ->
      Format.fprintf ppf "gave up waiting for task%s"
        (match last_task with
         | Some t -> Printf.sprintf " %s (last state %s)" t.id (Types.Task_state.to_string t.status.state)
         | None -> "")
  | No_compatible_interface msg -> Format.fprintf ppf "no compatible interface: %s" msg
  | Unsupported_capability msg -> Format.fprintf ppf "unsupported capability: %s" msg

let to_string e = Format.asprintf "%a" pp e
