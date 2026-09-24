#include <zlib.h>

#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/mlvalues.h>

/* camlzip 1.14 stores a [z_stream *] directly in its custom block.  Keep
   these two missing reset operations beside the sole caller rather than
   maintaining a second streaming-deflate binding. */
#define ZStream_val(v) (*((z_streamp *)Data_custom_val(v)))

CAMLprim value fastws_inflate_reset(value stream) {
  if (inflateReset(ZStream_val(stream)) != Z_OK)
    caml_failwith("zlib inflateReset failed");
  return Val_unit;
}

CAMLprim value fastws_deflate_reset(value stream) {
  if (deflateReset(ZStream_val(stream)) != Z_OK)
    caml_failwith("zlib deflateReset failed");
  return Val_unit;
}
