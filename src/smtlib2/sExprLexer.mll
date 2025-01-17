(**************************************************************************)
(*                                                                        *)
(*     SMTCoq                                                             *)
(*     Copyright (C) 2011 - 2021                                          *)
(*                                                                        *)
(*     See file "AUTHORS" for the list of authors                         *)
(*                                                                        *)
(*   This file is distributed under the terms of the CeCILL-C licence     *)
(*                                                                        *)
(**************************************************************************)


(* Lexer for S-expressions
   
   Adapted from the OCaml sexplib, which is part of the ocaml-core
   alternative standard library for OCaml.

*)

{
  (** Lexer: Lexer Specification for S-expressions *)

  open Printf
  open Lexing
  open SExprParser

}

let lf = '\010'
let lf_cr = ['\010' '\013']
let dos_newline = "\013\010"
let blank = [' ' '\009' '\012']
let unquoted = [^ ';' '(' ')' '"'] # blank # lf_cr
let digit = ['0'-'9']
let hexdigit = digit | ['a'-'f' 'A'-'F']

let unquoted_start =
  unquoted # ['#' '|'] | '#' unquoted # ['|'] | '|' unquoted # ['#']

rule main buf = parse
  | lf | dos_newline { SmtMisc.found_newline lexbuf 0; main buf lexbuf }
  | blank+ | ';' (_ # lf_cr)* { main buf lexbuf }
  | '(' { LPAREN }
  | ')' { RPAREN }
  | '"'
      {
        scan_string buf (lexeme_start_p lexbuf) lexbuf;
        let str = Buffer.contents buf in
        Buffer.clear buf;
        STRING str
      }
  | "#;" { HASH_SEMI }
  | "#|"
      {
        scan_block_comment buf [lexeme_start_p lexbuf] lexbuf;
        main buf lexbuf
      }
  | "|#" { SmtMisc.main_failure lexbuf "illegal end of comment" }
  | '|'
    {
      scan_quoted buf (lexeme_start_p lexbuf) lexbuf;
      let str = Buffer.contents buf in
      Buffer.clear buf;
      STRING ("|"^ str ^"|")
    }
  | unquoted_start unquoted* ("#|" | "|#") unquoted*
      { SmtMisc.main_failure lexbuf "comment tokens in unquoted atom" }
  | "#" | unquoted_start unquoted* as str { STRING str }
  | eof { EOF }

and scan_string buf start = parse
  | '"' { () }
  | '\\' lf [' ' '\t']*
      {
        SmtMisc.found_newline lexbuf (SmtMisc.lexeme_len lexbuf - 2);
        scan_string buf start lexbuf
      }
  | '\\' dos_newline [' ' '\t']*
      {
        SmtMisc.found_newline lexbuf (SmtMisc.lexeme_len lexbuf - 3);
        scan_string buf start lexbuf
      }
  | '\\' (['\\' '\'' '"' 'n' 't' 'b' 'r' ' '] as c)
      {
        Buffer.add_char buf (SmtMisc.char_for_backslash c);
        scan_string buf start lexbuf
      }
  | '\\' (digit as c1) (digit as c2) (digit as c3)
      {
        let v = SmtMisc.dec_code c1 c2 c3 in
        if v > 255 then (
          let { pos_lnum; pos_bol; pos_cnum; _ } = lexeme_end_p lexbuf in
          let msg =
            sprintf
              "Sexplib.Lexer.scan_string: \
               illegal escape at line %d char %d: `\\%c%c%c'"
              pos_lnum (pos_cnum - pos_bol - 3)
              c1 c2 c3 in
          failwith msg);
        Buffer.add_char buf (Char.chr v);
        scan_string buf start lexbuf
      }
  | '\\' 'x' (hexdigit as c1) (hexdigit as c2)
      {
        let v = SmtMisc.hex_code c1 c2 in
        Buffer.add_char buf (Char.chr v);
        scan_string buf start lexbuf
      }
  | '\\' (_ as c)
      {
        Buffer.add_char buf '\\';
        Buffer.add_char buf c;
        scan_string buf start lexbuf
      }
  | lf
      {
        SmtMisc.found_newline lexbuf 0;
        Buffer.add_char buf SmtMisc.lf;
        scan_string buf start lexbuf
      }
  | ([^ '\\' '"'] # lf)+
      {
        Buffer.add_string buf (lexeme lexbuf);
        scan_string buf start lexbuf
      }
  | eof
      {
        let msg =
          sprintf
            "Sexplib.Lexer.scan_string: unterminated string at line %d char %d"
            start.pos_lnum (start.pos_cnum - start.pos_bol)
        in
        failwith msg
      }

and scan_quoted buf start = parse
  | '|' { () }
  | '\\' lf [' ' '\t']*
      {
        SmtMisc.found_newline lexbuf (SmtMisc.lexeme_len lexbuf - 2);
        scan_quoted buf start lexbuf
      }
  | '\\' dos_newline [' ' '\t']*
      {
        SmtMisc.found_newline lexbuf (SmtMisc.lexeme_len lexbuf - 3);
        scan_quoted buf start lexbuf
      }
  | '\\' (['\\' '\'' '"' 'n' 't' 'b' 'r' ' ' '|'] as c)
      {
        Buffer.add_char buf (SmtMisc.char_for_backslash c);
        scan_quoted buf start lexbuf
      }
  | '\\' (digit as c1) (digit as c2) (digit as c3)
      {
        let v = SmtMisc.dec_code c1 c2 c3 in
        if v > 255 then (
          let { pos_lnum; pos_bol; pos_cnum; _ } = lexeme_end_p lexbuf in
          let msg =
            sprintf
              "Sexplib.Lexer.scan_quoted: \
               illegal escape at line %d char %d: `\\%c%c%c'"
              pos_lnum (pos_cnum - pos_bol - 3)
              c1 c2 c3 in
          failwith msg);
        Buffer.add_char buf (Char.chr v);
        scan_quoted buf start lexbuf
      }
  | '\\' 'x' (hexdigit as c1) (hexdigit as c2)
      {
        let v = SmtMisc.hex_code c1 c2 in
        Buffer.add_char buf (Char.chr v);
        scan_quoted buf start lexbuf
      }
  | '\\' (_ as c)
      {
        Buffer.add_char buf '\\';
        Buffer.add_char buf c;
        scan_quoted buf start lexbuf
      }
  | lf
      {
        SmtMisc.found_newline lexbuf 0;
        Buffer.add_char buf SmtMisc.lf;
        scan_quoted buf start lexbuf
      }
  | ([^ '\\' '|'] # lf)+
      {
        Buffer.add_string buf (lexeme lexbuf);
        scan_quoted buf start lexbuf
      }
  | eof
      {
        let msg =
          sprintf
            "Sexplib.Lexer.scan_quoted: unterminated ident at line %d char %d"
            start.pos_lnum (start.pos_cnum - start.pos_bol)
        in
        failwith msg
      }

and scan_block_comment buf locs = parse
  | ('#'* | '|'*) lf
      { SmtMisc.found_newline lexbuf 0; scan_block_comment buf locs lexbuf }
  | (('#'* | '|'*) [^ '"' '#' '|'] # lf)+ { scan_block_comment buf locs lexbuf }
  | ('#'* | '|'*) '"'
      {
        let cur = lexeme_end_p lexbuf in
        let start = { cur with pos_cnum = cur.pos_cnum - 1 } in
        scan_string buf start lexbuf;
        Buffer.clear buf;
        scan_block_comment buf locs lexbuf
      }
  | '#'+ '|'
    {
      let cur = lexeme_end_p lexbuf in
      let start = { cur with pos_cnum = cur.pos_cnum - 2 } in
      scan_block_comment buf (start :: locs) lexbuf
    }
  | '|'+ '#'
      {
        match locs with
        | [_] -> ()
        | _ :: t -> scan_block_comment buf t lexbuf
        | [] -> assert false  (* impossible *)
      }
  | eof
      {
        match locs with
        | [] -> assert false
        | { pos_lnum; pos_bol; pos_cnum; _ } :: _ ->
            let msg =
              sprintf "Sexplib.Lexer.scan_block_comment: \
                unterminated block comment at line %d char %d"
                pos_lnum (pos_cnum - pos_bol)
            in
            failwith msg
      }

and ruleTail acc = parse
  | eof { acc }
  | _* as str { ruleTail (acc ^ str) lexbuf }

  
{
  let main ?buf =
    let buf =
      match buf with
      | None -> Buffer.create 64
      | Some buf -> Buffer.clear buf; buf
    in
    main buf
}

