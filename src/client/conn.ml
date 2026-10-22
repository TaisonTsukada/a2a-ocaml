(* Shared by every operation: the client record, request building and
   one unary HTTP exchange. *)

open Types

let src = Logs.Src.create "a2a-client" ~doc:"A2A protocol client"

module Log = (val Logs.src_log src : Logs.LOG)

let ( let* ) = Result.bind

module Auth = struct
  type t = unit -> (string * string) list

  let none : t = fun () -> []
  let bearer token : t = fun () -> [ ("Authorization", "Bearer " ^ token) ]
  let header name value : t = fun () -> [ (name, value) ]
  let headers hs : t = fun () -> hs
  let dynamic (f : unit -> (string * string) list) : t = f
end

module Reconnect = struct
  type t = { max_attempts : int; delay : float; max_delay : float; backoff : float }

  let none = { max_attempts = 0; delay = 1.0; max_delay = 30.0; backoff = 2.0 }

  let make ?(max_attempts = 5) ?(delay = 1.0) ?(max_delay = 30.0) ?(backoff = 2.0) () =
    if max_attempts < 0 || delay < 0. || backoff < 1. then
      invalid_arg "Reconnect.make: need max_attempts >= 0, delay >= 0 and backoff >= 1";
    { max_attempts; delay; max_delay; backoff }
end

type t = {
  transport : Transport.t;
  clock : Eio.Time.Mono.ty Eio.Resource.t;
  endpoint : Uri.t;
  tenant : string option;
  auth : Auth.t;
  headers : (string * string) list;
  extensions : string list;
  timeout : float option;
  stream_idle_timeout : float option;
  max_response_size : int;
  reconnect : Reconnect.t;
  card : Agent_card.t option;
  wire : Wire.t;
}

let default_timeout = 30.0
let default_max_response_size = 16 * 1024 * 1024

let create ?(auth = Auth.none) ?(headers = []) ?tenant ?(extensions = [])
    ?(timeout = default_timeout) ?stream_idle_timeout
    ?(max_response_size = default_max_response_size) ?(reconnect = Reconnect.none) ?card
    ?(protocol_version = Protocol_version.V1_0) ?(binding = Protocol_binding.Jsonrpc) ~clock
    ~transport endpoint =
  let timeout = Some timeout in
  { transport; clock = (clock :> Eio.Time.Mono.ty Eio.Resource.t); endpoint;
    tenant; auth; headers; extensions; timeout; stream_idle_timeout;
    max_response_size; reconnect; card; wire = Wire.make protocol_version binding }

let endpoint t = t.endpoint
let agent_card t = t.card
let with_agent_card t card = { t with card = Some card }
let version t = t.wire.version
let binding t = t.wire.binding

let redact_uri u = Uri.with_query (Uri.with_userinfo u None) [] |> Uri.to_string

let guard what f =
  match f () with
  | v -> Ok v
  | exception (Eio.Cancel.Cancelled _ as e) -> raise e
  | exception e -> Error (Error.Transport_error (what ^ ": " ^ Printexc.to_string e))

let with_timeout clock secs what f =
  match secs with
  | None -> f ()
  | Some s when s = Float.infinity -> f ()
  | Some s -> (
      match Eio.Time.Timeout.run (Eio.Time.Timeout.seconds clock s) (fun () -> Ok (f ())) with
      | Ok r -> r
      | Error `Timeout -> Error (Error.Timeout (Printf.sprintf "%s (%gs)" what s)))

let read_buffer_size = 16 * 1024

let read_all ~limit (body : Eio.Flow.source_ty Eio.Resource.t) =
  let buf = Buffer.create 4096 in
  let cs = Cstruct.create read_buffer_size in
  let rec loop () =
    match Eio.Flow.single_read body cs with
    | n ->
        if Buffer.length buf + n > limit then
          Error (Error.Invalid_response (Printf.sprintf "response body exceeds %d bytes" limit))
        else begin
          Buffer.add_string buf (Cstruct.to_string ~len:n cs);
          loop ()
        end
    | exception End_of_file -> Ok (Buffer.contents buf)
  in
  Result.join (guard "reading response body" loop)

let excerpt_limit = 1024
let error_body_limit = 64 * 1024

let excerpt (resp : Transport.response) =
  let cs = Cstruct.create excerpt_limit in
  match Eio.Flow.single_read resp.body cs with
  | n -> Cstruct.to_string ~len:n cs
  | exception (Eio.Cancel.Cancelled _ as e) -> raise e
  | exception _ -> ""

let http_error ?error_of_body (resp : Transport.response) =
  let fallback body = Error.Http_error { status = resp.status; body } in
  match error_of_body with
  | None -> fallback (excerpt resp)
  | Some parse -> (
      match read_all ~limit:error_body_limit resp.body with
      | Error _ -> fallback ""
      | Ok body -> (
          match parse body with
          | Some e -> e
          | None ->
              fallback
                (if String.length body > excerpt_limit then String.sub body 0 excerpt_limit
                 else body)))

let is_success status = status >= 200 && status < 300

let send ?error_of_body (transport : Transport.t) ~sw what req =
  let* resp = guard what (fun () -> transport ~sw req) in
  if is_success resp.status then Ok resp else Error (http_error ?error_of_body resp)

let strip_trailing_slash path =
  if String.ends_with ~suffix:"/" path then String.sub path 0 (String.length path - 1) else path

let request_headers t ~accept (r : _ Op.request) =
  let extensions =
    match t.extensions with
    | [] -> []
    | l ->
        let v = String.concat "," l in
        List.map (fun name -> (name, v)) t.wire.extension_headers
  in
  (match r.body with Some _ -> [ ("Content-Type", r.content_type) ] | None -> [])
  @ [ ("Accept", accept); ("A2A-Version", Protocol_version.to_string t.wire.version) ]
  @ extensions @ t.headers @ t.auth ()

let http_request t (r : _ Op.request) ~accept ~extra_headers =
  let uri =
    if r.path = "" then t.endpoint
    else Uri.with_path t.endpoint (strip_trailing_slash (Uri.path t.endpoint) ^ r.path)
  in
  let uri = if r.query = [] then uri else Uri.add_query_params' uri r.query in
  { Transport.meth = r.meth; uri;
    headers = request_headers t ~accept r @ extra_headers;
    body = r.body }

let request_id (r : _ Op.request) = Option.value r.id ~default:"-"

let call t (op : _ Op.t) req =
  let r = op.prepare req in
  let id = request_id r in
  Log.debug (fun m -> m "%s -> %s (id %s)" op.name (redact_uri t.endpoint) id);
  let result =
    with_timeout t.clock t.timeout op.name @@ fun () ->
    Eio.Switch.run @@ fun sw ->
    let req = http_request t r ~accept:r.accept ~extra_headers:[] in
    let* resp = send ?error_of_body:r.error_of_body t.transport ~sw "sending request" req in
    let* body = read_all ~limit:t.max_response_size resp.body in
    r.decode body
  in
  (match result with
   | Ok _ -> Log.debug (fun m -> m "%s <- ok (id %s)" op.name id)
   | Error e -> Log.info (fun m -> m "%s failed (id %s): %a" op.name id Error.pp e));
  result

let optional t what = function
  | Some op -> Ok op
  | None ->
      Error
        (Error.Unsupported_capability
           (Printf.sprintf "%s is not part of protocol %s" what
              (Protocol_version.to_string t.wire.version)))

let require_capability t what declared =
  match t.card with
  | Some card when declared card <> Some true ->
      Error (Error.Unsupported_capability (Printf.sprintf "the Agent Card does not declare %s" what))
  | _ -> Ok ()

let with_tenant t = function Some _ as x -> x | None -> t.tenant


let get_task t ?tenant ?history_length id =
  call t t.wire.get_task { Get_task_request.tenant = with_tenant t tenant; id; history_length }
