type meth = [ `GET | `POST | `DELETE ]

type request = {
  meth : meth;
  uri : Uri.t;
  headers : (string * string) list;
  body : string option;
}

type response = {
  status : int;
  headers : (string * string) list;
  body : Eio.Flow.source_ty Eio.Resource.t;
}

type t = sw:Eio.Switch.t -> request -> response

let header name (headers : (string * string) list) =
  let name = String.lowercase_ascii name in
  List.find_map
    (fun (k, v) -> if String.lowercase_ascii k = name then Some v else None)
    headers

let media_type headers =
  match header "content-type" headers with
  | None -> None
  | Some v ->
      let v = match String.index_opt v ';' with Some i -> String.sub v 0 i | None -> v in
      Some (String.lowercase_ascii (String.trim v))

type connection = [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t
type https = Uri.t -> connection -> connection

let no_tls name =
  failwith ("https:// URL but no TLS wrapper configured (pass ~https to Transport." ^ name ^ ")")

let call client ~sw (req : request) =
  let headers = Cohttp.Header.of_list req.headers in
  let body = Option.map Cohttp_eio.Body.of_string req.body in
  Cohttp_eio.Client.call client ~sw ~headers ?body (req.meth :> Http.Method.t) req.uri

let response resp body =
  { status = Cohttp.Code.code_of_status (Cohttp.Response.status resp);
    headers = Cohttp.Header.to_list (Cohttp.Response.headers resp);
    body }

let cohttp ?(https : https option) net : t =
  let client = Cohttp_eio.Client.make ~https:(Option.map (fun f uri flow -> (f uri flow :> connection)) https) net in
  fun ~sw req ->
    if Uri.scheme req.uri = Some "https" && Option.is_none https then no_tls "cohttp";
    let resp, body = call client ~sw req in
    response resp (body :> Eio.Flow.source_ty Eio.Resource.t)

module Tracked_body = struct
  type t = { inner : Eio.Flow.source_ty Eio.Resource.t; on_eof : unit -> unit }

  let read_methods = []

  let single_read t buf =
    match Eio.Flow.single_read t.inner buf with
    | n -> n
    | exception End_of_file ->
        t.on_eof ();
        raise End_of_file
end

let tracked_body inner ~on_eof : Eio.Flow.source_ty Eio.Resource.t =
  Eio.Resource.T ({ Tracked_body.inner; on_eof }, Eio.Flow.Pi.source (module Tracked_body))

let reusable (resp : Http.Response.t) =
  let headers = Http.Response.headers resp in
  Http.Response.is_keep_alive resp
  && (Http.Header.get headers "content-length" <> None
     || Http.Header.get_transfer_encoding headers = Http.Transfer.Chunked)

type idle = { conn : connection; since : Mtime.t }

let drain_grace = 0.1
let drain_limit = 64 * 1024

let drain clock body =
  let cs = Cstruct.create 4096 in
  let rec loop budget =
    budget > 0
    && match Eio.Flow.single_read body cs with n -> loop (budget - n) | exception End_of_file -> true
  in
  match Eio.Time.Timeout.run (Eio.Time.Timeout.seconds clock drain_grace) (fun () -> Ok (loop drain_limit)) with
  | Ok done_ -> done_
  | Error `Timeout -> false
  | exception (Eio.Cancel.Cancelled _ as e) -> raise e
  | exception _ -> false

let pooled ?(https : https option) ?(max_idle_per_host = 8) ?(idle_timeout = 30.0) ~sw:pool_sw
    ~clock net : t =
  let clock = (clock :> Eio.Time.Mono.ty Eio.Resource.t) in
  let idle : (string * string * int, idle list) Hashtbl.t = Hashtbl.create 8 in
  let lock = Mutex.create () in
  let key uri =
    let scheme = Option.value (Uri.scheme uri) ~default:"http" in
    let port = match Uri.port uri with Some p -> p | None -> if scheme = "https" then 443 else 80 in
    (scheme, Uri.host_with_default ~default:"localhost" uri, port)
  in
  let close conn = try Eio.Resource.close conn with _ -> () in
  let fresh now { since; _ } =
    Mtime.Span.to_float_ns (Mtime.span since now) /. 1e9 <= idle_timeout
  in
  let sweep now =
    let stale = ref [] in
    Hashtbl.filter_map_inplace
      (fun _ l ->
        let keep, drop = List.partition (fresh now) l in
        stale := drop @ !stale;
        if keep = [] then None else Some keep)
      idle;
    !stale
  in
  let checkout k =
    let found, stale =
      Mutex.protect lock @@ fun () ->
      let stale = sweep (Eio.Time.Mono.now clock) in
      match Hashtbl.find_opt idle k with
      | Some ({ conn; _ } :: rest) ->
          if rest = [] then Hashtbl.remove idle k else Hashtbl.replace idle k rest;
          (Some conn, stale)
      | _ -> (None, stale)
    in
    List.iter (fun { conn; _ } -> close conn) stale;
    found
  in
  let checkin k conn =
    let kept =
      Mutex.protect lock @@ fun () ->
      let l = Option.value (Hashtbl.find_opt idle k) ~default:[] in
      List.length l < max_idle_per_host
      && (Hashtbl.replace idle k ({ conn; since = Eio.Time.Mono.now clock } :: l);
          true)
    in
    if not kept then close conn
  in
  let release k conn ~body ~read_to_end =
    if read_to_end then checkin k conn
    else
      Eio.Fiber.fork ~sw:pool_sw (fun () -> if drain clock body then checkin k conn else close conn)
  in
  let connect uri =
    let scheme, host, port = key uri in
    let addr =
      match Eio.Net.getaddrinfo_stream ~service:(string_of_int port) net host with
      | a :: _ -> a
      | [] -> failwith ("cannot resolve host " ^ host)
    in
    let socket = (Eio.Net.connect ~sw:pool_sw net addr :> connection) in
    match (scheme, https) with
    | "https", Some wrap -> wrap uri socket
    | "https", None ->
        close socket;
        no_tls "pooled"
    | _ -> socket
  in
  fun ~sw req ->
    let k = key req.uri in
    let attempt conn =
      let state = ref `Busy in
      Eio.Switch.on_release sw (fun () ->
          match !state with
          | `Reusable (body, read_to_end) -> release k conn ~body ~read_to_end
          | `Busy -> close conn);
      let client = Cohttp_eio.Client.make_generic (fun ~sw:_ _ -> conn) in
      let resp, body = Eio.Switch.run @@ fun sw -> call client ~sw req in
      let body = (body :> Eio.Flow.source_ty Eio.Resource.t) in
      if reusable resp then begin
        state := `Reusable (body, false);
        response resp (tracked_body body ~on_eof:(fun () -> state := `Reusable (body, true)))
      end
      else response resp body
    in
    match checkout k with
    | None -> attempt (connect req.uri)
    | Some conn -> (
        match attempt conn with
        | r -> r
        | exception (Eio.Cancel.Cancelled _ as e) -> raise e
        | exception _ -> attempt (connect req.uri))
