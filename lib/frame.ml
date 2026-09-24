type t =
  { header : Header.t
  ; payload : string
  }

let create ?rsv ?final ?mask ?(payload = "") opcode =
  let length = String.length payload in
  let header = Header.create ?rsv ?final ?mask ~length opcode in
  { header; payload }
;;

let compare = Stdlib.compare
let equal = Stdlib.( = )

let pp ppf = function
  | { header; _ } when Header.has_rsv1 header ->
    (* Compressed data, do not display! *)
    Format.fprintf ppf "%a <compressed data>" Sexplib.Sexp.pp (Header.sexp_of_t header)
  | { header = { opcode = Text; _ } as header; payload } ->
    let len = String.length payload in
    if Option.is_some (Sys.getenv_opt "FASTWS_PP_FULL") || len < 1024
    then Format.fprintf ppf "%a <%s>" Sexplib.Sexp.pp (Header.sexp_of_t header) payload
    else
      Format.fprintf
        ppf
        "%a <%s...>"
        Sexplib.Sexp.pp
        (Header.sexp_of_t header)
        String.(sub payload 0 (min 4096 (length payload)))
  | { header; _ } ->
    Format.fprintf ppf "%a <binary data>" Sexplib.Sexp.pp (Header.sexp_of_t header)
;;

let is_binary = function
  | { header = { opcode = Binary; _ }; _ } -> true
  | _ -> false
;;

let is_text = function
  | { header = { opcode = Text; _ }; _ } -> true
  | _ -> false
;;

let is_close = function
  | { header = { opcode = Close; _ }; _ } -> true
  | _ -> false
;;

let with_compressed_payload t payload =
  let length = String.length payload in
  let rsv = Header.rsv1 lor t.header.rsv in
  let header = { t.header with length; rsv } in
  { header; payload }
;;

module String = struct
  let kcreate opcode payload =
    match payload with
    | None -> create opcode
    | Some payload -> create ~payload opcode
  ;;

  let empty_text = kcreate Text None
  let empty_binary = kcreate Binary None
  let text msg = kcreate Text (Some msg)
  let binary msg = kcreate Binary (Some msg)
  let ping msg = kcreate Ping (Some msg)
  let pong msg = kcreate Pong (Some msg)
  let createf opcode fmt = Format.kasprintf (fun payload -> create ~payload opcode) fmt
  let pingf fmt = createf Ping fmt
  let pongf fmt = createf Pong fmt
  let textf fmt = createf Text fmt
  let binaryf fmt = createf Binary fmt

  let kclose status msg =
    let msglen = String.length msg in
    let payload = Bytes.create (2 + msglen) in
    Bytes.set_int16_be payload 0 (Status.to_int status);
    Bytes.blit_string msg 0 payload 2 msglen;
    let payload = Bytes.unsafe_to_string payload in
    { header = Header.create ~length:(2 + msglen) Close; payload }
  ;;

  let close ?status () =
    match status with
    | None -> create Close
    | Some (st, None) ->
      let payload = Status.to_string st in
      create ~payload Close
    | Some (st, Some payload) ->
      let payload = Status.to_string st ^ payload in
      create ~payload Close
  ;;

  let closef ?(status = Status.NormalClosure) fmt = Format.kasprintf (kclose status) fmt
end
