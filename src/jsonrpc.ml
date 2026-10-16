module D = Json_decode

let ( let* ) = Result.bind

module Method = struct
  let send_message = "SendMessage"
  let send_streaming_message = "SendStreamingMessage"
  let get_task = "GetTask"
  let cancel_task = "CancelTask"
  let subscribe_to_task = "SubscribeToTask"
end

let new_id () = Id.uuid_v4 ()

let request ~id ~meth (params : Yojson.Safe.t) : Yojson.Safe.t =
  `Assoc
    [ ("jsonrpc", `String "2.0"); ("id", `String id); ("method", `String meth);
      ("params", params) ]

let rpc_error : Error.rpc_error D.t =
  D.obj @@ fun kvs ->
  let* code = D.field "code" D.int kvs in
  let* message = D.string_field_default "message" kvs in
  let details =
    match List.assoc_opt "data" kvs with
    | None | Some `Null -> []
    | Some (`List l) -> l
    | Some other -> [ other ]
  in
  Ok { Error.code = Error.Code.of_int code; message; details }

let invalid fmt = Printf.ksprintf (fun s -> Error (Error.Invalid_response s)) fmt

let parse_response ~expected_id (json : Yojson.Safe.t) :
    (Yojson.Safe.t, Error.t) result =
  match json with
  | `Assoc kvs -> (
      let* () =
        match List.assoc_opt "jsonrpc" kvs with
        | Some (`String "2.0") -> Ok ()
        | Some v -> invalid "unsupported jsonrpc version %s" (Yojson.Safe.to_string v)
        | None -> invalid "missing \"jsonrpc\" member"
      in
      let id = List.assoc_opt "id" kvs in
      let id_matches = id = Some (`String expected_id) in
      match (List.assoc_opt "result" kvs, List.assoc_opt "error" kvs) with
      | Some _, Some _ -> invalid "response has both \"result\" and \"error\""
      | None, None -> invalid "response has neither \"result\" nor \"error\""
      | Some result, None ->
          if id_matches then Ok result
          else
            invalid "response id %s does not match request id %S"
              (Option.fold ~none:"<missing>" ~some:Yojson.Safe.to_string id)
              expected_id
      | None, Some err -> (
          match rpc_error err with
          | Error e -> invalid "malformed error object %s" (D.error_to_string e)
          | Ok e ->
              if id_matches || id = Some `Null || id = None then
                Error (Error.Rpc_error e)
              else
                invalid "error response id %s does not match request id %S"
                  (Option.fold ~none:"<missing>" ~some:Yojson.Safe.to_string id)
                  expected_id))
  | j -> invalid "expected a JSON-RPC response object, got %s" (D.type_name j)

let parse_json s =
  match Yojson.Safe.from_string s with
  | j -> Ok j
  | exception Yojson.Json_error msg -> invalid "invalid JSON: %s" msg

let decode_response ~expected_id (d : 'a D.t) body : ('a, Error.t) result =
  let* json = parse_json body in
  let* result = parse_response ~expected_id json in
  match d result with
  | Ok v -> Ok v
  | Error e ->
      Error (Error.Invalid_response (D.error_to_string (D.under "result" e)))
