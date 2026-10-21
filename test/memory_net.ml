(* An in-memory Eio network, so the HTTP tests run cohttp-eio servers and
   clients end to end without OS sockets (sandboxes such as opam's on
   macOS do not allow binding one, even on the loopback interface).

   Every address resolves to a listener registered on the same network,
   identified by its TCP port. Connecting to a port nobody listens on is
   refused. *)

type pipe = {
  chunks : string option Eio.Stream.t;  (* [None] marks the end of the data *)
  mutable pending : string;
  mutable ended : bool;  (* the reader saw [None] *)
  mutable sent_eof : bool;
  mutable reader_gone : bool;
}

let pipe () =
  { chunks = Eio.Stream.create max_int; pending = ""; ended = false; sent_eof = false;
    reader_gone = false }

type Eio.Exn.Backend.t += Memory_net of string

let () =
  Eio.Exn.Backend.register_pp (fun f -> function
    | Memory_net msg -> Format.pp_print_string f msg; true
    | _ -> false)

let reset msg = Eio.Net.err (Connection_reset (Memory_net msg))

module Socket = struct
  type t = { rx : pipe; tx : pipe; mutable closed : bool }
  type tag = [ `Generic ]

  let read_methods = []

  let rec single_read t buf =
    if t.closed then raise (reset "socket closed")
    else if t.rx.pending <> "" then begin
      let n = min (Cstruct.length buf) (String.length t.rx.pending) in
      Cstruct.blit_from_string t.rx.pending 0 buf 0 n;
      t.rx.pending <- String.sub t.rx.pending n (String.length t.rx.pending - n);
      n
    end
    else if t.rx.ended then raise End_of_file
    else
      match Eio.Stream.take t.rx.chunks with
      | None ->
          t.rx.ended <- true;
          raise End_of_file
      | Some s ->
          t.rx.pending <- s;
          single_read t buf

  let single_write t bufs =
    if t.closed || t.tx.sent_eof || t.tx.reader_gone then raise (reset "broken pipe");
    let s = Cstruct.copyv bufs in
    if s <> "" then Eio.Stream.add t.tx.chunks (Some s);
    String.length s

  let copy t ~src = Eio.Flow.Pi.simple_copy ~single_write t ~src

  let shutdown t = function
    | `Send ->
        if not t.tx.sent_eof then begin
          t.tx.sent_eof <- true;
          Eio.Stream.add t.tx.chunks None
        end
    | `Receive -> t.rx.reader_gone <- true
    | `All ->
        if not t.tx.sent_eof then begin
          t.tx.sent_eof <- true;
          Eio.Stream.add t.tx.chunks None
        end;
        t.rx.reader_gone <- true

  let close t =
    if not t.closed then begin
      shutdown t `All;
      t.closed <- true
    end

  let setsockopt _ _ _ = ()
  let getsockopt _ _ = raise (Eio.Net.err Invalid_option)
end

let socket_handler = Eio.Net.Pi.stream_socket (module Socket)

let socket ~sw s : Socket.tag Eio.Net.stream_socket_ty Eio.Resource.t =
  Eio.Switch.on_release sw (fun () -> Socket.close s);
  Eio.Resource.T (s, socket_handler)

type network = {
  listeners : (int, listener) Hashtbl.t;
  mutable next_port : int;
}

and listener = {
  net : network;
  port : int;
  backlog : (Socket.t * Eio.Net.Sockaddr.stream) Eio.Stream.t;
  mutable open_ : bool;
}

let fresh_port net =
  let p = net.next_port in
  net.next_port <- p + 1;
  p

module Listening = struct
  type t = listener
  type tag = Socket.tag

  let accept t ~sw =
    let s, peer = Eio.Stream.take t.backlog in
    (socket ~sw s, peer)

  let close t =
    if t.open_ then begin
      t.open_ <- false;
      Hashtbl.remove t.net.listeners t.port
    end

  let listening_addr t = `Tcp (Eio.Net.Ipaddr.V4.loopback, t.port)
  let setsockopt _ _ _ = ()
  let getsockopt _ _ = raise (Eio.Net.err Invalid_option)
end

let listening_handler = Eio.Net.Pi.listening_socket (module Listening)

module Network = struct
  type t = network
  type tag = Socket.tag

  let listen net ~reuse_addr:_ ~reuse_port:_ ~backlog:_ ~sw (addr : Eio.Net.Sockaddr.stream) =
    let port =
      match addr with
      | `Tcp (_, 0) -> fresh_port net
      | `Tcp (_, p) when not (Hashtbl.mem net.listeners p) -> p
      | `Tcp (_, p) -> raise (Eio.Net.err (Connection_reset (Memory_net (Printf.sprintf "port %d in use" p))))
      | `Unix _ -> invalid_arg "Memory_net: Unix domain sockets are not supported"
    in
    let l = { net; port; backlog = Eio.Stream.create max_int; open_ = true } in
    Hashtbl.replace net.listeners port l;
    Eio.Switch.on_release sw (fun () -> Listening.close l);
    Eio.Resource.T (l, listening_handler)

  let connect net ~bind_to:_ ~options:_ ~sw (addr : Eio.Net.Sockaddr.stream) =
    let refused () = raise (Eio.Net.err (Connection_failure (Refused (Memory_net "connection refused")))) in
    match addr with
    | `Unix _ -> refused ()
    | `Tcp (_, port) -> (
        match Hashtbl.find_opt net.listeners port with
        | None -> refused ()
        | Some l ->
            let up = pipe () and down = pipe () in
            let peer = `Tcp (Eio.Net.Ipaddr.V4.loopback, fresh_port net) in
            Eio.Stream.add l.backlog ({ Socket.rx = up; tx = down; closed = false }, peer);
            socket ~sw { Socket.rx = down; tx = up; closed = false })

  let datagram_socket _ ~reuse_addr:_ ~reuse_port:_ ~sw:_ _ =
    invalid_arg "Memory_net: datagram sockets are not supported"

  let getaddrinfo _ ~service _host =
    let port = match service with "http" -> 80 | "https" -> 443 | s -> int_of_string s in
    [ `Tcp (Eio.Net.Ipaddr.V4.loopback, port) ]

  let getnameinfo _ _ = ("localhost", "")
end

let network_handler = Eio.Net.Pi.network (module Network)

let create () : Socket.tag Eio.Net.ty Eio.Resource.t =
  Eio.Resource.T ({ listeners = Hashtbl.create 8; next_port = 40000 }, network_handler)
