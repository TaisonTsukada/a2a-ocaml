(** HTTP transport: how the client exchanges one request for one
    response. Supply your own to add proxies, tracing or test doubles. *)

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
(** The response body must stay readable until [sw] is released, and the
    connection must be released with it. *)

val header : string -> (string * string) list -> string option
(** Case-insensitive lookup. *)

val media_type : (string * string) list -> string option
(** The [Content-Type] without parameters, lowercased. *)

type connection = [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t

type https = Uri.t -> connection -> connection
(** Wraps a TCP connection in TLS for the given URL, e.g. with [tls-eio]. *)

val cohttp : ?https:https -> _ Eio.Net.t -> t
(** A new connection per request, closed when the request's switch is
    released. Honours [Cohttp_eio.Client.set_proxies]. *)

val pooled :
  ?https:https ->
  ?max_idle_per_host:int ->
  ?idle_timeout:float ->
  sw:Eio.Switch.t ->
  clock:_ Eio.Time.Mono.t ->
  _ Eio.Net.t ->
  t
(** HTTP/1.1 keep-alive: a connection whose response was read to the end
    goes back to an idle pool when the request's switch is released, and
    is reused by the next request to the same scheme, host and port. A
    response that was not read to the end (a finished stream the server
    has not closed yet, cancellation, an error) is drained in the
    background for up to 0.1 s; if it does not end by then, its
    connection is closed instead.

    Connections belong to [sw], the pool's lifetime; they are all closed
    when it is released. Each request still holds its connection only
    until its own switch is released, so streams and concurrent requests
    each get their own connection.

    @param max_idle_per_host idle connections kept per host. Default 8.
    @param idle_timeout seconds an idle connection is kept. Default 30.
      Expired connections are closed at the next request.

    A request that fails on a reused connection (the server may have
    closed it meanwhile) is retried once on a new connection. Proxies are
    not supported. *)
