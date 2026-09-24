open Sexplib.Std

type t =
  | NormalClosure
  | GoingAway
  | ProtocolError
  | UnsupportedDataType
  | InconsistentData
  | ViolatesPolicy
  | MessageTooBig
  | UnsupportedExtension
  | UnexpectedCondition
  | ServiceRestart
  | TryAgainLater
  | BadGateway
  | TLSHandshake
  | Unknown of int
[@@deriving sexp_of]

let of_int = function
  | 1000 -> NormalClosure
  | 1001 -> GoingAway
  | 1002 -> ProtocolError
  | 1003 -> UnsupportedDataType
  | 1007 -> InconsistentData
  | 1008 -> ViolatesPolicy
  | 1009 -> MessageTooBig
  | 1010 -> UnsupportedExtension
  | 1011 -> UnexpectedCondition
  | 1012 -> ServiceRestart
  | 1013 -> TryAgainLater
  | 1014 -> BadGateway
  | 1015 -> TLSHandshake
  | status -> Unknown status
;;

let to_int = function
  | NormalClosure -> 1000
  | GoingAway -> 1001
  | ProtocolError -> 1002
  | UnsupportedDataType -> 1003
  | InconsistentData -> 1007
  | ViolatesPolicy -> 1008
  | MessageTooBig -> 1009
  | UnsupportedExtension -> 1010
  | UnexpectedCondition -> 1011
  | ServiceRestart -> 1012
  | TryAgainLater -> 1013
  | BadGateway -> 1014
  | TLSHandshake -> 1015
  | Unknown status -> status
[@@deriving sexp_of]
;;

let is_unknown = function
  | Unknown _ -> true
  | _ -> false
;;

let pp ppf t = Format.fprintf ppf "%d: %a" (to_int t) Sexplib.Sexp.pp (sexp_of_t t)

let to_string t =
  let buf = Bytes.create 2 in
  Bytes.set_int16_be buf 0 (to_int t);
  Bytes.unsafe_to_string buf
;;

let of_payload buf =
  match String.length buf with
  | 0 | 1 -> None
  | _ -> Some (of_int (String.get_int16_be buf 0))
;;
