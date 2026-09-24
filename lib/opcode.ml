open Sexplib.Std

type t =
  | Continuation
  | Text
  | Binary
  | Close
  | Ping
  | Pong
  | Ctrl of int
  | Nonctrl of int
[@@deriving sexp]

let compare = Stdlib.compare
let equal = Stdlib.( = )
let pp ppf t = Format.fprintf ppf "%a" Sexplib.Sexp.pp (sexp_of_t t)

let of_int = function
  | i when i < 0 || i > 0xf -> invalid_arg "Opcode.of_int"
  | 0 -> Continuation
  | 1 -> Text
  | 2 -> Binary
  | 8 -> Close
  | 9 -> Ping
  | 10 -> Pong
  | i when i < 8 -> Nonctrl i
  | i -> Ctrl i
;;

let to_int = function
  | Continuation -> 0
  | Text -> 1
  | Binary -> 2
  | Close -> 8
  | Ping -> 9
  | Pong -> 10
  | Ctrl i -> i
  | Nonctrl i -> i
;;

let is_control = function
  | Close | Ping | Pong | Ctrl _ -> true
  | _ -> false
;;

let is_std = function
  | Ctrl _ | Nonctrl _ -> false
  | _ -> true
;;

let is_continuation = function
  | Continuation -> true
  | _ -> false
;;
