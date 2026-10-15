(* Test doubles: a scripted response body and a recording transport. *)

open A2a_client

(* One step of a scripted body. *)
type step =
  | Chunk of string  (** delivered by one or more reads *)
  | Sleep of float  (** wait on the mock clock before the next step *)
  | Check of (unit -> unit)  (** run an assertion before continuing *)
  | Block  (** never deliver anything more (until cancelled) *)
  | Raise of exn  (** connection failure *)

module Scripted = struct
  type t = {
    mutable steps : step list;
    mutable pending : string;
    clock : Eio.Time.Mono.ty Eio.Resource.t;
  }

  let read_methods = []

  let rec single_read t buf =
    if t.pending <> "" then begin
      let n = min (Cstruct.length buf) (String.length t.pending) in
      Cstruct.blit_from_string t.pending 0 buf 0 n;
      t.pending <- String.sub t.pending n (String.length t.pending - n);
      n
    end
    else
      match t.steps with
      | [] -> raise End_of_file
      | step :: rest -> (
          t.steps <- rest;
          match step with
          | Chunk s ->
              t.pending <- s;
              single_read t buf
          | Sleep d ->
              Eio.Time.Mono.sleep t.clock d;
              single_read t buf
          | Check f ->
              f ();
              single_read t buf
          | Block -> Eio.Fiber.await_cancel ()
          | Raise e -> raise e)
end

let source ~clock steps : Eio.Flow.source_ty Eio.Resource.t =
  let ops = Eio.Flow.Pi.source (module Scripted) in
  Eio.Resource.T
    ({ Scripted.steps; pending = ""; clock = (clock :> Eio.Time.Mono.ty Eio.Resource.t) }, ops)

type reply = {
  status : int;
  headers : (string * string) list;
  body : step list;
  delay : float;  (** before the response headers arrive *)
}

let reply ?(status = 200) ?(headers = [ ("content-type", "application/json") ]) ?(delay = 0.)
    body =
  { status; headers; body; delay }

let json_reply ?status body = reply ?status [ Chunk body ]

let sse_reply ?(status = 200) steps =
  reply ~status ~headers:[ ("content-type", "text/event-stream; charset=utf-8") ] steps

type recorder = {
  mutable requests : Transport.request list;  (** newest first *)
  mutable opened : int;
  mutable released : int;
}

(* [handler] answers each request; it may inspect the request (e.g. to echo
   its JSON-RPC id). Every request registers a release hook on [sw], like a
   real socket would. *)
let transport ~clock (handler : Transport.request -> reply) =
  let r = { requests = []; opened = 0; released = 0 } in
  let t : Transport.t =
   fun ~sw req ->
    r.requests <- req :: r.requests;
    r.opened <- r.opened + 1;
    Eio.Switch.on_release sw (fun () -> r.released <- r.released + 1);
    let rep = handler req in
    if rep.delay > 0. then Eio.Time.Mono.sleep clock rep.delay;
    { Transport.status = rep.status; headers = rep.headers; body = source ~clock rep.body }
  in
  (t, r)

(* JSON-RPC helpers. *)

let request_json (req : Transport.request) =
  Yojson.Safe.from_string (Option.get req.body)

let request_id req =
  match request_json req with
  | `Assoc kvs -> (match List.assoc "id" kvs with `String s -> s | _ -> assert false)
  | _ -> assert false

let result_envelope ~id result =
  Yojson.Safe.to_string
    (`Assoc [ ("jsonrpc", `String "2.0"); ("id", `String id); ("result", result) ])

let error_envelope ?(data = []) ~id code message =
  Yojson.Safe.to_string
    (`Assoc
       [ ("jsonrpc", `String "2.0"); ("id", id);
         ("error",
           `Assoc
             ([ ("code", `Int code); ("message", `String message) ]
             @ if data = [] then [] else [ ("data", `List data) ])) ])

let sse_data payload = "data: " ^ payload ^ "\n\n"
