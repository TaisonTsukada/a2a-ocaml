type meth = [ `GET | `POST ]

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

type https =
  Uri.t ->
  [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t ->
  [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t

let cohttp ?(https : https option) net : t =
  let https = Option.map (fun f uri flow -> (f uri flow :> [ Eio.Resource.close_ty | Eio.Flow.two_way_ty ] Eio.Resource.t)) https in
  let client = Cohttp_eio.Client.make ~https net in
  fun ~sw req ->
    if Uri.scheme req.uri = Some "https" && Option.is_none https then
      failwith "https:// URL but no TLS wrapper configured (pass ~https to Transport.cohttp)";
    let headers = Cohttp.Header.of_list req.headers in
    let body = Option.map Cohttp_eio.Body.of_string req.body in
    let resp, body =
      Cohttp_eio.Client.call client ~sw ~headers ?body (req.meth :> Http.Method.t) req.uri
    in
    { status = Cohttp.Code.code_of_status (Cohttp.Response.status resp);
      headers = Cohttp.Header.to_list (Cohttp.Response.headers resp);
      body = (body :> Eio.Flow.source_ty Eio.Resource.t) }
