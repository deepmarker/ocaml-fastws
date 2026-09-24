type t

val of_params : [ `Client | `Server ] -> (string * _) list -> t
val close : t -> unit
val decompress_exn : t -> string -> string
val compress_exn : t -> string -> string
