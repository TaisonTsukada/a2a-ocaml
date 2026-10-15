open A2a_client


let ev_t = Alcotest.(list (pair (pair (option string) string) (pair (option string) (option int))))
let flat (e : Sse.event) = ((e.event_type, e.data), (e.id, e.retry))

let feed_all ?max_event_size chunks =
  let p = Sse.create ?max_event_size () in
  List.concat_map
    (fun c ->
      match Sse.feed p c with
      | Ok evs -> List.map flat evs
      | Error (`Event_too_large _) -> Alcotest.fail "too large")
    chunks

let one ?typ ?id ?retry data = ((typ, data), (id, retry))

let test_basic () =
  Alcotest.check ev_t "two events"
    [ one "a"; one "b" ]
    (feed_all [ "data: a\n\ndata: b\n\n" ])

let test_multiline_data () =
  Alcotest.check ev_t "joined with LF"
    [ one "line1\nline2\n\nline4" ]
    (feed_all [ "data: line1\ndata: line2\ndata\ndata: line4\n\n" ])

let test_fields_and_comments () =
  Alcotest.check ev_t "event/id/retry/comment"
    [ one ~typ:"update" ~id:"42" ~retry:3000 "x"; one ~id:"42" "y" ]
    (feed_all
       [ ": keep-alive comment\n";
         "event: update\nid: 42\nretry: 3000\nunknown: z\ndata: x\n\n";
         (* id persists, type and retry reset *)
         "retry: soon\ndata: y\n\n" ])

let test_value_spacing () =
  (* only one leading space is removed; no colon = empty value *)
  Alcotest.check ev_t "spacing"
    [ one "x"; one " x"; one "" ]
    (feed_all [ "data:x\n\n"; "data:  x\n\n"; "data\n\n" ])

let test_line_endings () =
  Alcotest.check ev_t "CRLF, CR and LF"
    [ one "a"; one "b"; one "c" ]
    (feed_all [ "data: a\r\n\r\ndata: b\r\rdata: c\n\n" ])

let test_no_dispatch_without_data () =
  Alcotest.check ev_t "empty events skipped"
    [ one ~typ:"e" "d" ]
    (feed_all [ "\n\nevent: x\n\n: c\n\nevent: e\ndata: d\n\n" ])

let test_incomplete_event_at_eof () =
  Alcotest.check ev_t "unterminated event not dispatched" [ one "a" ]
    (feed_all [ "data: a\n\ndata: b\n" ])

let test_bom () =
  Alcotest.check ev_t "BOM stripped" [ one "a" ] (feed_all [ "\xEF\xBB\xBFdata: a\n\n" ]);
  Alcotest.check ev_t "split BOM" [ one "a" ] (feed_all [ "\xEF"; "\xBB\xBFdata: a\n\n" ])

(* The same stream split at every possible position, and byte by byte,
   yields the same events: TCP chunking is irrelevant. *)
let test_arbitrary_chunking () =
  let stream =
    ": hello\r\nevent: status\r\nid: 7\r\ndata: {\"a\":\r\ndata: 1}\r\n\r\ndata: second\n\ndata: third\r\rdata: é漢字\n\n"
  in
  let expected = feed_all [ stream ] in
  Alcotest.(check int) "four events" 4 (List.length expected);
  for i = 0 to String.length stream do
    let a = String.sub stream 0 i and b = String.sub stream i (String.length stream - i) in
    Alcotest.check ev_t (Printf.sprintf "split at %d" i) expected (feed_all [ a; b ])
  done;
  let bytes = List.init (String.length stream) (fun i -> String.make 1 stream.[i]) in
  Alcotest.check ev_t "byte by byte" expected (feed_all bytes)

let test_crlf_split_across_chunks () =
  (* CR at the end of a chunk, LF at the start of the next: one line end. *)
  Alcotest.check ev_t "CR|LF" [ one "a"; one "b" ]
    (feed_all [ "data: a\r"; "\n\r"; "\ndata: b\r\n\r\n" ])

let test_event_too_large () =
  let p = Sse.create ~max_event_size:16 () in
  (match Sse.feed p "data: 0123456789\n" with Ok [] -> () | _ -> Alcotest.fail "first chunk ok");
  match Sse.feed p "data: 0123456789\n" with
  | Error (`Event_too_large 16) -> ()
  | _ -> Alcotest.fail "expected Event_too_large"

let test_line_without_newline_bounded () =
  let p = Sse.create ~max_event_size:8 () in
  match Sse.feed p (String.make 100 'x') with
  | Error (`Event_too_large _) -> ()
  | _ -> Alcotest.fail "an endless line must be bounded"

let tests =
  [ ("basic", `Quick, test_basic);
    ("multi-line data", `Quick, test_multiline_data);
    ("fields and comments", `Quick, test_fields_and_comments);
    ("value spacing", `Quick, test_value_spacing);
    ("line endings", `Quick, test_line_endings);
    ("no dispatch without data", `Quick, test_no_dispatch_without_data);
    ("incomplete event at EOF", `Quick, test_incomplete_event_at_eof);
    ("BOM", `Quick, test_bom);
    ("arbitrary chunking", `Quick, test_arbitrary_chunking);
    ("CRLF split across chunks", `Quick, test_crlf_split_across_chunks);
    ("event too large", `Quick, test_event_too_large);
    ("unterminated line bounded", `Quick, test_line_without_newline_bounded) ]

