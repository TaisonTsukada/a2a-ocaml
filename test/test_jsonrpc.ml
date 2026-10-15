open A2a_client

let parse = Yojson.Safe.from_string

let check_invalid name r =
  match r with
  | Error (Error.Invalid_response _) -> ()
  | Error e -> Alcotest.failf "%s: expected Invalid_response, got %s" name (Error.to_string e)
  | Ok _ -> Alcotest.failf "%s: expected an error" name

let test_request_envelope () =
  Alcotest.(check string) "envelope"
    {|{"jsonrpc":"2.0","id":"abc","method":"SendMessage","params":{}}|}
    (Yojson.Safe.to_string (Jsonrpc.request ~id:"abc" ~meth:Jsonrpc.Method.send_message (`Assoc [])));
  Alcotest.(check (list string)) "v1.0 method names"
    [ "SendMessage"; "SendStreamingMessage"; "GetTask"; "CancelTask"; "SubscribeToTask" ]
    Jsonrpc.Method.[ send_message; send_streaming_message; get_task; cancel_task; subscribe_to_task ]

let test_result () =
  match Jsonrpc.parse_response ~expected_id:"1" (parse {|{"jsonrpc":"2.0","id":"1","result":{"x":1}}|}) with
  | Ok (`Assoc [ ("x", `Int 1) ]) -> ()
  | _ -> Alcotest.fail "result"

let test_envelope_violations () =
  let p s = Jsonrpc.parse_response ~expected_id:"1" (parse s) in
  check_invalid "id mismatch" (p {|{"jsonrpc":"2.0","id":"2","result":{}}|});
  check_invalid "numeric id" (p {|{"jsonrpc":"2.0","id":1,"result":{}}|});
  check_invalid "missing id" (p {|{"jsonrpc":"2.0","result":{}}|});
  check_invalid "version" (p {|{"jsonrpc":"1.0","id":"1","result":{}}|});
  check_invalid "no version" (p {|{"id":"1","result":{}}|});
  check_invalid "both" (p {|{"jsonrpc":"2.0","id":"1","result":{},"error":{"code":1,"message":"x"}}|});
  check_invalid "neither" (p {|{"jsonrpc":"2.0","id":"1"}|});
  check_invalid "malformed error" (p {|{"jsonrpc":"2.0","id":"1","error":{"message":"no code"}}|});
  check_invalid "error id mismatch" (p {|{"jsonrpc":"2.0","id":"9","error":{"code":-32603,"message":"x"}}|});
  check_invalid "array" (p {|[]|});
  check_invalid "bad json" (Jsonrpc.parse_json "{\"jsonrpc\":")

let test_a2a_errors () =
  let codes =
    [ (-32001, Error.Code.Task_not_found); (-32002, Task_not_cancelable);
      (-32003, Push_notification_not_supported); (-32004, Unsupported_operation);
      (-32005, Content_type_not_supported); (-32006, Invalid_agent_response);
      (-32007, Extended_agent_card_not_configured); (-32008, Extension_support_required);
      (-32009, Version_not_supported); (-32700, Parse_error); (-32600, Invalid_request);
      (-32601, Method_not_found); (-32602, Invalid_params); (-32603, Internal_error);
      (-32050, Other (-32050)) ]
  in
  List.iter
    (fun (n, code) ->
      Alcotest.(check bool) (string_of_int n) true (Error.Code.of_int n = code);
      Alcotest.(check int) "to_int" n (Error.Code.to_int code))
    codes

(* Spec §9.5 example; a null id is allowed for errors. *)
let test_error_details () =
  let body =
    {|{"jsonrpc":"2.0","id":null,"error":{"code":-32001,"message":"Task not found","data":[
        {"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"TASK_NOT_FOUND","domain":"a2a-protocol.org",
         "metadata":{"taskId":"nonexistent-task-id"}}]}}|}
  in
  match Jsonrpc.parse_response ~expected_id:"1" (parse body) with
  | Error (Error.Rpc_error e) -> (
      Alcotest.(check bool) "code" true (e.code = Error.Code.Task_not_found);
      Alcotest.(check string) "message" "Task not found" e.message;
      match Error.error_info e with
      | Some info ->
          Alcotest.(check string) "reason" "TASK_NOT_FOUND" info.reason;
          Alcotest.(check (list (pair string string))) "metadata"
            [ ("taskId", "nonexistent-task-id") ] info.info_metadata
      | None -> Alcotest.fail "ErrorInfo")
  | _ -> Alcotest.fail "expected Rpc_error"

let tests =
  [ ("request envelope", `Quick, test_request_envelope);
    ("result", `Quick, test_result);
    ("envelope violations", `Quick, test_envelope_violations);
    ("A2A error codes", `Quick, test_a2a_errors);
    ("error details (spec 9.5)", `Quick, test_error_details) ]
