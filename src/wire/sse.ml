type event = {
  event_type : string option;
  data : string;
  id : string option;
  retry : int option;
}

type t = {
  line : Buffer.t;
  data : Buffer.t;
  mutable has_data : bool;
  mutable event_type : string option;
  mutable retry : int option;
  mutable last_id : string option;
  mutable after_cr : bool;
  mutable at_start : bool;
  max_event_size : int;
}

let create ?(max_event_size = 16 * 1024 * 1024) () =
  { line = Buffer.create 256; data = Buffer.create 1024; has_data = false;
    event_type = None; retry = None; last_id = None; after_cr = false;
    at_start = true; max_event_size }

let last_event_id t = t.last_id

let reset_event t =
  Buffer.clear t.data;
  t.has_data <- false;
  t.event_type <- None;
  t.retry <- None

let all_digits s = s <> "" && String.for_all (fun c -> c >= '0' && c <= '9') s

let process_field t name value =
  match name with
  | "data" ->
      if t.has_data then Buffer.add_char t.data '\n';
      Buffer.add_string t.data value;
      t.has_data <- true
  | "event" -> t.event_type <- Some value
  | "id" -> if not (String.contains value '\000') then t.last_id <- Some value
  | "retry" -> if all_digits value then t.retry <- int_of_string_opt value
  | _ -> ()

let process_line t line =
  if line = "" then begin
    let ev =
      if t.has_data then
        Some { event_type = t.event_type; data = Buffer.contents t.data;
               id = t.last_id; retry = t.retry }
      else None
    in
    reset_event t;
    ev
  end
  else if line.[0] = ':' then None
  else begin
    (match String.index_opt line ':' with
     | None -> process_field t line ""
     | Some i ->
         let name = String.sub line 0 i in
         let start = if i + 1 < String.length line && line.[i + 1] = ' ' then i + 2 else i + 1 in
         process_field t name (String.sub line start (String.length line - start)));
    None
  end

let strip_bom t line =
  if t.at_start then begin
    t.at_start <- false;
    let bom = "\xEF\xBB\xBF" in
    if String.starts_with ~prefix:bom line then
      String.sub line 3 (String.length line - 3)
    else line
  end
  else line

let feed t chunk =
  let events = ref [] in
  let len = String.length chunk in
  let seg_start = ref 0 in
  let flush_line upto =
    Buffer.add_substring t.line chunk !seg_start (upto - !seg_start);
    let line = strip_bom t (Buffer.contents t.line) in
    Buffer.clear t.line;
    match process_line t line with Some ev -> events := ev :: !events | None -> ()
  in
  for i = 0 to len - 1 do
    match chunk.[i] with
    | '\n' when t.after_cr ->
        t.after_cr <- false;
        seg_start := i + 1
    | '\n' ->
        flush_line i;
        seg_start := i + 1
    | '\r' ->
        flush_line i;
        t.after_cr <- true;
        seg_start := i + 1
    | _ -> t.after_cr <- false
  done;
  Buffer.add_substring t.line chunk !seg_start (len - !seg_start);
  if Buffer.length t.line + Buffer.length t.data > t.max_event_size then
    Error (`Event_too_large t.max_event_size)
  else Ok (List.rev !events)
