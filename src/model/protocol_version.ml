type t =
  | V1_0
  | V0_3

let to_string = function V1_0 -> "1.0" | V0_3 -> "0.3"

let of_string s =
  match String.split_on_char '.' (String.trim s) with
  | "1" :: _ -> Some V1_0
  | "0" :: "3" :: _ -> Some V0_3
  | _ -> None

let supported = [ V1_0; V0_3 ]

let pp ppf t = Format.pp_print_string ppf (to_string t)
