(*
 * Copyright (c) 2012 Anil Madhavapeddy <anil@recoil.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *
 *)

open Sexplib.Std

type t = { 
  mutable headers: Header.t;
  mutable meth: Code.meth;
  mutable uri: Uri.t;
  mutable version: Code.version;
  mutable encoding: Transfer.encoding;
} with fields, sexp

let make ?(meth=`GET) ?(version=`HTTP_1_1) ?encoding ?headers uri =
  let headers = 
    match headers with
    | None -> Header.init ()
    | Some h -> h in
  let encoding =
    match encoding with
    | None -> begin
       (* Check for a content-length in the supplied headers first *)
       match Header.get_content_range headers with
       | Some clen -> Transfer.Fixed clen
       | None -> Transfer.Fixed 0 
     end
    | Some e -> e
  in
  { meth; version; headers; uri; encoding }

let is_keep_alive { version; headers; _ } =
  not (version = `HTTP_1_0 ||
       (match Header.connection headers with
       | Some `Close -> true
       | _ -> false))

(* Make a client request, which involves guessing encoding and
   adding content headers if appropriate.
   @param chunked Forces chunked encoding
 *)
let make_for_client ?headers ?(chunked=true) ?(body_length=0) meth uri =
  let encoding =
    match chunked with
    | true -> Transfer.Chunked
    | false -> Transfer.Fixed body_length
  in
  make ~meth ~encoding ?headers uri

type tt = t
module Make(IO : S.IO) = struct
  type t = tt
  module IO = IO
  module Header_IO = Header_io.Make(IO)
  module Transfer_IO = Transfer_io.Make(IO)
  
  open IO

  let url_decode url = Uri.pct_decode url

  let parse_request_fst_line ic =
    let open Code in
    read_line ic >>= function
    | Some request_line -> begin
      match Stringext.split request_line ~on:' ' with
      | [ meth_raw; path; http_ver_raw ] -> begin
          let m = method_of_string meth_raw in
          match version_of_string http_ver_raw with
          | `HTTP_1_1 | `HTTP_1_0 as v -> return (`Ok (m, path, v))
          | `Other _ -> return (`Invalid ("Malformed request HTTP version: " ^ http_ver_raw))
      end
      | _ -> return (`Invalid ("Malformed request header: " ^ request_line))
    end
    | None -> return `Eof

  let read ic =
    parse_request_fst_line ic >>= function
    | `Eof -> return `Eof
    | `Invalid reason as r -> return r
    | `Ok (meth, path, version) ->
      Header_IO.parse ic >>= fun headers ->
      let uri = match (Header.get headers "host") with
        | None -> Uri.of_string path
        | Some h ->
          (* XXX: Could be https:// as well... *)
          Uri.of_string ("http://" ^ h ^ path) in
      let encoding = Header.get_transfer_encoding headers in
      return (`Ok { headers; meth; uri; version; encoding })

  let has_body req = Transfer.has_body req.encoding
  let read_body_chunk req = Transfer_IO.read req.encoding

  let write_header req oc =
   let fst_line = Printf.sprintf "%s %s %s\r\n" (Code.string_of_method req.meth)
      (Uri.path_and_query req.uri) (Code.string_of_version req.version) in
    let headers = Header.add req.headers "host"
        (Uri.host_with_default ~default:"localhost" req.uri ^
           match Uri.port req.uri with
           | Some p -> ":" ^ string_of_int p
           | None -> ""
        ) in
    let headers = Header.add_transfer_encoding headers req.encoding in
    IO.write oc fst_line >>= fun _ ->
    iter (IO.write oc) (Header.to_lines headers) >>= fun _ ->
    IO.write oc "\r\n"

  let write_body req oc buf =
    Transfer_IO.write req.encoding oc buf

  let write_footer req oc =
    match req.encoding with
    |Transfer.Chunked ->
       (* TODO Trailer header support *)
       IO.write oc "0\r\n\r\n"
    |Transfer.Fixed _ | Transfer.Unknown -> return ()

  (* TODO: remove either write' or write *)
  let write write_body req oc =
    write_header req oc >>= fun () ->
    write_body req oc >>= fun () ->
    write_footer req oc

  let is_form req = Header.is_form req.headers
  let read_form req ic = Header_IO.parse_form req.headers ic
end


