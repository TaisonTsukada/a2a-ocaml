module D = Json_decode

let ( let* ) = Result.bind

let segment s = Uri.pct_encode ~component:`Path s

let query_value : Yojson.Safe.t -> string option = function
  | `String s -> Some s
  | `Int n -> Some (string_of_int n)
  | `Bool b -> Some (string_of_bool b)
  | _ -> None

type part = Literal of string | Var of string * string

let parse_template template =
  String.split_on_char '/' template
  |> List.map (fun part ->
         match (String.index_opt part '{', String.index_opt part '}') with
         | Some i, Some j when i < j ->
             Var (String.sub part (i + 1) (j - i - 1), String.sub part (j + 1) (String.length part - j - 1))
         | _ -> Literal part)

let fill parts fields =
  let value name = match List.assoc_opt name fields with Some (`String v) -> segment v | _ -> "" in
  String.concat "/" (List.map (function Literal s -> s | Var (n, suffix) -> value n ^ suffix) parts)

let variables parts = List.filter_map (function Var (n, _) -> Some n | Literal _ -> None) parts

let status : Error.rpc_error option D.t =
  D.obj @@ fun kvs ->
  D.field_default "error"
    (D.obj @@ fun err ->
     let* message = D.string_field_default "message" err in
     let* code = D.field_default "code" D.int ~default:0 err in
     let* details = D.list_field "details" D.json err in
     let e = { Error.code = Other code; message; details } in
     let reason = Option.bind (Error.error_info e) (fun i -> Error.Code.of_reason i.reason) in
     Ok (Some { e with code = Option.value reason ~default:e.code }))
    ~default:None kvs

let status_error json = match status json with Ok (Some e) -> Some (Error.Rpc_error e) | _ -> None

let blank = String.for_all (function ' ' | '\n' | '\r' | '\t' -> true | _ -> false)

let decode_body d body =
  let* json = if blank body then Ok `Null else Jsonrpc.parse_json body in
  match status_error json with
  | Some e -> Error e
  | None -> Result.map_error (fun e -> Error.Invalid_response (D.error_to_string e)) (d json)

let error_of_body body = Option.bind (Result.to_option (Jsonrpc.parse_json body)) status_error

let content_type = "application/a2a+json"
let accept = content_type ^ ", application/json"

let op ~meth ~path:template encode decode : _ Op.t =
  let with_tenant = parse_template ("/{tenant}" ^ template) and without = parse_template template in
  let used = variables with_tenant in
  let prepare req =
    let fields = match encode req with `Assoc kvs -> kvs | _ -> [] in
    let parts = if List.mem_assoc "tenant" fields then with_tenant else without in
    let query, body =
      match meth with
      | `POST -> ([], Some (Yojson.Safe.to_string (`Assoc fields)))
      | `GET | `DELETE ->
          ( List.filter_map
              (fun (k, v) ->
                if List.mem k used then None else Option.map (fun v -> (k, v)) (query_value v))
              fields,
            None )
    in
    { Op.meth; path = fill parts fields; query; body; content_type;
      accept; id = None; decode = decode_body decode;
      error_of_body = Some error_of_body }
  in
  let verb = match meth with `GET -> "GET" | `POST -> "POST" | `DELETE -> "DELETE" in
  { name = verb ^ " " ^ template; prepare }
