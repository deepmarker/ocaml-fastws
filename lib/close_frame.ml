open Sexplib.Std

type t =
  { code : int option
  ; reason : string
  }
[@@deriving sexp]

type error =
  | Payload_length_one
  | Invalid_code of int
  | Invalid_utf8_reason
[@@deriving sexp]

let valid_code = function
  | 1000 | 1001 | 1002 | 1003 | 1007 | 1008 | 1009 | 1010 | 1011 | 1012 | 1013 | 1014 ->
    true
  | code when code >= 3000 && code <= 4999 -> true
  | _ -> false
;;

let valid_utf_8 value =
  Uutf.String.fold_utf_8
    (fun valid _ -> function
       | `Uchar _ -> valid
       | `Malformed _ -> false)
    true
    value
;;

let of_payload payload =
  match String.length payload with
  | 0 -> Ok { code = None; reason = "" }
  | 1 -> Error Payload_length_one
  | length ->
    let code = String.get_int16_be payload 0 in
    if not (valid_code code)
    then Error (Invalid_code code)
    else (
      let reason = String.sub payload 2 (length - 2) in
      if valid_utf_8 reason
      then Ok { code = Some code; reason }
      else Error Invalid_utf8_reason)
;;

let pp ppf { code; reason } =
  Format.fprintf
    ppf
    "{code=%s; reason=%S}"
    (Option.fold ~none:"none" ~some:string_of_int code)
    reason
;;

let pp_error ppf error = Format.fprintf ppf "%a" Sexplib.Sexp.pp (sexp_of_error error)
