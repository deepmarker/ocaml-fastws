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

(** Decode the application data of a Close control frame according to RFC 6455
    sections 5.5.1, 7.4, and 8.1. *)
val of_payload : string -> (t, error) result

val pp : Format.formatter -> t -> unit
val pp_error : Format.formatter -> error -> unit
