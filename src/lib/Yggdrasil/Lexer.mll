{
open Lexing
open Token

module type SOURCE = sig
  val on_refill : lexbuf -> unit Lwt.t
end

module type LEXER = sig
  val token : lexbuf -> token Lwt.t
end

module Make (R : SOURCE) : LEXER = struct
  let refill_handler k lexbuf =
    R.on_refill lexbuf >> k lexbuf

  let make_table num elems =
    let table = Hashtbl.create num in
    List.iter (fun (k, v) -> Hashtbl.add table k v) elems;
    table

  let keywords =
    make_table 1 [
      ("@@analyze", KEYWORD_ANALYZE);
      ("->", KEYWORD_ARITY);
      ("cell", KEYWORD_CELL);
      ("computad", KEYWORD_COMPUTAD);
      ("lam", KEYWORD_LAMBDA);
      ("sign", KEYWORD_SIGN);
      ("type", KEYWORD_TYPE);
    ]
}

let line_ending
  = '\r'
  | '\n'
  | "\r\n"
let number =
  ['0'-'9']+
let whitespace =
  [' ' '\t']+
let identifier_initial =
  [^ '0'-'9' '(' ')' '[' ']' '{' '}' '.' '#' '\\' '"' ' ' '\t' '\n' '\r']
let identifier_subsequent =
  [^ '(' ')' '[' ']' '{' '}' '.' '#' '\\' '"' ' ' '\t' '\n' '\r']

refill {refill_handler}

rule token = parse
  | identifier_initial identifier_subsequent*
{
  let input = lexeme lexbuf in
  try
    let kwd = Hashtbl.find keywords input in
    Lwt.return kwd
  with Not_found ->
    Lwt.return (IDENTIFIER input)
}
  | '('
{ Lwt.return LEFT_PARENTHESIS }
  | '['
{ Lwt.return LEFT_SQUARE_BRACKET }
  | ')'
{ Lwt.return RIGHT_PARENTHESIS }
  | ']'
{ Lwt.return RIGHT_SQUARE_BRACKET }
  | line_ending
{ new_line lexbuf; token lexbuf }
  | whitespace
{ token lexbuf }
  | eof
{ Lwt.return EOF }
  | _
{ Lwt_io.printlf "Unexpected char: %s" (lexeme lexbuf) >> token lexbuf }

{
end (* LEXER *)

module type STATE = sig
  val ix : Lwt_io.input_channel
  val sz : int
end

module LwtSource (S : STATE): SOURCE = struct
  let resize b n =
    if (b.lex_buffer_len + n) > (Bytes.length b.lex_buffer) then begin
      let tmp_buf = ref b.lex_buffer in
      if (b.lex_buffer_len - b.lex_start_pos + n) > Bytes.length b.lex_buffer then begin
        let new_len = min (2 * Bytes.length b.lex_buffer) Sys.max_string_length in
        if b.lex_buffer_len - b.lex_start_pos + n > new_len then
          failwith "cannot resize buffer"
        else
          tmp_buf := Bytes.create new_len
      end;
      Bytes.blit b.lex_buffer b.lex_start_pos !tmp_buf 0 (b.lex_buffer_len - b.lex_start_pos);
      b.lex_buffer <- !tmp_buf;
      for i = 0 to Array.length b.lex_mem - 1 do
        if b.lex_mem.(i) >= 0 then
          b.lex_mem.(i) <- b.lex_mem.(i) - b.lex_start_pos
      done;
      b.lex_abs_pos    <- b.lex_abs_pos    + b.lex_start_pos;
      b.lex_curr_pos   <- b.lex_curr_pos   - b.lex_start_pos;
      b.lex_last_pos   <- b.lex_last_pos   - b.lex_start_pos;
      b.lex_buffer_len <- b.lex_buffer_len - b.lex_start_pos;
      b.lex_start_pos  <- 0;
    end

  let on_refill b =
    let aux_buffer = Bytes.create S.sz in
    let%lwt n = Lwt_io.read_into S.ix aux_buffer 0 S.sz in
    if n = 0 then
      Lwt.return (b.lex_eof_reached <- true)
    else begin
      resize b n;
      Bytes.blit aux_buffer 0 b.lex_buffer b.lex_buffer_len n;
      Lwt.return (b.lex_buffer_len <- b.lex_buffer_len + n)
    end
end

let create ix sz =
  let pkg : (module LEXER) = (module Make(LwtSource(struct
    let ix = ix
    let sz = sz
  end))) in
  let zero_pos = {
    pos_fname = "";
    pos_lnum  = 1;
    pos_bol   = 0;
    pos_cnum  = 0;
  } in
  let buf = {
    refill_buff     = begin fun _ -> () end;
    lex_buffer      = Bytes.create sz;
    lex_buffer_len  = 0;
    lex_abs_pos     = 0;
    lex_start_pos   = 0;
    lex_curr_pos    = 0;
    lex_last_pos    = 0;
    lex_last_action = 0;
    lex_mem         = [| |];
    lex_eof_reached = false;
    lex_start_p     = zero_pos;
    lex_curr_p      = zero_pos;
  } in (pkg, buf)

let tokens ix =
  let len = 1024 in
  let pkg, buf = create ix len in
  let module Lwt_lex = (val pkg : LEXER) in
  let go () = match%lwt Lwt_lex.token buf with
    | tok -> Lwt.return (Some tok)
  in Lwt_stream.from go
}
