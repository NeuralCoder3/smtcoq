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
unlistet but important functions
  call_verit
    writes Form (Ocaml Form) to an smt2 file
    calls veriT and generates a proof certificate
    imports the trace via import_trace
    returns the resulting trace
  import_trace 
    reads in a certificate
  import_all 
    generates default arguments
    imports hypotheses using Smtlib2_genConstr.import_smtlib2
    imports a oblique trace
  export
    writes a OCaml form to smt2 file
*)

val parse_certif :
  CoqInterface.id ->
  CoqInterface.id ->
  CoqInterface.id ->
  CoqInterface.id ->
  CoqInterface.id -> CoqInterface.id -> CoqInterface.id -> string -> string -> unit
(* checks smt2 file together with certificate (proof log) *)
val checker : string -> string -> unit
val checker_debug : string -> string -> unit
(* like checker but also generates a Coq representation and proof 
    (generates definition in first argument) 
  calls SmtCommands.theorem with import_all of its arguments
*)
val theorem : CoqInterface.id -> string -> string -> unit
(* verit_bool_base tactic
    first argument are hypotheses (option of tuple)
    second is get_lemmas() => old lemmas?

    the environment and goal (conclusion) is added
      at SmtCommands.core_tactic using mk_tactic (in CoqInterface)

    generates default arguments (rt, ro, ra, rf, ...)
    calls SmtCommands.tactic and forwards call_verit
*)
val tactic : EConstr.t -> CoqInterface.constr_expr list -> CoqInterface.tactic
val tactic_no_check : EConstr.t -> CoqInterface.constr_expr list -> CoqInterface.tactic
(*
    looks up a defintion of a boolean statement
    executes selected part of inner mechanisms of tactic
    to reify the boolean statement to OCaml Form
    lastly writes the statement to a smt2 file
*)
val export_bool : CoqInterface.globRef -> string -> unit
(* 
  executes selected parts of call_verit
  takes a smt2 file and output (proof certificate destination)
  and basically calls veriT
 *)
val run_verit : string -> string -> unit
(*
    TODO should do the following
    imports a proof certificate like theorem
    but remembers local definitions like tactic

    the final idea is that the theorem can be different
    but build on the same variables which should be reused
    instead of manually being reconstructed
    (for instance a more complex statement is proven in the modified file)

    currently does:
    looks up a definition of a boolean statement (maybe not needed?)
    reifies the statement to OCaml form
    executes theorem => fails or forgets definitions

    the solution?
      ro seems to be the key for the variables
      used in atoms and forms
      namely t_func is the lookup array in the final form
      and it is constructed using applications to t_i and
      from the ro argument (a table/array)
      env and sigma should play an important role
      as the variables lie in the global environment
        (do they? We are in a module/section with localized axioms)
    problem:
      ro does not seem to differ between tactic and theorem
    not working:
      call parts of the tactic
      the tactic environment is different
      and tactic build up tactics (also internally in SmtCommands)
      not unit functions
    attempts:
      rebuild the functions or important parts thereof 
      namely replicate build_body from SmtCommands
    idea:
      use like theorem but add environment like core_tactic uses
      env and sigma =>
      ro is extended by Op.declare in Atom.of_coq
        which is used in Form.of_coq in core_tactic
        before calls to build_body

    (see call_stack.txt in parent directory for important call traces)

*)
val import_bool : CoqInterface.id -> CoqInterface.globRef -> string -> string -> unit
