type t = Jsonrpc | Http_json

let to_string = function Jsonrpc -> "JSONRPC" | Http_json -> "HTTP+JSON"

let of_string s =
  match String.uppercase_ascii (String.trim s) with
  | "JSONRPC" -> Some Jsonrpc
  | "HTTP+JSON" -> Some Http_json
  | _ -> None

let pp ppf t = Format.pp_print_string ppf (to_string t)
