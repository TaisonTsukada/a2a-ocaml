open Types

type t = {
  version : Protocol_version.t;
  binding : Protocol_binding.t;
  extension_headers : string list;
  send_message : (Send_message_request.t, Send_message_response.t) Op.t;
  send_streaming_message : (Send_message_request.t, Stream_response.t) Op.t;
  get_task : (Get_task_request.t, Task.t) Op.t;
  list_tasks : (List_tasks_request.t, List_tasks_response.t) Op.t option;
  cancel_task : (Cancel_task_request.t, Task.t) Op.t;
  subscribe_to_task : (Subscribe_to_task_request.t, Stream_response.t) Op.t;
  create_push_config : (Task_push_notification_config.t, Task_push_notification_config.t) Op.t;
  get_push_config : (Task_push_notification_config_request.t, Task_push_notification_config.t) Op.t;
  list_push_configs :
    ( List_task_push_notification_configs_request.t,
      List_task_push_notification_configs_response.t )
    Op.t;
  delete_push_config : (Task_push_notification_config_request.t, unit) Op.t;
  get_extended_agent_card : (Get_extended_agent_card_request.t, Agent_card.t) Op.t;
}

let v1_0 binding =
  let op name (meth, path) encode decode =
    match binding with
    | Protocol_binding.Jsonrpc -> Jsonrpc.op ~meth:name encode decode
    | Http_json -> Rest.op ~meth ~path encode decode
  in
  { version = V1_0; binding; extension_headers = [ "A2A-Extensions" ];
    send_message =
      op "SendMessage" (`POST, "/message:send") Codec.send_message_request_to_json
        Codec.send_message_response;
    send_streaming_message =
      op "SendStreamingMessage" (`POST, "/message:stream") Codec.send_message_request_to_json
        Codec.stream_response;
    get_task = op "GetTask" (`GET, "/tasks/{id}") Codec.get_task_request_to_json Codec.task;
    list_tasks =
      Some (op "ListTasks" (`GET, "/tasks") Codec.list_tasks_request_to_json Codec.list_tasks_response);
    cancel_task =
      op "CancelTask" (`POST, "/tasks/{id}:cancel") Codec.cancel_task_request_to_json Codec.task;
    subscribe_to_task =
      op "SubscribeToTask" (`POST, "/tasks/{id}:subscribe")
        Codec.subscribe_to_task_request_to_json Codec.stream_response;
    create_push_config =
      op "CreateTaskPushNotificationConfig" (`POST, "/tasks/{taskId}/pushNotificationConfigs")
        Codec.task_push_notification_config_to_json Codec.task_push_notification_config;
    get_push_config =
      op "GetTaskPushNotificationConfig" (`GET, "/tasks/{taskId}/pushNotificationConfigs/{id}")
        Codec.task_push_notification_config_request_to_json Codec.task_push_notification_config;
    list_push_configs =
      op "ListTaskPushNotificationConfigs" (`GET, "/tasks/{taskId}/pushNotificationConfigs")
        Codec.list_task_push_notification_configs_request_to_json
        Codec.list_task_push_notification_configs_response;
    delete_push_config =
      op "DeleteTaskPushNotificationConfig"
        (`DELETE, "/tasks/{taskId}/pushNotificationConfigs/{id}")
        Codec.task_push_notification_config_request_to_json Codec_base.empty;
    get_extended_agent_card =
      op "GetExtendedAgentCard" (`GET, "/extendedAgentCard")
        Codec.get_extended_agent_card_request_to_json Codec.agent_card }

let v0_3 =
  let op meth encode decode = Jsonrpc.op ~meth encode decode in
  { version = V0_3; binding = Jsonrpc; extension_headers = [ "A2A-Extensions"; "X-A2A-Extensions" ];
    send_message =
      op "message/send" Codec_v0_3.send_message_request_to_json Codec_v0_3.send_message_response;
    send_streaming_message =
      op "message/stream" Codec_v0_3.send_message_request_to_json Codec_v0_3.stream_response;
    get_task = op "tasks/get" Codec_v0_3.get_task_request_to_json Codec_v0_3.task;
    list_tasks = None;
    cancel_task = op "tasks/cancel" Codec_v0_3.cancel_task_request_to_json Codec_v0_3.task;
    subscribe_to_task =
      op "tasks/resubscribe" Codec_v0_3.subscribe_to_task_request_to_json Codec_v0_3.stream_response;
    create_push_config =
      op "tasks/pushNotificationConfig/set" Codec_v0_3.task_push_notification_config_to_json
        Codec_v0_3.task_push_notification_config;
    get_push_config =
      op "tasks/pushNotificationConfig/get"
        Codec_v0_3.task_push_notification_config_request_to_json
        Codec_v0_3.task_push_notification_config;
    list_push_configs =
      op "tasks/pushNotificationConfig/list"
        Codec_v0_3.list_task_push_notification_configs_request_to_json
        Codec_v0_3.list_task_push_notification_configs_response;
    delete_push_config =
      op "tasks/pushNotificationConfig/delete"
        Codec_v0_3.task_push_notification_config_request_to_json Codec_base.empty;
    get_extended_agent_card =
      op "agent/getAuthenticatedExtendedCard" (fun _ -> `Null) Codec.agent_card }

let supports (version : Protocol_version.t) (binding : Protocol_binding.t) =
  match (version, binding) with V1_0, _ | V0_3, Jsonrpc -> true | V0_3, Http_json -> false

let v1_0_jsonrpc = v1_0 Jsonrpc
let v1_0_rest = v1_0 Http_json

let make version binding =
  if not (supports version binding) then
    invalid_arg "the HTTP+JSON binding is only supported with protocol 1.0";
  match (version : Protocol_version.t), (binding : Protocol_binding.t) with
  | V1_0, Jsonrpc -> v1_0_jsonrpc
  | V1_0, Http_json -> v1_0_rest
  | V0_3, _ -> v0_3
