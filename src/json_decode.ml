(* Exception-free JSON decoding combinators over [Yojson.Safe.t].

   Errors carry the path to the offending value (e.g.
   "$.result.task.status.state") so malformed agent responses can be
   diagnosed without crashing. Decoding follows ProtoJSON conventions:
   unknown fields are ignored, absent scalars take their default value, and
   [null] is treated as absent. *)

type error = { path : string list; (* innermost first *) message : string }
type 'a t = Yojson.Safe.t -> ('a, error) result

let error_to_string { path; message } =
  let path =
    List.rev path
    |> List.map (fun seg ->
           if String.length seg > 0 && seg.[0] = '[' then seg else "." ^ seg)
    |> String.concat ""
  in
  Printf.sprintf "at $%s: %s" path message

let fail message = Error { path = []; message }
let ( let* ) = Result.bind

let in_path seg = function
  | Ok _ as ok -> ok
  | Error e -> Error { e with path = e.path @ [ seg ] }

let type_name : Yojson.Safe.t -> string = function
  | `Null -> "null"
  | `Bool _ -> "boolean"
  | `Int _ | `Intlit _ | `Float _ -> "number"
  | `String _ -> "string"
  | `Assoc _ -> "object"
  | `List _ -> "array"

let expected what json =
  fail (Printf.sprintf "expected %s, got %s" what (type_name json))

let json : Yojson.Safe.t t = fun j -> Ok j
let string : string t = function `String s -> Ok s | j -> expected "string" j
let bool : bool t = function `Bool b -> Ok b | j -> expected "boolean" j

(* ProtoJSON int32 may be encoded as a number or a decimal string. *)
let int : int t = function
  | `Int i -> Ok i
  | `Float f when Float.is_integer f && Float.abs f < 2147483648. ->
      Ok (int_of_float f)
  | `String s as j -> (
      match int_of_string_opt s with Some i -> Ok i | None -> expected "integer" j)
  | j -> expected "integer" j

let assoc : (string * Yojson.Safe.t) list t = function
  | `Assoc kvs -> Ok kvs
  | j -> expected "object" j

let list (d : 'a t) : 'a list t = function
  | `List items ->
      let rec go i acc = function
        | [] -> Ok (List.rev acc)
        | x :: rest ->
            let* v = d x |> in_path (Printf.sprintf "[%d]" i) in
            go (i + 1) (v :: acc) rest
      in
      go 0 [] items
  | j -> expected "array" j

(* Object whose values all decode with [d] (proto map<string, _>). *)
let string_map (d : 'a t) : (string * 'a) list t =
 fun j ->
  let* kvs = assoc j in
  let rec go acc = function
    | [] -> Ok (List.rev acc)
    | (k, v) :: rest ->
        let* v = d v |> in_path k in
        go ((k, v) :: acc) rest
  in
  go [] kvs

let lookup name kvs =
  match List.assoc_opt name kvs with None | Some `Null -> None | Some j -> Some j

(* Field accessors take the already-destructured object. *)
let field name (d : 'a t) kvs =
  match lookup name kvs with
  | None -> Error { path = [ name ]; message = "missing required field" }
  | Some j -> d j |> in_path name

let field_opt name (d : 'a t) kvs =
  match lookup name kvs with
  | None -> Ok None
  | Some j -> d j |> in_path name |> Result.map Option.some

let field_default name (d : 'a t) ~default kvs =
  match lookup name kvs with None -> Ok default | Some j -> d j |> in_path name

let list_field name d kvs = field_default name (list d) ~default:[] kvs
let bool_field name kvs = field_default name bool ~default:false kvs

(* proto3 strings without presence: "" means unset. *)
let string_opt_field name kvs =
  let* s = field_opt name string kvs in
  Ok (match s with Some "" -> None | s -> s)

let string_field_default name kvs = field_default name string ~default:"" kvs

let obj (f : (string * Yojson.Safe.t) list -> ('a, error) result) : 'a t =
 fun j ->
  let* kvs = assoc j in
  f kvs

let of_string (d : 'a t) s =
  match Yojson.Safe.from_string s with
  | exception Yojson.Json_error msg -> Error ("invalid JSON: " ^ msg)
  | j -> Result.map_error error_to_string (d j)

(* Prefix an error's path with an outer segment. *)
let under seg e = { e with path = e.path @ [ seg ] }
