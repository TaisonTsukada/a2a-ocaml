open Types

type ('req, 'res) op = { meth : string; encode : 'req -> json; decode : 'res Json_decode.t }

type t = {
  version : Protocol_version.t;
  send_message : (Send_message_request.t, Send_message_response.t) op;
  send_streaming_message : (Send_message_request.t, Stream_response.t) op;
  get_task : (Get_task_request.t, Task.t) op;
  cancel_task : (Cancel_task_request.t, Task.t) op;
  subscribe_to_task : (Subscribe_to_task_request.t, Stream_response.t) op;
  extension_headers : string list;
}

let v1_0 =
  { version = V1_0;
    send_message =
      { meth = Jsonrpc.Method.send_message; encode = Codec.send_message_request_to_json;
        decode = Codec.send_message_response };
    send_streaming_message =
      { meth = Jsonrpc.Method.send_streaming_message; encode = Codec.send_message_request_to_json;
        decode = Codec.stream_response };
    get_task =
      { meth = Jsonrpc.Method.get_task; encode = Codec.get_task_request_to_json; decode = Codec.task };
    cancel_task =
      { meth = Jsonrpc.Method.cancel_task; encode = Codec.cancel_task_request_to_json;
        decode = Codec.task };
    subscribe_to_task =
      { meth = Jsonrpc.Method.subscribe_to_task; encode = Codec.subscribe_to_task_request_to_json;
        decode = Codec.stream_response };
    extension_headers = [ "A2A-Extensions" ] }

let v0_3 =
  { version = V0_3;
    send_message =
      { meth = "message/send"; encode = Codec_v0_3.send_message_request_to_json;
        decode = Codec_v0_3.send_message_response };
    send_streaming_message =
      { meth = "message/stream"; encode = Codec_v0_3.send_message_request_to_json;
        decode = Codec_v0_3.stream_response };
    get_task =
      { meth = "tasks/get"; encode = Codec_v0_3.get_task_request_to_json; decode = Codec_v0_3.task };
    cancel_task =
      { meth = "tasks/cancel"; encode = Codec_v0_3.cancel_task_request_to_json;
        decode = Codec_v0_3.task };
    subscribe_to_task =
      { meth = "tasks/resubscribe"; encode = Codec_v0_3.subscribe_to_task_request_to_json;
        decode = Codec_v0_3.stream_response };
    extension_headers = [ "A2A-Extensions"; "X-A2A-Extensions" ] }

let of_version : Protocol_version.t -> t = function V1_0 -> v1_0 | V0_3 -> v0_3
