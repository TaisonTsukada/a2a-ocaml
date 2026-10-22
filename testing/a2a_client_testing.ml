open A2a_client

(* Payload encoders of one protocol version. *)
type codec = {
  stream_response : Stream_response.t -> Yojson.Safe.t;
  send_message_response : Send_message_response.t -> Yojson.Safe.t;
  task : Task.t -> Yojson.Safe.t;
}

let codec : Protocol_version.t -> codec = function
  | V1_0 ->
      { stream_response = Codec.stream_response_to_json;
        send_message_response = Codec.send_message_response_to_json; task = Codec.task_to_json }
  | V0_3 ->
      { stream_response = Codec_v0_3.stream_response_to_json;
        send_message_response = Codec_v0_3.send_message_response_to_json;
        task = Codec_v0_3.task_to_json }

(* What an encoder needs to know about the request being answered. *)
type wire = {
  codec : codec;
  binding : Protocol_binding.t;
  id : Yojson.Safe.t;  (* the JSON-RPC request id, or [`Null] *)
}

let request_json (req : Transport.request) =
  match req.body with
  | None -> None
  | Some b -> ( try Some (Yojson.Safe.from_string b) with Yojson.Json_error _ -> None)

let member k = function Some (`Assoc kvs) -> List.assoc_opt k kvs | _ -> None

let rpc_method req =
  match member "method" (request_json req) with Some (`String m) -> Some m | _ -> None

let params req =
  let json = request_json req in
  match (member "jsonrpc" json, json) with
  | Some _, _ -> Option.value (member "params" json) ~default:`Null
  | None, Some j -> j
  | None, None -> `Null

let result w (json : Yojson.Safe.t) : Yojson.Safe.t =
  match w.binding with
  | Jsonrpc -> `Assoc [ ("jsonrpc", `String "2.0"); ("id", w.id); ("result", json) ]
  | Http_json -> json

let error w ~status code message : Yojson.Safe.t =
  match w.binding with
  | Jsonrpc ->
      `Assoc
        [ ("jsonrpc", `String "2.0"); ("id", w.id);
          ("error", `Assoc [ ("code", `Int (Error.Code.to_int code)); ("message", `String message) ]) ]
  | Http_json ->
      (* Without a known reason, the client reads the error code from [code]. *)
      let code, details =
        match Error.Code.to_reason code with
        | None -> (Error.Code.to_int code, [])
        | Some reason ->
            ( status,
              [ `Assoc
                  [ ("@type", `String "type.googleapis.com/google.rpc.ErrorInfo");
                    ("reason", `String reason); ("domain", `String "a2a-protocol.org") ] ] )
      in
      `Assoc
        [ ("error",
            `Assoc [ ("code", `Int code); ("message", `String message); ("details", `List details) ]) ]

(* The body of a response, as the client will read it. *)
type chunk = Data of string | Pause of float | Break | Stall

module Body = struct
  type t = { mutable chunks : chunk list; mutable pending : string; clock : Eio.Time.Mono.ty Eio.Resource.t }

  let read_methods = []

  let rec single_read t buf =
    if t.pending <> "" then begin
      let n = min (Cstruct.length buf) (String.length t.pending) in
      Cstruct.blit_from_string t.pending 0 buf 0 n;
      t.pending <- String.sub t.pending n (String.length t.pending - n);
      n
    end
    else
      match t.chunks with
      | [] -> raise End_of_file
      | c :: rest -> (
          t.chunks <- rest;
          match c with
          | Data s ->
              t.pending <- s;
              single_read t buf
          | Pause d ->
              Eio.Time.Mono.sleep t.clock d;
              single_read t buf
          | Break -> failwith "connection reset (A2a_client_testing.Step.drop)"
          | Stall -> Eio.Fiber.await_cancel ())
end

let body ~clock chunks : Eio.Flow.source_ty Eio.Resource.t =
  Eio.Resource.T ({ Body.chunks; pending = ""; clock }, Eio.Flow.Pi.source (module Body))

let sse json = Data ("data: " ^ Yojson.Safe.to_string json ^ "\n\n")

module Step = struct
  type t = wire -> chunk

  let event ev w = sse (result w (w.codec.stream_response ev))
  let error code message w = sse (error w ~status:400 code message)
  let raw s _ = Data s
  let sleep d _ = Pause d
  let drop _ = Break
  let hang _ = Stall
end

module Reply = struct
  type response = { status : int; content_type : string; chunks : chunk list }
  type t = { delay : float; respond : wire -> response option }

  let now respond = { delay = 0.; respond = (fun w -> Some (respond w)) }
  let json ?(status = 200) j = { status; content_type = "application/json"; chunks = [ Data (Yojson.Safe.to_string j) ] }

  let stream steps =
    now (fun w ->
        { status = 200; content_type = "text/event-stream"; chunks = List.map (fun s -> s w) steps })

  let send_message_response r = now (fun w -> json (result w (w.codec.send_message_response r)))
  let task t = now (fun w -> json (result w (w.codec.task t)))

  let error ?(status = 400) code message =
    now (fun w ->
        let status = match w.binding with Jsonrpc -> 200 | Http_json -> status in
        json ~status (error w ~status code message))

  let http ~status ?(content_type = "text/plain") body =
    now (fun _ -> { status; content_type; chunks = [ Data body ] })

  let refuse = { delay = 0.; respond = (fun _ -> None) }
  let after d r = { r with delay = r.delay +. d }
end

type agent = {
  codec : codec;
  binding : Protocol_binding.t;
  clock : Eio.Time.Mono.ty Eio.Resource.t;
  handler : Transport.request -> Reply.t;
  mutable received : Transport.request list;  (* newest first *)
}

let agent ?(protocol = Protocol.default) ~clock handler =
  { codec = codec (Protocol.version protocol); binding = Protocol.binding protocol; clock = (clock :> Eio.Time.Mono.ty Eio.Resource.t); handler;
    received = [] }

let requests a = List.rev a.received

let transport a : Transport.t =
 fun ~sw:_ req ->
  a.received <- req :: a.received;
  let reply = a.handler req in
  if reply.delay > 0. then Eio.Time.Mono.sleep a.clock reply.delay;
  let id = Option.value (member "id" (request_json req)) ~default:`Null in
  match reply.respond { codec = a.codec; binding = a.binding; id } with
  | None -> failwith "connection refused (A2a_client_testing.Reply.refuse)"
  | Some r ->
      { Transport.status = r.status;
        headers = [ ("content-type", r.content_type) ];
        body = body ~clock:a.clock r.chunks }
