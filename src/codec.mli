(** JSON conversion for the A2A 1.0 wire format (ProtoJSON).

    The client uses these internally; they are exposed for applications that
    store or forward protocol objects as JSON. Decoders never raise: unknown
    fields are ignored, absent scalars take their default value, and errors
    carry the JSON path of the offending value. Agent Cards are accepted in
    both the 1.0 and the 0.3 layout. {!Codec_v0_3} has the same functions
    for the 0.3 wire format. *)

open Types

type 'a decoder = 'a Json_decode.t

val decode_string : 'a decoder -> string -> ('a, string) result
(** Parse and decode. The error names the JSON path, e.g.
    ["at $.status.state: unknown TaskState \"done\""]. *)

val decode_json : 'a decoder -> json -> ('a, string) result

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

(** {1 Task lists} *)

val list_tasks_response : List_tasks_response.t decoder

(** {1 Request parameters} *)

val send_message_configuration_to_json : Send_message_configuration.t -> json
val send_message_request_to_json : Send_message_request.t -> json
val get_task_request_to_json : Get_task_request.t -> json
val cancel_task_request_to_json : Cancel_task_request.t -> json
val subscribe_to_task_request_to_json : Subscribe_to_task_request.t -> json
val list_tasks_request_to_json : List_tasks_request.t -> json

val task_push_notification_config_request_to_json :
  Task_push_notification_config_request.t -> json

val list_task_push_notification_configs_request_to_json :
  List_task_push_notification_configs_request.t -> json

val get_extended_agent_card_request_to_json : Get_extended_agent_card_request.t -> json

(** {1 Agent Card} *)

val agent_card : Agent_card.t decoder
(** Either layout. A 0.3 card's [url], [preferredTransport],
    [additionalInterfaces] and [protocolVersion] become
    [supported_interfaces] entries, main interface first. Its [security]
    lists, [type]-tagged security schemes and
    [supportsAuthenticatedExtendedCard] map to their 1.0 counterparts; of
    several OAuth flows, the first (authorization code, client credentials,
    implicit, password) is kept. *)
