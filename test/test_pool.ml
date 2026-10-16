open A2a_client

let ok = Test_http.ok

let handler ~clock ~peers ~port (((_, peer), req, body) as conn) =
  if not (List.mem peer !peers) then peers := peer :: !peers;
  let reply ?headers () =
    let j = Yojson.Safe.from_string (Eio.Buf_read.(parse_exn take_all) body ~max_size:1_000_000) in
    let id = Yojson.Safe.Util.(to_string (member "id" j)) in
    Test_http.respond_json ?headers
      (Mock.result_envelope ~id (`Assoc [ ("task", Test_http.task_json "t-1" "COMPLETED") ]))
  in
  match Http.Request.resource req with
  | "/close" -> reply ~headers:[ ("connection", "close") ] ()
  | "/slow" ->
      Eio.Time.Mono.sleep clock 0.05;
      reply ()
  | _ -> Test_http.handler ~clock ~port conn

let with_pool f =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.mono_clock env and net = Eio.Stdenv.net env in
  Eio.Switch.run @@ fun sw ->
  let peers = ref [] in
  let port = Test_http.serve ~sw net (handler ~clock ~peers) in
  let transport = Transport.pooled ~sw ~clock net in
  let client path = create ~clock ~transport (Uri.of_string (Printf.sprintf "http://127.0.0.1:%d%s" port path)) in
  f ~clock ~client ~connections:(fun () -> List.length !peers)

let send client = ignore (ok "send" (send_text client "hi"))

let test_reuse () =
  with_pool @@ fun ~clock ~client ~connections ->
  let c = client "/rpc" in
  send c;
  send c;
  send c;
  Alcotest.(check int) "sequential requests share a connection" 1 (connections ());
  (match send_streaming_message c (Message.user_text "go") with
   | Ok (Outcome.Completed _) -> ()
   | _ -> Alcotest.fail "expected Completed");
  Eio.Time.Mono.sleep clock 0.05;
  send c;
  Alcotest.(check int) "a finished stream is drained and reused" 1 (connections ());
  let slow = client "/slow" in
  Eio.Fiber.both (fun () -> send slow) (fun () -> send slow);
  Alcotest.(check int) "concurrent requests get their own" 2 (connections ());
  send c;
  send c;
  Alcotest.(check int) "both went back to the pool" 2 (connections ())

let test_not_reused () =
  with_pool @@ fun ~clock ~client ~connections ->
  let c = client "/rpc" in
  let got = ref false in
  Eio.Fiber.first
    (fun () -> ignore (subscribe_to_task c ~on_event:(fun _ -> got := true) "t-1"))
    (fun () ->
      let rec wait () = if not !got then (Eio.Time.Mono.sleep clock 0.01; wait ()) in
      wait ());
  send c;
  Alcotest.(check int) "a cancelled stream's connection is closed" 2 (connections ());
  let closing = client "/close" in
  send closing;
  send closing;
  send closing;
  Alcotest.(check int) "Connection: close is honoured" 4 (connections ())

let read_request flow =
  let r = Eio.Buf_read.of_flow ~max_size:1_000_000 flow in
  let rec headers len =
    match Eio.Buf_read.line r with
    | "" -> len
    | l -> (
        match String.split_on_char ':' l with
        | k :: v :: _ when String.lowercase_ascii k = "content-length" -> headers (int_of_string (String.trim v))
        | _ -> headers len)
  in
  let len = headers 0 in
  Yojson.Safe.from_string (Eio.Buf_read.take len r)

let test_stale_connection () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.mono_clock env and net = Eio.Stdenv.net env in
  Eio.Switch.run @@ fun sw ->
  let socket, port = Test_http.listen ~sw net in
  let accepted = ref 0 in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      let rec loop () =
        Eio.Switch.run (fun sw ->
            let flow, _ = Eio.Net.accept ~sw socket in
            incr accepted;
            let id = Yojson.Safe.Util.(to_string (member "id" (read_request flow))) in
            let body = Mock.result_envelope ~id (`Assoc [ ("task", Test_http.task_json "t-1" "COMPLETED") ]) in
            Eio.Flow.copy_string
              (Printf.sprintf "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: %d\r\n\r\n%s"
                 (String.length body) body)
              flow);
        loop ()
      in
      loop ());
  let transport = Transport.pooled ~sw ~clock net in
  let c = create ~clock ~transport (Uri.of_string (Printf.sprintf "http://127.0.0.1:%d/rpc" port)) in
  send c;
  send c;
  Alcotest.(check int) "retried on a new connection" 2 !accepted

let tests =
  [ ("keep-alive reuse", `Quick, test_reuse);
    ("connections that are not reused", `Quick, test_not_reused);
    ("stale pooled connection", `Quick, test_stale_connection) ]
