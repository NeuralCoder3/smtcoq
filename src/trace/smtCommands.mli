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

(*
  general tactics and vernaculars to handle
  the calls from Coq for all smt provers

  for veriT this file contains the glue for the tactic
  and the whole logic for the theorem vernacular

  main part of theorem and tactic functions
*)


val parse_certif :
  CoqInterface.id ->
  CoqInterface.id ->
  CoqInterface.id ->
  CoqInterface.id ->
  CoqInterface.id ->
  CoqInterface.id ->
  CoqInterface.id ->
  SmtBtype.reify_tbl * SmtAtom.Op.reify_tbl *
  SmtAtom.Atom.reify_tbl * SmtAtom.Form.reify *
  SmtAtom.Form.t list * int * SmtAtom.Form.t SmtCertif.clause ->
  unit

val checker_debug :
  SmtBtype.reify_tbl * SmtAtom.Op.reify_tbl *
  SmtAtom.Atom.reify_tbl * SmtAtom.Form.reify *
  SmtAtom.Form.t list * int * SmtAtom.Form.t SmtCertif.clause -> 'a

(*
  similar to tactic but without reification
  it takes the certificate (parsed and imported by the solver)
  and build the proof term (similar to build_body)
  meanwhile the needed variables are generated as local axioms
*)
val theorem :
  CoqInterface.id ->
  SmtBtype.reify_tbl * SmtAtom.Op.reify_tbl *
  SmtAtom.Atom.reify_tbl * SmtAtom.Form.reify *
  SmtAtom.Form.t list * int * SmtAtom.Form.t SmtCertif.clause ->
  unit

val checker :
  SmtBtype.reify_tbl * SmtAtom.Op.reify_tbl *
  SmtAtom.Atom.reify_tbl * SmtAtom.Form.reify *
  SmtAtom.Form.t list * int * SmtAtom.Form.t SmtCertif.clause ->
  unit

(*
  a tactic that generates a proof inline
  the environments (global env Γ and local Σ) and conclusion (proof goal)
  are added by CoqInterface.mk_tactic
  it calls core_tactic
  which does the reification from bool to OCaml form,
  collects the lemmas, generates the hash tables,
  calls the solver (higher order argument call_solver)
  calls build_body which generates the proof,
  and returns the coq proof

  some tables are modified as side effect
*)
val tactic :
  (Environ.env ->
   SmtBtype.reify_tbl ->
   SmtAtom.Op.reify_tbl ->
   SmtAtom.Atom.reify_tbl ->
   SmtAtom.Form.reify ->
   (SmtAtom.Form.t SmtCertif.clause * SmtAtom.Form.t) ->
   SmtAtom.Form.t list -> int * SmtAtom.Form.t SmtCertif.clause) ->
  SmtMisc.logic ->
  SmtBtype.reify_tbl ->
  SmtAtom.Op.reify_tbl ->
  SmtAtom.Atom.reify_tbl ->
  SmtAtom.Form.reify ->
  SmtAtom.Atom.reify_tbl ->
  SmtAtom.Form.reify ->
  (Environ.env -> CoqInterface.constr -> CoqInterface.constr) ->
  CoqInterface.constr list ->
  CoqInterface.constr_expr list -> CoqInterface.tactic

val model_string : Environ.env -> SmtBtype.reify_tbl -> 'a -> 'b -> 'c -> SExpr.t -> string
