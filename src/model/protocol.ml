type t = V1_0 of Protocol_binding.t | V0_3

let default = V1_0 Jsonrpc

let make (version : Protocol_version.t) (binding : Protocol_binding.t) =
  match (version, binding) with
  | V1_0, b -> Some (V1_0 b)
  | V0_3, Jsonrpc -> Some V0_3
  | V0_3, Http_json -> None

let version = function V1_0 _ -> Protocol_version.V1_0 | V0_3 -> V0_3
let binding = function V1_0 b -> b | V0_3 -> Protocol_binding.Jsonrpc

let pp ppf t =
  Format.fprintf ppf "%a over %a" Protocol_version.pp (version t) Protocol_binding.pp (binding t)
