(** JSON conversion for the A2A 0.3 wire format, onto the same types as
    {!Codec}.

    Differences from 1.0:
    - objects carry a [kind] ("message", "task", "status-update",
      "artifact-update"; parts "text", "file", "data"). When it is missing,
      it is inferred from the fields;
    - enums are lowercase ("user", "input-required"); state "unknown" is
      [Unspecified];
    - a file part nests [bytes] or [uri], [name] and [mimeType] under [file];
    - a data part holds an object. Other values travel as [{"value": v}] with
      metadata [data_part_compat: true], as in the official SDKs, and are
      unwrapped when decoded;
    - text and data parts have no media type, and requests have no [tenant];
      both are dropped;
    - [returnImmediately] is sent as its negation, [blocking];
    - timestamps without a zone are read as UTC, and ones that cannot be
      parsed are dropped;
    - [final] on status updates is ignored when decoding; the task state
      says whether a stream is over;
    - a push notification config nests [id], [url], [token] and
      [authentication] under [pushNotificationConfig], and authentication
      lists [schemes] (joined with commas into [scheme] when decoded);
    - there is no [ListTasks], and push notification configs are listed
      without pagination. *)

open Types

type 'a decoder = 'a Json_decode.t

(** {1 Enums} *)

val role : Role.t decoder
val task_state : Task_state.t decoder
val task_state_to_json : Task_state.t -> json

(** {1 Objects} *)

val part : Part.t decoder
val part_to_json : Part.t -> json
val message : Message.t decoder
val message_to_json : Message.t -> json
val task_status : Task_status.t decoder
val task_status_to_json : Task_status.t -> json
val artifact : Artifact.t decoder
val artifact_to_json : Artifact.t -> json
val task : Task.t decoder
val task_to_json : Task.t -> json
val status_update : Task_status_update_event.t decoder
val status_update_to_json : Task_status_update_event.t -> json
val artifact_update : Task_artifact_update_event.t decoder
val artifact_update_to_json : Task_artifact_update_event.t -> json

(** {1 Results} *)

val send_message_response : Send_message_response.t decoder
val send_message_response_to_json : Send_message_response.t -> json
val stream_response : Stream_response.t decoder
val stream_response_to_json : Stream_response.t -> json

(** {1 Push notification configs} *)

val task_push_notification_config : Task_push_notification_config.t decoder
val task_push_notification_config_to_json : Task_push_notification_config.t -> json

val list_task_push_notification_configs_response :
  List_task_push_notification_configs_response.t decoder

(** {1 Request parameters} *)

val send_message_configuration_to_json : Send_message_configuration.t -> json
val send_message_request_to_json : Send_message_request.t -> json
val get_task_request_to_json : Get_task_request.t -> json
val cancel_task_request_to_json : Cancel_task_request.t -> json
val subscribe_to_task_request_to_json : Subscribe_to_task_request.t -> json

val task_push_notification_config_request_to_json :
  Task_push_notification_config_request.t -> json

val list_task_push_notification_configs_request_to_json :
  List_task_push_notification_configs_request.t -> json
