
# General remarks
* The actively used files are (or will be) documented
* the main additions happen in verit/verit.ml
* There is a Coq Form and OCaml form
    only the OCaml form is transformed to the Coq one
* the general flow is:
  (in Coq) Coq Prop + Integers + ... -> Bool
  (in OCaml)
  Bool -> Form -> Smt
  -> Certificate
  -> Form -> Coq Form -> Bool (with proofs each)
  (in Coq) possibly back to Prop, positivity check, ...
* veriT and is usage support UF_LIA
* `grep -r "[SOMETHING]" . --exclude "*.glob" --exclude "*.aux" -I --color=always` works great for searching things
* if one locally modified Coq files, the .vo* files need to be deleted for a fresh recompilation with correct prefixes
* the tools (especially veriT) need to be installed and in the path
    as described in the installation instructions
* the Coq files mentioned below have more information in their headers


# Short Overview
* call_stack.txt selected calls from functions to trace executions
* Conversion_tactics transform between N, nat, positive, Z, ...
* g_smtcoq.mlg Definitions of Vernaculars and OCaml tactics
* Tactic.v auxiliary tactics
* PropToBool.v tactics to move prop to bool (and back)
* ReflectFacts.v theorems used by PropToBool
* SMT_terms.v definition, interpretation, and lemmas for Coq form and atom
* classes/
  * SMT_classes.v definition of used type classes
  * SMT_classes_instances.v theirs instances registered in SMTCoq
* array/
  * FArray.v functional arrays for smt2
* Array/
  * PArray.v arrays based on finite maps using AVL trees (used in the Coq part)
* bva/
  * BVList.v Bit vectors and their operations