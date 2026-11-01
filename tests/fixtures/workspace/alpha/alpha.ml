(* alpha keeps its greeting base64-encoded and decodes it with the pinned
   base64 library. *)
let encoded = Base64.encode_string "Hello from alpha"

let get () = Base64.decode_exn encoded
