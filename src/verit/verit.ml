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


open SmtMisc
open CoqTerms
open SmtTrace
open SmtAtom
open SmtBtype
open SmtCertif


(* let debug = false *)


(******************************************************************************)
(* Given a verit trace build the corresponding certif and theorem             *)
(******************************************************************************)
(* exception Import_trace of int *)

(* let get_val = function
 *     Some a -> a
 *   | None -> assert false *)

(* For debugging certif processing : <add_scertif> <select> <occur> <alloc> *)
(* let print_certif c where=
 *   let r = ref c in
 *   let out_channel = open_out where in
 *   let fmt = Format.formatter_of_out_channel out_channel in
 *   let continue = ref true in
 *   while !continue do
 *     let kind = to_string (!r.kind) in
 *     let id = !r.id in
 *     let pos = match !r.pos with
 *       | None -> "None"
 *       | Some p -> string_of_int p in
 *     let used = !r.used in
 *     Format.fprintf fmt "id:%i kind:%s pos:%s used:%i value:" id kind pos used;
 *     begin match !r.value with
 *     | None -> Format.fprintf fmt "None"
 *     | Some l -> List.iter (fun f -> Form.to_smt Atom.to_smt fmt f;
 *                                     Format.fprintf fmt " ") l end;
 *     Format.fprintf fmt "\n";
 *     match !r.next with
 *     | None -> continue := false
 *     | Some n -> r := n
 *   done;
 *   Format.fprintf fmt "@."; close_out out_channel *)

let import_trace ra_quant rf_quant filename first lsmt =
  let chan = open_in filename in
  let lexbuf = Lexing.from_channel chan in
  let confl_num = ref (-1) in
  let first_num = ref (-1) in
  let is_first = ref true in
  let line = ref 1 in
  (* let _ = Parsing.set_trace true in *)
  try
    while true do
      confl_num := VeritParser.line VeritLexer.token lexbuf;
      if !is_first then (
        is_first := false;
        first_num := !confl_num
      );
      incr line
    done;
    raise VeritLexer.Eof
  with
    | VeritLexer.Eof ->
       close_in chan;
       let cfirst = ref (VeritSyntax.get_clause !first_num) in
       let confl = ref (VeritSyntax.get_clause !confl_num) in
       let re_hash = Form.hash_hform (Atom.hash_hatom ra_quant) rf_quant in
       begin match first with
       | None -> ()
       | Some _ ->
          let init_index = VeritSyntax.init_index lsmt re_hash in
          let cf, lr = order_roots init_index !cfirst in
          cfirst := cf;
          let to_add = VeritSyntax.qf_to_add (List.tl lr) in
          let to_add =
            (match first, !cfirst.value with
             | Some (root, l), Some [fl] when init_index fl = 1 && not (Form.equal l (re_hash fl)) ->
                 let cfirst_value = !cfirst.value in
                 !cfirst.value <- root.value;
                 [Other (ImmFlatten (root, fl)), cfirst_value, !cfirst]
             | _ -> []) @ to_add in
       match to_add with
       | [] -> ()
       | _  -> confl := add_scertifs to_add !cfirst end;
       select !confl;
       occur !confl;
       (alloc !cfirst, !confl)
    | Parsing.Parse_error -> failwith ("Verit.import_trace: parsing error line "^(string_of_int !line))


let clear_all () =
  SmtTrace.clear ();
  SmtMaps.clear ();
  VeritSyntax.clear ()


let import_all fsmt fproof =
  clear_all ();
  let rt = SmtBtype.create () in
  let ro = Op.create () in
  let ra = VeritSyntax.ra in
  let rf = VeritSyntax.rf in
  let ra_quant = VeritSyntax.ra_quant in
  let rf_quant = VeritSyntax.rf_quant in
  let roots = Smtlib2_genConstr.import_smtlib2 rt ro ra rf fsmt in
  let (max_id, confl) = import_trace ra_quant rf_quant fproof None [] in
  (rt, ro, ra, rf, roots, max_id, confl)


let parse_certif t_i t_func t_atom t_form root used_root trace fsmt fproof =
  SmtCommands.parse_certif t_i t_func t_atom t_form root used_root trace
    (import_all fsmt fproof)

let checker_debug fsmt fproof =
  SmtCommands.checker_debug (import_all fsmt fproof)

let theorem name fsmt fproof =
  SmtCommands.theorem name (import_all fsmt fproof)

let checker fsmt fproof =
  SmtCommands.checker (import_all fsmt fproof)



(******************************************************************************)
(** Given a Coq formula build the proof                                       *)
(******************************************************************************)

let export out_channel rt ro lsmt =
  let fmt = Format.formatter_of_out_channel out_channel in
  Format.fprintf fmt "(set-logic UFLIA)@.";

  List.iter (fun (i,t) ->
    let s = "Tindex_"^(string_of_int i) in
    SmtMaps.add_btype s (Tindex t);
    Format.fprintf fmt "(declare-sort %s 0)@." s
  ) (SmtBtype.to_list rt);

  List.iter (fun (i,dom,cod,op) ->
    let op_idx = SmtAtom.index_of_indexed_op op in
    let s = 
      match op_idx with
      | Rel_name n -> n
      | Rel_name2 (i,n) -> "op_"^(string_of_int i)^"_"^n
      | _ -> "op_"^(string_of_int i) in
    SmtMaps.add_fun s op;
    Format.fprintf fmt "(declare-fun %s (" s;
    let is_first = ref true in
    Array.iter (fun t -> if !is_first then is_first := false else Format.fprintf fmt " "; SmtBtype.to_smt fmt t) dom;
    Format.fprintf fmt ") ";
    SmtBtype.to_smt fmt cod;
    Format.fprintf fmt ")@."
  ) (Op.to_list ro);

  List.iter (fun u -> Format.fprintf fmt "(assert ";
                      Form.to_smt fmt u;
                      Format.fprintf fmt ")\n") lsmt;

  Format.fprintf fmt "(check-sat)\n(exit)@."

exception Unknown

let call_verit _ rt ro ra_quant rf_quant first lsmt =
  let (filename, outchan) = Filename.open_temp_file "verit_coq" ".smt2" in
  export outchan rt ro lsmt;
  close_out outchan;
  let logfilename = Filename.chop_extension filename ^ ".vtlog" in
  let wname, woc = Filename.open_temp_file "warnings_verit" ".log" in
  close_out woc;
  let command = "veriT --proof-prune --proof-merge --proof-with-sharing --cnf-definitional --disable-ackermann --input=smtlib2 --proof=" ^ logfilename ^ " " ^ filename ^ " 2> " ^ wname in
  Format.eprintf "%s@." command;
  let t0 = Sys.time () in
  let exit_code = Sys.command command in
  let t1 = Sys.time () in
  Format.eprintf "Verit = %.5f@." (t1-.t0);

  let win = open_in wname in

  let raise_warnings_errors () =
    try
      while true do
        let l = input_line win in
        let n = String.length l in
        if l = "warning : proof_done: status is still open" then
          raise Unknown
        else if l = "Invalid memory reference" then
          CoqInterface.warning "verit-warning" ("veriT outputted the warning: " ^ l)
        else if n >= 7 && String.sub l 0 7 = "warning" then
          CoqInterface.warning "verit-warning" ("veriT outputted the warning: " ^ (String.sub l 7 (n-7)))
        else if n >= 8 && String.sub l 0 8 = "error : " then
          CoqInterface.error ("veriT failed with the error: " ^ (String.sub l 8 (n-8)))
        else
          CoqInterface.error ("veriT failed with the error: " ^ l)
      done
    with End_of_file -> () in

  try
    if exit_code <> 0 then CoqInterface.warning "verit-non-zero-exit-code" ("Verit.call_verit: command " ^ command ^ " exited with code " ^ string_of_int exit_code);
    raise_warnings_errors ();
    let res = import_trace ra_quant rf_quant logfilename (Some first) lsmt in
    close_in win; Sys.remove wname; res
  with x -> close_in win; Sys.remove wname;
            match x with
            | Unknown -> CoqInterface.error "veriT returns 'unknown'"
            | VeritSyntax.Sat -> CoqInterface.error "veriT found a counter-example"
            | _ -> raise x

let verit_logic =
  SL.of_list [LUF; LLia]

let tactic_gen vm_cast lcpl lcepl =
  (* Transform the tuple of lemmas given by the user into a list *)
  let lcpl =
    let lcpl = EConstr.Unsafe.to_constr lcpl in
    let lcpl = CoqTerms.option_of_constr_option lcpl in
    match lcpl with
      | Some lcpl -> CoqTerms.list_of_constr_tuple lcpl
      | None -> []
  in

  (* Core tactic *)
  clear_all ();
  let rt = SmtBtype.create () in
  let ro = Op.create () in
  let ra = VeritSyntax.ra in
  let rf = VeritSyntax.rf in
  let ra_quant = VeritSyntax.ra_quant in
  let rf_quant = VeritSyntax.rf_quant in
  SmtCommands.tactic call_verit verit_logic rt ro ra rf ra_quant rf_quant vm_cast lcpl lcepl
let tactic = tactic_gen vm_cast_true
let tactic_no_check = tactic_gen (fun _ -> vm_cast_true_no_check)


let export_bool name fsmt =
  let open Names.GlobRef in
  match name with
  | VarRef _ ->
    CoqInterface.error("variables are not covered in this example")
  | IndRef _ ->
    CoqInterface.error( "inductive types are not covered in this example")
  | ConstructRef _ ->
    CoqInterface.error( "constructors are not covered in this example")
  | ConstRef cst ->
    let cb = Environ.lookup_constant cst (Global.env()) in
    match Global.body_of_constant_body Library.indirect_accessor cb with
    | Some(e, _, _) ->

      let env = Global.env () in
      let sigma = Evd.from_env env in
      (* let t = EConstr.of_constr e in *)
      (* Feedback.msg_warning(Printer.pr_econstr_env env sigma (t)) *)

      let t = e in

      let outchan = open_out fsmt in

      let rt = SmtBtype.create () in
      let ro = Op.create () in
      let ra = VeritSyntax.ra in
      let rf = VeritSyntax.rf in
      (* let lsmt = [] in *)

      let lsmt = [
        (* Form.of_coq (Atom.of_coq rt ro ra verit_logic env sigma) rf t *)
        (* mklApp cFxor (Array.map Lazy.force [|cFtrue;cFfalse|]) *)
        (* cFtrue *)
        (* SmtForm.Ftrue *)
        (* Form.of_coq (Atom.get ra) rf (cFtrue) *)




(* working *)
        (* Form.of_coq (Atom.of_coq rt ro ra verit_logic env sigma) rf 
          (Lazy.force ctrue) *)

        (* Form.of_coq (Atom.of_coq rt ro ra verit_logic env sigma) rf 
          ( mklApp cxorb (Array.map Lazy.force [|ctrue;cfalse|]) ) *)

(* working: bool -> formula
example: xorb true false *)
        Form.of_coq (Atom.of_coq rt ro ra verit_logic env sigma) rf t
      ] in
      export outchan rt ro lsmt;

      (* let fmt = Format.formatter_of_out_channel outchan in *)
      (* Format.fprintf fmt "(check-sat)\n(exit)@."; *)
      close_out outchan;

      ()
    | None -> CoqInterface.error( "This term has no value")



let run_verit filename logfilename =
  let wname = Filename.chop_extension filename ^ ".log" in
  let woc = open_out wname in
  close_out woc;
  let command = "veriT --proof-prune --proof-merge --proof-with-sharing --cnf-definitional --disable-ackermann --input=smtlib2 --proof=" ^ logfilename ^ " " ^ filename ^ " 2> " ^ wname in
  Format.eprintf "%s@." command;
  let t0 = Sys.time () in
  let exit_code = Sys.command command in
  let t1 = Sys.time () in
  Format.eprintf "Verit = %.5f@." (t1-.t0);

  let win = open_in wname in

  let raise_warnings_errors () =
    try
      while true do
        let l = input_line win in
        let n = String.length l in
        if l = "warning : proof_done: status is still open" then
          raise Unknown
        else if l = "Invalid memory reference" then
          CoqInterface.warning "verit-warning" ("veriT outputted the warning: " ^ l)
        else if n >= 7 && String.sub l 0 7 = "warning" then
          CoqInterface.warning "verit-warning" ("veriT outputted the warning: " ^ (String.sub l 7 (n-7)))
        else if n >= 8 && String.sub l 0 8 = "error : " then
          CoqInterface.error ("veriT failed with the error: " ^ (String.sub l 8 (n-8)))
        else
          CoqInterface.error ("veriT failed with the error: " ^ l)
      done
    with End_of_file -> () in

  try
    if exit_code <> 0 then CoqInterface.warning "verit-non-zero-exit-code" ("Verit.call_verit: command " ^ command ^ " exited with code " ^ string_of_int exit_code);
    raise_warnings_errors ();
    (* let res = import_trace ra_quant rf_quant logfilename (Some first) lsmt in *)
    close_in win; 
    ()
    (* Sys.remove wname; res *)
  with x -> close_in win; 
  (* Sys.remove wname; *)
            match x with
            | Unknown -> CoqInterface.error "veriT returns 'unknown'"
            | VeritSyntax.Sat -> CoqInterface.error "veriT found a counter-example"
            | _ -> raise x



let import_bool name smt fsmt fproof =
  let rt = SmtBtype.create () in
  let ro = Op.create () in
  let ra = VeritSyntax.ra in
  let rf = VeritSyntax.rf in
  let ra_quant = VeritSyntax.ra_quant in
  let rf_quant = VeritSyntax.rf_quant in

  let open Names.GlobRef in
  match smt with
  | VarRef _ ->
    CoqInterface.error("variables are not covered in this example")
  | IndRef _ ->
    CoqInterface.error( "inductive types are not covered in this example")
  | ConstructRef _ ->
    CoqInterface.error( "constructors are not covered in this example")
  | ConstRef cst ->
    let cb = Environ.lookup_constant cst (Global.env()) in
    match Global.body_of_constant_body Library.indirect_accessor cb with
    | None -> CoqInterface.error( "This term has no value")
    | Some(e, _, _) ->

  clear_all ();
      let env = Global.env () in
      let sigma = Evd.from_env env in

      let t = e in

      let lsmt = Form.of_coq (Atom.of_coq rt ro ra verit_logic env sigma) rf t in
      (* let l = Form.of_coq (Atom.of_coq rt ro ra solver_logic env sigma) rf a in *)
      (* let _ = Form.of_coq (Atom.of_coq ~eqsym:true rt ro ra_quant verit_logic env sigma) rf_quant t in *)
      let first = lsmt in
      let root = SmtTrace.mkRootV [first] in 
      let roots = [first] in 

      (* writes function table *)
      let (filename, outchan) = Filename.open_temp_file "verit_coq" ".smt2" in
      export outchan rt ro [lsmt];
      close_out outchan;

      (* Form.neg *)
  (* let rt2 = SmtBtype.create () in
  let ro2 = Op.create () in
  let ra2 = VeritSyntax.ra in
  let rf2 = VeritSyntax.rf in *)
      (* let roots = Smtlib2_genConstr.import_smtlib2 rt2 ro2 ra2 rf2 fsmt in *)
      (* let roots = Smtlib2_genConstr.import_smtlib2 rt ro2 ra rf fsmt in *)
      (* let roots = Smtlib2_genConstr.import_smtlib2 rt ro ra rf fsmt in *)

      let _ = (
      root
      ,t,sigma
      (* ,rt2,ro2,ra2,rf2 *)
      ) in
      (* let root = [lsmt] in *)




  (* let lcpl = [] in
  let lcepl = [] in
  let tlcepl = List.map (CoqInterface.interp_constr env sigma) lcepl in
  let lcpl = lcpl @ tlcepl in

  let create_lemma l =
    let cl = CoqInterface.retyping_get_type_of env sigma l in
    match SmtCommands.of_coq_lemma rt ro ra_quant rf_quant env sigma verit_logic cl with
      | Some smt -> Some ((cl, l), smt)
      | None -> None
  in
  let l_pl_ls = SmtMisc.filter_map create_lemma lcpl in
  let lsmt2 = List.map snd l_pl_ls in

  let lem_tbl : (int, CoqInterface.constr * CoqInterface.constr) Hashtbl.t =
    Hashtbl.create 100 in
  let new_ref ((l, pl), ls) =
    Hashtbl.add lem_tbl (Form.index ls) (l, pl) in

  List.iter new_ref l_pl_ls;
  let find_lemma cl =
    let re_hash hf = Form.hash_hform (Atom.hash_hatom ra_quant) rf_quant hf in
    match cl.value with
    | Some [l] ->
       let hl = re_hash l in
       begin try Hashtbl.find lem_tbl (Form.index hl)
             with Not_found ->
               let oc = open_out "/tmp/find_lemma.log" in
               let fmt = Format.formatter_of_out_channel oc in
               List.iter (fun u -> Format.fprintf fmt "%a\n" (Form.to_smt ~debug:true) u) lsmt2;
               Format.fprintf fmt "\n%a\n" (Form.to_smt ~debug:true) hl;
               flush oc; close_out oc; failwith "find_lemma" end
      | _ -> failwith "unexpected form of root" in *)




      let (max_id, confl) = import_trace ra_quant rf_quant fproof (Some (root,first)) [lsmt] in
  (* let (max_id, confl) = import_trace ra_quant rf_quant fproof None [] in *)
  (* let res = import_trace ra_quant rf_quant logfilename (Some first) lsmt in *)
      SmtCommands.theorem name (rt, ro, ra, rf, roots, max_id, confl)
      ~transform:(fun body ->
        CoqInterface.mkLetIn (CoqInterface.mkName "CompDec0", Lazy.force cint63_compdec, CoqInterface.retyping_get_type_of env sigma (Lazy.force cint63_compdec), body)
        )
      (* ~find:(Some find_lemma) *)

      (* SmtCommands.theorem name (rt, ro, ra, rf, root, max_id, confl) *)


      (* let forward _ rt ro ra_quant rf_quant first lsmt =
          import_trace ra_quant rf_quant fproof (Some first) lsmt
          (* (max_id,confl) *)
      in *)
      
      (* SmtCommands.tactic forward 
        verit_logic rt ro ra rf ra_quant rf_quant vm_cast_true [t] [] *)
      ;()
      (* SmtCommands.core_tactic forward 
        verit_logic rt ro ra rf ra_quant rf_quant vm_cast lcpl lcepl env sigma concl = *)

      (* let find_lemma cl =
        let re_hash hf = Form.hash_hform (Atom.hash_hatom ra_quant) rf_quant hf in
        match cl.value with
        | Some [l] ->
          let hl = re_hash l in
          begin try Hashtbl.find lem_tbl (Form.index hl)
                with Not_found ->
                  let oc = open_out "/tmp/find_lemma.log" in
                  let fmt = Format.formatter_of_out_channel oc in
                  List.iter (fun u -> Format.fprintf fmt "%a\n" (Form.to_smt ~debug:true) u) lsmt;
                  Format.fprintf fmt "\n%a\n" (Form.to_smt ~debug:true) hl;
                  flush oc; close_out oc; failwith "find_lemma" end
          | _ -> failwith "unexpected form of root" in

      (* let l = Form.of_coq (Atom.of_coq rt ro ra solver_logic env sigma) rf a in *)
      (* let _ = Form.of_coq (Atom.of_coq ~eqsym:true rt ro ra_quant solver_logic env sigma) rf_quant a in *)
      let l = lsmt in
      (* let nl = if (CoqInterface.eq_constr b (Lazy.force ctrue)) then Form.neg l else l in *)
      let nl = Form.neg l in
      let lsmt2 = Form.flatten rf nl :: lsmt in
      (* let max_id_confl = make_proof call_solver env rt ro ra_quant rf_quant nl lsmt in *)
      let max_id_confl = (max_id,confl) in
      SmtCommands.build_body rt ro ra rf (Form.to_coq l) b max_id_confl (vm_cast env) (Some find_lemma) *)