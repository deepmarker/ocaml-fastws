open Sexplib.Std

type t =
  { opcode : Opcode.t
  ; rsv : int
  ; final : bool
  ; length : int
  ; mask : (string option[@sexp.opaque])
  }
[@@deriving sexp_of]

let rsv1 = 1 lsl 2
let rsv2 = 1 lsl 1
let rsv3 = 1
let has_rsv1 t = t.rsv land rsv1 <> 0
let has_rsv2 t = t.rsv land rsv2 <> 0
let has_rsv3 t = t.rsv land rsv3 <> 0
let compare = Stdlib.compare
let equal = Stdlib.( = )
let pp ppf t = Format.fprintf ppf "%a" Sexplib.Sexp.pp (sexp_of_t t)
let show t = Format.asprintf "%a" pp t

let create ?(rsv = 0) ?(final = true) ?(length = 0) ?mask opcode =
  { opcode; rsv; final; length; mask }
;;

type parse_result =
  [ `Need of int
  | `Ok of t * int
  ]

let parse_aux buf pos len =
  let get_finmask c = Char.code c land 0x80 <> 0 in
  let get_rsv c = (Char.code c lsr 4) land 0x7 in
  let get_len c = Char.code c land 0x7f in
  let get_opcode c = Opcode.of_int (Char.code c land 0xf) in
  let b1 = Bigstringaf.get buf pos in
  let b2 = Bigstringaf.get buf (pos + 1) in
  let final = get_finmask b1 in
  let rsv = get_rsv b1 in
  let opcode = get_opcode b1 in
  let masked = get_finmask b2 in
  let frame_len = get_len b2 in
  match frame_len, masked with
  | 126, false ->
    if len < 4
    then `Need 4
    else (
      let length = Bigstringaf.get_int16_be buf (pos + 2) in
      `Ok (create ~final ~rsv ~length opcode, 4))
  | 126, true ->
    if len < 8
    then `Need 8
    else (
      let length = Bigstringaf.get_int16_be buf (pos + 2) in
      let mask = Bigstringaf.substring buf ~off:(pos + 4) ~len:4 in
      `Ok (create ~final ~rsv ~length ~mask opcode, 8))
  | 127, false ->
    if len < 10
    then `Need 10
    else (
      let length = Bigstringaf.get_int64_be buf (pos + 2) in
      let length = Int64.to_int length in
      `Ok (create ~final ~rsv ~length opcode, 10))
  | 127, true ->
    if len < 14
    then `Need 14
    else (
      let length = Bigstringaf.get_int64_be buf (pos + 2) in
      let length = Int64.to_int length in
      let mask = Bigstringaf.substring buf ~off:(pos + 10) ~len:4 in
      `Ok (create ~final ~rsv ~length ~mask opcode, 14))
  | length, true ->
    if len < 6
    then `Need 6
    else (
      let mask = Bigstringaf.substring buf ~off:(pos + 2) ~len:4 in
      `Ok (create ~final ~rsv ~mask ~length opcode, 6))
  | length, false -> `Ok (create ~final ~rsv ~length opcode, 2)
;;

let parse ?(pos = 0) ?len buf =
  let open Bigstringaf in
  let len =
    match len with
    | Some len -> len
    | None -> length buf - pos
  in
  if pos < 0 || len < 2 || pos + len > length buf
  then invalid_arg (Printf.sprintf "parse: pos = %d, len = %d" pos len);
  parse_aux buf pos len
;;

let serialize t { opcode; rsv; final; length; mask } =
  let open Faraday in
  let b1 = Opcode.to_int opcode lor (rsv lsl 4) in
  write_uint8 t (if final then 0x80 lor b1 else b1);
  let len = if length < 126 then length else if length < 1 lsl 16 then 126 else 127 in
  write_uint8
    t
    (match mask with
     | None -> len
     | Some _ -> 0x80 lor len);
  if len = 126
  then BE.write_uint16 t length
  else if len = 127
  then BE.write_uint64 t (Int64.of_int length);
  match mask with
  | None -> ()
  | Some mask -> write_string t mask
;;
