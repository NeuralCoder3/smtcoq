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


Require Import Bool List Int63 Ring63 PArray ZArith.
Require Import Misc State SMT_terms Euf.

Require Import RingMicromega ZMicromega Coq.micromega.Tauto Psatz.

Local Open Scope array_scope.
Local Open Scope int63_scope.

Section certif.

  Variable t_form : PArray.array Form.form.
  Variable t_atom : PArray.array Atom.atom.

  Local Notation get_atom := (PArray.get t_atom) (only parsing).
  Local Notation get_form := (PArray.get t_form) (only parsing).

  Import EnvRing Atom.

  (* Register option_map as PrimInline. *)

  Section BuildPositive.
    Variable build_positive : hatom -> option positive.

    Definition build_positive_atom_aux (a:atom) : option positive :=
      match a with
      | Acop CO_xH => Some xH
      | Auop UO_xO a => option_map xO (build_positive a)
      | Auop UO_xI a => option_map xI (build_positive a)
      | _ => None
      end.

  End BuildPositive.

  Definition build_positive :=
    foldi
      (fun i cont h =>
          build_positive_atom_aux cont (get_atom h))
      0 (PArray.length t_atom) (fun _ => None).

  Definition build_positive_atom := build_positive_atom_aux build_positive.
  (* Register build_positive_atom as PrimInline. *)

  Section BuildZ.

    Definition build_z_atom_aux a :=
      match a with
      | Auop UO_Zpos a => option_map Zpos (build_positive a)
      | Acop CO_Z0 => Some Z0
      | Auop UO_Zneg a => option_map Zneg (build_positive a)
      | _ => None
      end.

  End BuildZ.

  Definition build_z h := build_z_atom_aux (get_atom h).

  Definition build_z_atom := build_z_atom_aux.

  Definition vmap := (positive * list Atom.atom)%type.

  Fixpoint find_var_aux h p (l:list Atom.atom) :=
    match l with
    | nil => None
    | h' :: l =>
      let p := Pos.pred p in
      if Atom.eqb h h' then Some p else find_var_aux h p l
    end.

  Definition find_var (vm:vmap) h :=
    let (count,map) := vm in
    match find_var_aux h count map with
    | Some p => (vm, p)
    | None => ((Pos.succ count,h::map), count)
    end.

  Definition empty_vmap : vmap := (1%positive, nil).

  Section BuildPExpr.

    Variable build_pexpr : vmap -> hatom -> (vmap * PExpr Z).

    Definition build_pexpr_atom_aux (vm:vmap) (h:atom) : vmap * PExpr Z :=
      match h with
      | Abop BO_Zplus a1 a2 =>
        let (vm, pe1) := build_pexpr vm a1 in
        let (vm, pe2) := build_pexpr vm a2 in
        (vm, PEadd pe1 pe2)
      | Abop BO_Zminus a1 a2 =>
        let (vm, pe1) := build_pexpr vm a1 in
        let (vm, pe2) := build_pexpr vm a2 in
        (vm, PEsub pe1 pe2)
      | Abop BO_Zmult a1 a2 =>
        let (vm, pe1) := build_pexpr vm a1 in
        let (vm, pe2) := build_pexpr vm a2 in
        (vm, PEmul pe1 pe2)
      | Auop UO_Zopp a =>
        let (vm, pe) := build_pexpr vm a in
        (vm, PEopp pe)
      | _ =>
        match build_z_atom h with
        | Some z => (vm, PEc z)
        | None =>
          let (vm,p) := find_var vm h in
          (vm,PEX p)
        end
      end.

  End BuildPExpr.

  Definition build_pexpr :=
     foldi
       (fun i cont vm h => build_pexpr_atom_aux cont vm (get_atom h))
       0 (PArray.length t_atom) (fun vm _ => (vm,PEc 0%Z)).

  Definition build_pexpr_atom := build_pexpr_atom_aux build_pexpr.

  (* Remark: We do not use OpNeq *)
  Definition build_op2 op :=
    match op with
    | (BO_eq Typ.TZ) => Some OpEq
    | BO_Zle => Some OpLe
    | BO_Zge => Some OpGe
    | BO_Zlt => Some OpLt
    | BO_Zgt => Some OpGt
    | _ => None
    end.

  Definition build_formula_atom vm (a:atom) :=
    match a with
    | Abop op a1 a2 =>
      match build_op2 op with
      | Some o =>
        let (vm,pe1) := build_pexpr vm a1 in
        let (vm,pe2) := build_pexpr vm a2 in
        Some (vm, Build_Formula pe1 o pe2)
      | None => None
      end
    | _ => None
    end.

  Definition build_formula vm h :=
      build_formula_atom vm (get_atom h).


  Section Build_form.

    Definition build_not2 i f :=
      foldi (fun _ (f' : BFormula (Formula Z) isProp) => NOT (NOT f')) 0 i f.

    Variable build_var : vmap -> var -> option (vmap*(BFormula (Formula Z) isProp)).


    Definition build_hform vm f : option (vmap*(BFormula (Formula Z) isProp)) :=
      match f with
        | Form.Fatom h =>
          match build_formula vm h with
            | Some (vm,f) => Some (vm, A isProp f tt)
            | None => None
          end
        | Form.Ftrue => Some (vm, TT isProp)
        | Form.Ffalse => Some (vm, FF isProp)
        | Form.Fnot2 i l =>
          match build_var vm (Lit.blit l) with
            | Some (vm, f) =>
              let f' := build_not2 i f in
              let f'' := if Lit.is_pos l then f' else NOT f' in
              Some (vm,f'')
            | None => None
          end
        | Form.Fand args =>
          afold_left _
            (fun vm => Some (vm, TT isProp))
            (fun a b vm =>
              match a vm with
                | Some (vm1, f1) =>
                  match b vm1 with
                    | Some (vm2, f2) => Some (vm2, AND f1 f2)
                    | None => None
                  end
                | None => None
              end)
            (amap
              (fun l vm => match build_var vm (Lit.blit l) with
                  | Some (vm', f) => Some (vm', if Lit.is_pos l then f else NOT f)
                  | None => None
                end)
              args)
            vm
        | Form.For args =>
          afold_left _
            (fun vm => Some (vm, FF isProp))
            (fun a b vm =>
              match a vm with
                | Some (vm1, f1) =>
                  match b vm1 with
                    | Some (vm2, f2) => Some (vm2, OR f1 f2)
                    | None => None
                  end
                | None => None
              end)
            (amap
              (fun l vm => match build_var vm (Lit.blit l) with
                  | Some (vm', f) => Some (vm', if Lit.is_pos l then f else NOT f)
                  | None => None
                end)
              args)
            vm
        | Form.Fxor a b =>
          match build_var vm (Lit.blit a) with
            | Some (vm1, f1) =>
              match build_var vm1 (Lit.blit b) with
                | Some (vm2, f2) =>
                  let f1' := if Lit.is_pos a then f1 else NOT f1 in
                  let f2' := if Lit.is_pos b then f2 else NOT f2 in
                  Some (vm2, AND (OR f1' f2') (OR (NOT f1') (NOT f2')))
                | None => None
              end
            | None => None
          end
        | Form.Fimp args =>
          afold_right _
            (fun vm => Some (vm, TT isProp))
            (fun a b vm =>
              match b vm with
                | Some (vm2, f2) =>
                  match a vm2 with
                    | Some (vm1, f1) => Some (vm1, IMPL f1 None f2)
                    | None => None
                  end
                | None => None
              end)
            (amap
              (fun l vm => match build_var vm (Lit.blit l) with
                  | Some (vm', f) => Some (vm', if Lit.is_pos l then f else NOT f)
                  | None => None
                end)
              args)
            vm
        | Form.Fiff a b =>
          match build_var vm (Lit.blit a) with
            | Some (vm1, f1) =>
              match build_var vm1 (Lit.blit b) with
                | Some (vm2, f2) =>
                  let f1' := if Lit.is_pos a then f1 else NOT f1 in
                  let f2' := if Lit.is_pos b then f2 else NOT f2 in
                  Some (vm2, AND (OR f1' (NOT f2')) (OR (NOT f1') f2'))
                | None => None
              end
            | None => None
          end
        | Form.Fite a b c =>
          match build_var vm (Lit.blit a) with
            | Some (vm1, f1) =>
              match build_var vm1 (Lit.blit b) with
                | Some (vm2, f2) =>
                  match build_var vm2 (Lit.blit c) with
                    | Some (vm3, f3) =>
                      let f1' := if Lit.is_pos a then f1 else NOT f1 in
                      let f2' := if Lit.is_pos b then f2 else NOT f2 in
                      let f3' := if Lit.is_pos c then f3 else NOT f3 in
                      Some (vm3, OR (AND f1' f2') (AND (NOT f1') f3'))
                    | None => None
                  end
                | None => None
              end
            | None => None
          end
        | Form.FbbT _ _ => None
      end.

  End Build_form.


  Definition build_var :=
    foldi
    (fun i cont vm h => build_hform cont vm (get_form h))
    0 (PArray.length t_form) (fun _ _ => None).

  Definition build_form := build_hform build_var.


  Definition build_nlit vm l :=
    let l := Lit.neg l in
    match build_form vm (get_form (Lit.blit l)) with
      | Some (vm,f) =>
        let f := if Lit.is_pos l then f else NOT f in
        Some (vm,f)
      | None => None
    end.


  Fixpoint build_clause_aux vm (cl:list _lit) {struct cl} :
    option (vmap * BFormula (Formula Z) isProp) :=
    match cl with
    | nil => None
    | l::nil => build_nlit vm l
    | l::cl =>
      match build_nlit vm l with
      | Some (vm,bf1) =>
        match build_clause_aux vm cl with
        | Some (vm,bf2) => Some (vm, AND bf1 bf2)
        | _ => None
        end
      | None => None
      end
    end.

  Definition build_clause vm cl :=
    match build_clause_aux vm cl with
    | Some (vm, bf) => Some (vm, IMPL bf None (FF isProp))
    | None => None
    end.

  Definition get_eq (l:_lit) (f : Atom.hatom -> Atom.hatom -> C.t) :=
    if Lit.is_pos l then
      match get_form (Lit.blit l) with
        | Form.Fatom xa =>
          match get_atom xa with
            | Atom.Abop (Atom.BO_eq _) a b => f a b
            | _ => C._true
          end
        | _ => C._true
      end
      else C._true.
  (* Register get_eq as PrimInline. *)

  Definition get_not_le (l:_lit) (f : Atom.hatom -> Atom.hatom -> C.t) :=
    if negb (Lit.is_pos l) then
    match get_form (Lit.blit l) with
      | Form.Fatom xa =>
        match get_atom xa with
          | Atom.Abop (Atom.BO_Zle) a b => f a b
          | _ => C._true
        end
      | _ => C._true
    end
      else C._true.
  (* Register get_not_le as PrimInline. *)

  Definition check_micromega cl c : C.t :=
    match build_clause empty_vmap cl with
      | Some (_, bf) =>
        if ZTautoChecker bf c then cl
          else C._true
      | None => C._true
    end.

  Definition check_diseq l : C.t :=
    match get_form (Lit.blit l) with
      |Form.For a =>
        if PArray.length a == 3 then
          let a_eq_b := a.[0] in
          let not_a_le_b := a.[1] in
          let not_b_le_a := a.[2] in
          get_eq a_eq_b (fun a b => get_not_le not_a_le_b (fun a' b' => get_not_le not_b_le_a (fun b'' a'' =>
            if (a == a') && (a == a'') && (b == b') && (b == b'')
              then (Lit.lit (Lit.blit l))::nil
              else
                if (a == b') && (a == b'') && (b == a') && (b == a'')
                  then (Lit.lit (Lit.blit l))::nil
                  else C._true)))
          else C._true
      | _ => C._true
    end.


  Section Proof.

    Variables (t_i : array SMT_classes.typ_compdec)
              (t_func : array (Atom.tval t_i))
              (ch_atom : Atom.check_atom t_atom)
              (ch_form : Form.check_form t_form)
              (wt_t_atom : Atom.wt t_i t_func t_atom).

    Local Notation check_atom :=
      (check_aux t_i t_func (get_type t_i t_func t_atom)).

    Local Notation interp_form_hatom :=
      (Atom.interp_form_hatom t_i t_func t_atom).

    Local Notation interp_form_hatom_bv :=
      (Atom.interp_form_hatom_bv t_i t_func t_atom).

    Local Notation rho :=
      (Form.interp_state_var interp_form_hatom interp_form_hatom_bv t_form).

    Local Notation t_interp := (t_interp t_i t_func t_atom).

    Local Notation interp_atom :=
      (interp_aux t_i t_func (get t_interp)).

    Let wf_t_atom : Atom.wf t_atom.
    Proof. destruct (Atom.check_atom_correct _ ch_atom); auto. Qed.

    Let def_t_atom : default t_atom = Atom.Acop Atom.CO_xH.
    Proof. destruct (Atom.check_atom_correct _ ch_atom); auto. Qed.

    Let def_t_form : default t_form = Form.Ftrue.
    Proof.
      destruct (Form.check_form_correct interp_form_hatom interp_form_hatom_bv _ ch_form) as [H _]; destruct H; auto.
    Qed.

    Let wf_t_form : Form.wf t_form.
    Proof.
      destruct (Form.check_form_correct interp_form_hatom interp_form_hatom_bv _ ch_form) as [H _]; destruct H; auto.
    Qed.

    Let wf_rho : Valuation.wf rho.
    Proof.
      destruct (Form.check_form_correct interp_form_hatom interp_form_hatom_bv _ ch_form); auto.
    Qed.

    Lemma build_positive_atom_aux_correct :
       forall (build_positive : hatom -> option positive),
       (forall (h : hatom) p,
          build_positive h = Some p ->
          t_interp.[h] = Bval t_i Typ.Tpositive p) ->
       forall (a:atom) (p:positive),
         build_positive_atom_aux build_positive a = Some p ->
         interp_atom a = Bval t_i Typ.Tpositive p.
    Proof.
      intros build_positive Hbuild a; case a; simpl; try discriminate; auto.
      destruct c; simpl; try discriminate; intros p H1; inversion_clear H1; auto.
      destruct u; simpl; try discriminate;
        intros i p; case_eq (build_positive i); simpl; try discriminate; intros q H1 H2; inversion_clear H2; rewrite (Hbuild _ _ H1); auto.
    Qed.

    Lemma build_positive_correct : forall h p,
      build_positive h = Some p ->
      t_interp.[h] = Bval t_i Typ.Tpositive p.
    Proof.
      unfold build_positive.
      apply foldi_ind;intros;try discriminate.
      apply leb_0.
      rewrite t_interp_wf;trivial.
      apply (build_positive_atom_aux_correct a); trivial.
    Qed.

    Lemma build_positive_atom_correct :
       forall (a:atom) (p:positive),
         build_positive_atom a = Some p ->
         interp_atom a = Bval t_i Typ.Tpositive p.
    Proof.
     apply build_positive_atom_aux_correct;apply build_positive_correct.
    Qed.

    Lemma build_z_atom_aux_correct :
       forall a z,
         build_z_atom_aux a = Some z ->
         interp_atom a = Bval t_i Typ.TZ z.
    Proof.
     intros a z.
     destruct a;simpl;try discriminate;auto.
     destruct c;[discriminate | intros Heq;inversion Heq;trivial | discriminate].
     destruct u;try discriminate;
       case_eq (build_positive i);try discriminate;
       intros p Hp Heq;inversion Heq;clear Heq;subst;
       rewrite (build_positive_correct _ _ Hp);trivial.
    Qed.

    Lemma build_z_correct :
      forall h z, build_z h = Some z -> t_interp.[h] = Bval t_i Typ.TZ z.
    Proof.
     unfold build_z;intros h z;rewrite t_interp_wf;trivial.
     apply build_z_atom_aux_correct;discriminate.
    Qed.

    Lemma build_z_atom_correct :
      forall a z, build_z_atom a = Some z ->
      interp_atom a = Bval t_i Typ.TZ z.
    Proof.
     apply build_z_atom_aux_correct.
    Qed.

    Definition wf_vmap (vm:vmap) :=
      (List.length (snd vm) = nat_of_P (fst vm) - 1)%nat /\
      List.forallb (fun h => check_atom h Typ.TZ) (snd vm).

    Fixpoint bounded_pexpr (p:positive) (pe:PExpr Z) :=
      match pe with
      | PEc _ => true
      | @PEX _ x => Zlt_bool (Zpos x) (Zpos p)
      | PEadd pe1 pe2
      | PEsub pe1 pe2
      | PEmul pe1 pe2 => bounded_pexpr p pe1 && bounded_pexpr p pe2
      | PEopp pe => bounded_pexpr p pe
      | PEpow pe _ => bounded_pexpr p pe
      end.

    Definition bounded_formula (p:positive) (f:Formula Z) :=
      bounded_pexpr p (f.(Flhs)) &&  bounded_pexpr p (f.(Frhs)).

    Fixpoint bounded_bformula (p:positive) {k:kind} (bf:BFormula (Formula Z) k) : bool :=
      match bf with
      | @TT _ _ _ _ _ | @FF _ _ _ _ _ | @X _ _ _ _ _ _ => true
      | A _ f _ => bounded_formula p f
      | AND bf1 bf2
      | OR bf1 bf2
      | IMPL bf1 _ bf2 => bounded_bformula p bf1 && bounded_bformula p bf2
      | NOT bf => bounded_bformula p bf
      | IFF bf1 bf2 => bounded_bformula p bf1 && bounded_bformula p bf2
      | EQ bf1 bf2 => bounded_bformula p bf1 && bounded_bformula p bf2
      end.

    Definition interp_vmap (vm:vmap) p :=
      match nth_error (snd vm) (nat_of_P (fst vm - p) - 1)%nat  with
      | Some a =>
        let (t,v) := interp_atom a in
        match Typ.cast t Typ.TZ with
        | Typ.Cast k => k (Typ.interp t_i) v
        | _ => 0%Z
        end
      | _ => 0%Z
      end.

    Lemma find_var_aux_lt :
      forall h p lvm pvm,
      find_var_aux h pvm lvm = Some p ->
      Datatypes.length lvm = (nat_of_P pvm - 1)%nat ->
      (nat_of_P p < nat_of_P pvm)%nat.
    Proof.
      induction lvm;simpl;try discriminate.
      intros pvm Heq1 Heq.
      assert (1 < pvm)%positive.
       rewrite Plt_lt;change (nat_of_P 1) with 1%nat ;lia.
      assert (Datatypes.length lvm = nat_of_P (Pos.pred pvm) - 1)%nat.
       rewrite Ppred_minus, Pminus_minus;trivial.
       change (nat_of_P 1) with 1%nat ;try lia.
      revert Heq1.
      destruct (Atom.reflect_eqb h a);subst.
      intros Heq1;inversion Heq1;clear Heq1;subst;lia.
      intros Heq1;apply IHlvm in Heq1;trivial.
      apply lt_trans with (1:= Heq1);lia.
    Qed.

    Lemma build_pexpr_atom_aux_correct_z :
      forall (h : atom) (vm vm' : vmap) (pe : PExpr Z),
       check_atom h Typ.TZ ->
       match build_z_atom h with
       | Some z => (vm, PEc z)
       | None => let (vm0, p) := find_var vm h in (vm0, PEX p)
       end = (vm', pe) ->
       wf_vmap vm ->
       wf_vmap vm' /\
       (nat_of_P (fst vm) <= nat_of_P (fst vm'))%nat /\
       (forall p,
           (nat_of_P p < nat_of_P (fst vm))%nat ->
           nth_error (snd vm) (nat_of_P (fst vm - p) - 1) =
           nth_error (snd vm')(nat_of_P (fst vm' - p) - 1)) /\
       bounded_pexpr (fst vm') pe /\
       interp_atom h = Bval t_i Typ.TZ (Zeval_expr (interp_vmap vm') pe).
    Proof.
     intros h vm vm' pe Hh.
     case_eq (build_z_atom h).
     intros z Hb Heq;inversion Heq;clear Heq;subst.
     intros (Hwf1, Hwf2).
     repeat split;auto with zarith.
     rewrite (build_z_atom_correct _ _ Hb);trivial.
     intros _;unfold find_var;destruct vm as (pvm,lvm).
     case_eq (find_var_aux h pvm lvm).
     intros p Hf Heq;inversion Heq;clear Heq;subst.
     intros (Hwf1, Hwf2);repeat split;auto with zarith.
     simpl; unfold is_true;rewrite <- Zlt_is_lt_bool.
     rewrite <- !Z_of_nat_of_P; apply inj_lt;simpl in Hwf1.
     apply  find_var_aux_lt with (1:= Hf);trivial.
     revert lvm pvm p Hf Hwf1 Hwf2.
     unfold interp_vmap;simpl.
     induction lvm;simpl;try discriminate.
     intros pvm p Heq1 Heq.
     assert (1 < pvm)%positive.
       rewrite Plt_lt;change (nat_of_P 1) with 1%nat ;lia.
     assert (Datatypes.length lvm = nat_of_P (Pos.pred pvm) - 1)%nat.
     rewrite Ppred_minus, Pminus_minus;trivial.
     change (nat_of_P 1) with 1%nat ;try lia.
     revert Heq1.
     destruct (Atom.reflect_eqb h a);subst.
     intros Heq1;inversion Heq1;clear Heq1;subst.
     unfold is_true;rewrite andb_true_iff;intros (H1,H2).
     assert (1 < nat_of_P pvm)%nat by (rewrite Plt_lt in H;trivial).
     assert (W:=nat_of_P_pos (Pos.pred pvm)).
     assert (nat_of_P (pvm - Pos.pred pvm) - 1 = 0)%nat.
      rewrite Pminus_minus;lia.
     rewrite H4;simpl.
     destruct (check_aux_interp_aux _ _ _ wf_t_atom _ _ H1) as (z,Hz).
     rewrite Hz;trivial.
     unfold is_true;rewrite andb_true_iff;intros Heq1 (H1,H2).
     assert (W:= find_var_aux_lt _ _ _ _ Heq1 H0).
     assert (nat_of_P (pvm - p) - 1 = S (nat_of_P (Pos.pred pvm - p) - 1))%nat.
       assert (W1:= W);rewrite <- Plt_lt in W.
       rewrite !Pminus_minus;trivial.
       assert (W2:=nat_of_P_pos (Pos.pred pvm)).
       lia.
       rewrite Plt_lt.
       apply lt_trans with (1:= W1);lia.
     rewrite H3;simpl;apply IHlvm;trivial.
     intros _ Heq;inversion Heq;clear Heq;subst;unfold wf_vmap;
       simpl;intros (Hwf1, Hwf2);repeat split;simpl.
     rewrite Psucc_S; assert (W:= nat_of_P_pos pvm);lia.
     rewrite Hh;trivial.
     rewrite Psucc_S;lia.
     intros p Hlt;
      assert (nat_of_P (Pos.succ pvm - p) - 1 = S (nat_of_P (pvm - p) - 1))%nat.
       assert (W1:= Hlt);rewrite <- Plt_lt in W1.
       rewrite !Pminus_minus;trivial.
       rewrite Psucc_S;lia.
       rewrite Plt_lt, Psucc_S;lia.
     rewrite H;trivial.
     unfold is_true;rewrite <- Zlt_is_lt_bool.
     rewrite Zpos_succ_morphism;lia.
     destruct (check_aux_interp_aux _ _ _ wf_t_atom _ _ Hh) as (z,Hz).
     rewrite Hz;unfold interp_vmap;simpl.
     assert (nat_of_P (Pos.succ pvm - pvm) = 1%nat).
       rewrite Pplus_one_succ_l, Pminus_minus, Pplus_plus.
       change (nat_of_P 1) with 1%nat;lia.
       rewrite Plt_lt, Pplus_plus.
       change (nat_of_P 1) with 1%nat;lia.
     rewrite H;simpl;rewrite Hz;trivial.
   Qed.

   Lemma bounded_pexpr_le :
     forall p p',
       (nat_of_P p <= nat_of_P p')%nat ->
        forall pe,
        bounded_pexpr p pe -> bounded_pexpr p' pe.
   Proof.
    unfold is_true;induction pe;simpl;trivial.
    rewrite <- !Zlt_is_lt_bool; rewrite <- Ple_le in H.
    intros H1;apply Z.lt_le_trans with (1:= H1);trivial.
    rewrite !andb_true_iff;intros (H1,H2);auto.
    rewrite !andb_true_iff;intros (H1,H2);auto.
    rewrite !andb_true_iff;intros (H1,H2);auto.
   Qed.

   Lemma interp_pexpr_le :
     forall vm vm',
       (forall (p : positive),
         (nat_of_P p < nat_of_P (fst vm))%nat ->
         nth_error (snd vm) (nat_of_P (fst vm - p) - 1) =
         nth_error (snd vm') (nat_of_P (fst vm' - p) - 1)) ->
     forall pe,
       bounded_pexpr (fst vm) pe ->
       Zeval_expr (interp_vmap vm) pe = Zeval_expr (interp_vmap vm') pe.
   Proof.
    intros vm vm' Hnth.
    unfold is_true;induction pe;simpl;trivial.
    unfold interp_vmap, is_true;rewrite <- Zlt_is_lt_bool.
    intros Hlt;rewrite Hnth;trivial.
    rewrite <- Plt_lt;trivial.
    rewrite andb_true_iff;intros (H1,H2);rewrite IHpe1, IHpe2;trivial.
    rewrite andb_true_iff;intros (H1,H2);rewrite IHpe1, IHpe2;trivial.
    rewrite andb_true_iff;intros (H1,H2);rewrite IHpe1, IHpe2;trivial.
    intros H1;rewrite IHpe;trivial.
    intros H1;rewrite IHpe;trivial.
   Qed.

   Lemma build_pexpr_atom_aux_correct :
      forall (build_pexpr : vmap -> hatom -> vmap * PExpr Z) h i,
        (forall h' vm vm' pe,
          h' < h ->
          Typ.eqb (get_type t_i t_func t_atom h') Typ.TZ ->
          build_pexpr vm h' = (vm',pe) ->
          wf_vmap vm ->
          wf_vmap vm' /\
          (nat_of_P (fst vm) <= nat_of_P (fst vm'))%nat /\
          (forall p,
           (nat_of_P p < nat_of_P (fst vm))%nat ->
           nth_error (snd vm) (nat_of_P (fst vm - p) - 1) =
           nth_error (snd vm')(nat_of_P (fst vm' - p) - 1)) /\
          bounded_pexpr (fst vm') pe /\
          t_interp.[h'] = Bval t_i Typ.TZ (Zeval_expr (interp_vmap vm') pe))->
        forall a vm vm' pe,
          h < i ->
          lt_atom h a ->
          check_atom a Typ.TZ ->
          build_pexpr_atom_aux build_pexpr vm a = (vm',pe) ->
          wf_vmap vm ->
          wf_vmap vm' /\
          (nat_of_P (fst vm) <= nat_of_P (fst vm'))%nat /\
          (forall p,
           (nat_of_P p < nat_of_P (fst vm))%nat ->
           nth_error (snd vm) (nat_of_P (fst vm - p) - 1) =
           nth_error (snd vm')(nat_of_P (fst vm' - p) - 1)) /\
          bounded_pexpr (fst vm') pe /\
          interp_atom a = Bval t_i Typ.TZ (Zeval_expr (interp_vmap vm') pe).
   Proof.
     intros build_pexpr h i Hb a.
Opaque build_z_atom interp_aux.
     case a;simpl;
       try (intros;apply build_pexpr_atom_aux_correct_z;trivial;fail).

     intros u; destruct u; intros jind vm vm' pe _H_ Hlt Ht;
       try (intros;apply build_pexpr_atom_aux_correct_z;trivial;fail).
     generalize (Hb jind vm vm').
     destruct (build_pexpr vm jind) as (vm0, pe0); intro W1.
     intros Heq Hwf;inversion Heq;clear Heq;subst.
     assert (W:= W1 pe0 Hlt Ht (refl_equal _) Hwf).
     decompose [and] W;clear W W1.
     destruct H;repeat split;trivial.
Transparent interp_aux.
     simpl;rewrite H4;trivial.

     intro b; destruct b; intros j k vm vm' pe HH Hlt Ht;
       try (intros;apply build_pexpr_atom_aux_correct_z;trivial;fail).

     generalize (Hb j vm). destruct (build_pexpr vm j) as (vm0,pe0). intro IH.
     generalize (Hb k vm0). destruct (build_pexpr vm0 k) as (vm1,pe1). intro IH'.
     simpl in Ht;unfold is_true in Ht;rewrite !andb_true_iff in Ht;
       decompose [and] Ht;clear Ht.
     unfold is_true in Hlt;rewrite andb_true_iff in Hlt;destruct Hlt as (Hlt1, Hlt2).
     intros Heq Hwf;inversion Heq;clear Heq;subst.
     assert (W:= IH _ _ Hlt1 H (refl_equal _) Hwf);clear IH.
     decompose [and] W;clear W.
     assert (W:= IH' _ _ Hlt2 H0 (refl_equal _) H1);clear IH'.
     decompose [and] W;clear W.
     destruct H5;repeat split;trivial.
     apply le_trans with (1:= H3);trivial.
     intros p Hlt;rewrite H2, H7;trivial.
     apply lt_le_trans with (1:=Hlt);trivial.
     simpl;rewrite H9, andb_true_r.
     apply (bounded_pexpr_le (fst vm0));auto with arith.
     simpl;rewrite H6, H11;simpl.
     rewrite (interp_pexpr_le _ _ H7 _ H4);trivial.

     generalize (Hb j vm). destruct (build_pexpr vm j) as (vm0,pe0); intro IH.
     generalize (Hb k vm0). destruct (build_pexpr vm0 k) as (vm1,pe1). intro IH'.
     simpl in Ht;unfold is_true in Ht;rewrite !andb_true_iff in Ht;
       decompose [and] Ht;clear Ht.
     unfold is_true in Hlt;rewrite andb_true_iff in Hlt;destruct Hlt as (Hlt1, Hlt2).
     intros Heq Hwf;inversion Heq;clear Heq;subst.
     assert (W:= IH _ _ Hlt1 H (refl_equal _) Hwf);clear IH.
     decompose [and] W;clear W.
     assert (W:= IH' _ _ Hlt2 H0 (refl_equal _) H1);clear IH'.
     decompose [and] W;clear W.
     destruct H5;repeat split;trivial.
     apply le_trans with (1:= H3);trivial.
     intros p Hlt;rewrite H2, H7;trivial.
     apply lt_le_trans with (1:=Hlt);trivial.
     simpl;rewrite H9, andb_true_r.
     apply (bounded_pexpr_le (fst vm0));auto with arith.
     simpl;rewrite H6, H11;simpl.
     rewrite (interp_pexpr_le _ _ H7 _ H4);trivial.

     generalize (Hb j vm). destruct (build_pexpr vm j) as (vm0,pe0); intro IH.
     generalize (Hb k vm0). destruct (build_pexpr vm0 k) as (vm1,pe1). intro IH'.
     simpl in Ht;unfold is_true in Ht;rewrite !andb_true_iff in Ht;
       decompose [and] Ht;clear Ht.
     unfold is_true in Hlt;rewrite andb_true_iff in Hlt;destruct Hlt as (Hlt1, Hlt2).
     intros Heq Hwf;inversion Heq;clear Heq;subst.
     assert (W:= IH _ _ Hlt1 H (refl_equal _) Hwf);clear IH.
     decompose [and] W;clear W.
     assert (W:= IH' _ _ Hlt2 H0 (refl_equal _) H1);clear IH'.
     decompose [and] W;clear W.
     destruct H5;repeat split;trivial.
     apply le_trans with (1:= H3);trivial.
     intros p Hlt;rewrite H2, H7;trivial.
     apply lt_le_trans with (1:=Hlt);trivial.
     simpl;rewrite H9, andb_true_r.
     apply (bounded_pexpr_le (fst vm0));auto with arith.
     simpl;rewrite H6, H11;simpl.
     rewrite (interp_pexpr_le _ _ H7 _ H4);trivial.
   Qed.
Transparent build_z_atom.

   Lemma build_pexpr_atom_aux_correct' :
      forall (build_pexpr : vmap -> hatom -> vmap * PExpr Z),
        (forall h' vm vm' pe,
          Typ.eqb (get_type t_i t_func t_atom h') Typ.TZ ->
          build_pexpr vm h' = (vm',pe) ->
          wf_vmap vm ->
          wf_vmap vm' /\
          (nat_of_P (fst vm) <= nat_of_P (fst vm'))%nat /\
          (forall p,
           (nat_of_P p < nat_of_P (fst vm))%nat ->
           nth_error (snd vm) (nat_of_P (fst vm - p) - 1) =
           nth_error (snd vm')(nat_of_P (fst vm' - p) - 1)) /\
          bounded_pexpr (fst vm') pe /\
          t_interp.[h'] = Bval t_i Typ.TZ (Zeval_expr (interp_vmap vm') pe))->
        forall a vm vm' pe,
          check_atom a Typ.TZ ->
          build_pexpr_atom_aux build_pexpr vm a = (vm',pe) ->
          wf_vmap vm ->
          wf_vmap vm' /\
          (nat_of_P (fst vm) <= nat_of_P (fst vm'))%nat /\
          (forall p,
           (nat_of_P p < nat_of_P (fst vm))%nat ->
           nth_error (snd vm) (nat_of_P (fst vm - p) - 1) =
           nth_error (snd vm')(nat_of_P (fst vm' - p) - 1)) /\
          bounded_pexpr (fst vm') pe /\
          interp_atom a = Bval t_i Typ.TZ (Zeval_expr (interp_vmap vm') pe).
   Proof.
     intros build_pexpr Hb a.
Opaque build_z_atom interp_aux.
     case a;simpl;
       try (intros;apply build_pexpr_atom_aux_correct_z;trivial;fail).
     intro u; destruct u; intros ind vm vm' pe Ht;
       try (intros;apply build_pexpr_atom_aux_correct_z;trivial;fail).
     generalize (Hb ind vm); clear Hb.
     destruct (build_pexpr vm ind) as (vm0,pe0); intro IH.
     intros Heq Hwf;inversion Heq;clear Heq;subst.
     assert (W:= IH vm' pe0 Ht (refl_equal _) Hwf).
     decompose [and] W;clear W IH.
     destruct H;repeat split;trivial.
Transparent interp_aux.
     simpl;rewrite H4;trivial.

     intro b; destruct b; intros j k vm vm' pe Ht;
       try (intros;apply build_pexpr_atom_aux_correct_z;trivial;fail).
     generalize (Hb j vm).
     destruct (build_pexpr vm j) as (vm0,pe0); intro IH.
     generalize (Hb k vm0); clear Hb.
     destruct (build_pexpr vm0 k) as (vm1,pe1); intro IH'.
     simpl in Ht;unfold is_true in Ht;rewrite !andb_true_iff in Ht;
       decompose [and] Ht;clear Ht.
     intros Heq Hwf;inversion Heq;clear Heq;subst.
     assert (W:= IH _ _ H (refl_equal _) Hwf);clear IH.
     decompose [and] W;clear W.
     assert (W:= IH' _ _ H0 (refl_equal _) H1);clear IH'.
     decompose [and] W;clear W.
     destruct H5;repeat split;trivial.
     apply le_trans with (1:= H3);trivial.
     intros p Hlt;rewrite H2, H7;trivial.
     apply lt_le_trans with (1:=Hlt);trivial.
     simpl;rewrite H9, andb_true_r.
     apply (bounded_pexpr_le (fst vm0));auto with arith.
     simpl;rewrite H6, H11;simpl.
     rewrite (interp_pexpr_le _ _ H7 _ H4);trivial.

     generalize (Hb j vm).
     destruct (build_pexpr vm j) as (vm0,pe0); intro IH.
     generalize (Hb k vm0); clear Hb.
     destruct (build_pexpr vm0 k) as (vm1,pe1); intro IH'.
     simpl in Ht;unfold is_true in Ht;rewrite !andb_true_iff in Ht;
       decompose [and] Ht;clear Ht.
     intros Heq Hwf;inversion Heq;clear Heq;subst.
     assert (W:= IH _ _ H (refl_equal _) Hwf);clear IH.
     decompose [and] W;clear W.
     assert (W:= IH' _ _ H0 (refl_equal _) H1);clear IH'.
     decompose [and] W;clear W.
     destruct H5;repeat split;trivial.
     apply le_trans with (1:= H3);trivial.
     intros p Hlt;rewrite H2, H7;trivial.
     apply lt_le_trans with (1:=Hlt);trivial.
     simpl;rewrite H9, andb_true_r.
     apply (bounded_pexpr_le (fst vm0));auto with arith.
     simpl;rewrite H6, H11;simpl.
     rewrite (interp_pexpr_le _ _ H7 _ H4);trivial.

     generalize (Hb j vm).
     destruct (build_pexpr vm j) as (vm0,pe0); intro IH.
     generalize (Hb k vm0); clear Hb.
     destruct (build_pexpr vm0 k) as (vm1,pe1); intro IH'.
     simpl in Ht;unfold is_true in Ht;rewrite !andb_true_iff in Ht;
       decompose [and] Ht;clear Ht.
     intros Heq Hwf;inversion Heq;clear Heq;subst.
     assert (W:= IH _ _ H (refl_equal _) Hwf);clear IH.
     decompose [and] W;clear W.
     assert (W:= IH' _ _ H0 (refl_equal _) H1);clear IH'.
     decompose [and] W;clear W.
     destruct H5;repeat split;trivial.
     apply le_trans with (1:= H3);trivial.
     intros p Hlt;rewrite H2, H7;trivial.
     apply lt_le_trans with (1:=Hlt);trivial.
     simpl;rewrite H9, andb_true_r.
     apply (bounded_pexpr_le (fst vm0));auto with arith.
     simpl;rewrite H6, H11;simpl.
     rewrite (interp_pexpr_le _ _ H7 _ H4);trivial.
Qed.
Transparent build_z_atom.

   Lemma build_pexpr_correct_aux :
        forall h vm vm' pe,
          (to_Z h < to_Z (length t_atom))%Z ->
          Typ.eqb (get_type t_i t_func t_atom h) Typ.TZ ->
          build_pexpr vm h = (vm',pe) ->
          wf_vmap vm ->
          wf_vmap vm' /\
          (nat_of_P (fst vm) <= nat_of_P (fst vm'))%nat /\
          (forall p,
           (nat_of_P p < nat_of_P (fst vm))%nat ->
           nth_error (snd vm) (nat_of_P (fst vm - p) - 1) =
           nth_error (snd vm')(nat_of_P (fst vm' - p) - 1)) /\
          bounded_pexpr (fst vm') pe /\
          t_interp.[h] = Bval t_i Typ.TZ (Zeval_expr (interp_vmap vm') pe).
   Proof.
     unfold build_pexpr.
     apply foldi_ind.
     apply leb_0.
     intros h vm vm' pe Hh.
     assert (W:=to_Z_bounded h);rewrite to_Z_0 in Hh.
     elimtype False;lia.
     intros i cont Hpos Hlen Hrec.
     intros h vm vm' pe;unfold is_true;rewrite <-ltb_spec;intros.
     rewrite t_interp_wf;trivial.
     apply build_pexpr_atom_aux_correct with cont h (i + 1);trivial.
     intros;apply Hrec;auto.
     unfold is_true in H3;rewrite ltb_spec in H, H3, Hlen; rewrite to_Z_add_1_wB in H; generalize (to_Z_bounded (length t_atom)); lia.
     unfold wf, is_true in wf_t_atom.
     rewrite aforallbi_spec in wf_t_atom.
     apply wf_t_atom.
     rewrite ltb_spec in H, Hlen;rewrite ltb_spec; rewrite to_Z_add_1_wB in H; generalize (to_Z_bounded (length t_atom)); lia.
     unfold wt, is_true in wt_t_atom.
     rewrite aforallbi_spec in wt_t_atom.
     change (is_true(Typ.eqb (get_type t_i t_func t_atom h) Typ.TZ)) in H0.
     rewrite Typ.eqb_spec in H0;rewrite <- H0.
     apply wt_t_atom.
     rewrite ltb_spec in H, Hlen; rewrite ltb_spec; rewrite to_Z_add_1_wB in H; generalize (to_Z_bounded (length t_atom)); lia.
   Qed.

   Lemma build_pexpr_correct :
        forall h vm vm' pe,
          Typ.eqb (get_type t_i t_func t_atom h) Typ.TZ ->
          build_pexpr vm h = (vm',pe) ->
          wf_vmap vm ->
          wf_vmap vm' /\
          (nat_of_P (fst vm) <= nat_of_P (fst vm'))%nat /\
          (forall p,
           (nat_of_P p < nat_of_P (fst vm))%nat ->
           nth_error (snd vm) (nat_of_P (fst vm - p) - 1) =
           nth_error (snd vm')(nat_of_P (fst vm' - p) - 1)) /\
          bounded_pexpr (fst vm') pe /\
          t_interp.[h] = Bval t_i Typ.TZ (Zeval_expr (interp_vmap vm') pe).
   Proof.
     intros.
     case_eq (h < length t_atom);intros.
     apply build_pexpr_correct_aux;trivial.
     rewrite <- ltb_spec;trivial.
     revert H;unfold get_type,get_type'.
     rewrite PArray.get_outofbound, default_t_interp.
     revert H0.
     unfold build_pexpr.
     apply foldi_ind.
     apply leb_0.
     discriminate.
     intros i a _ Hi IH.
     rewrite PArray.get_outofbound by exact H2.
     Opaque build_z_atom.
     rewrite def_t_atom; simpl.
     intros HH H.
     revert HH H1.
     apply build_pexpr_atom_aux_correct_z; trivial.
     rewrite length_t_interp;trivial.
   Qed.
Transparent build_z_atom.

   Lemma build_pexpr_atom_correct :
      forall a vm vm' pe,
          check_atom a Typ.TZ ->
          build_pexpr_atom_aux build_pexpr vm a = (vm',pe) ->
          wf_vmap vm ->
          wf_vmap vm' /\
          (nat_of_P (fst vm) <= nat_of_P (fst vm'))%nat /\
          (forall p,
           (nat_of_P p < nat_of_P (fst vm))%nat ->
           nth_error (snd vm) (nat_of_P (fst vm - p) - 1) =
           nth_error (snd vm')(nat_of_P (fst vm' - p) - 1)) /\
          bounded_pexpr (fst vm') pe /\
          interp_atom a = Bval t_i Typ.TZ (Zeval_expr (interp_vmap vm') pe).
    Proof.
      apply build_pexpr_atom_aux_correct';apply build_pexpr_correct.
    Qed.

   Lemma build_formula_atom_correct :
        forall a vm vm' f t,
          check_atom a t ->
          build_formula_atom vm a = Some (vm',f) ->
          wf_vmap vm ->
          wf_vmap vm' /\
          (nat_of_P (fst vm) <= nat_of_P (fst vm'))%nat /\
          (forall p,
           (nat_of_P p < nat_of_P (fst vm))%nat ->
           nth_error (snd vm) (nat_of_P (fst vm - p) - 1) =
           nth_error (snd vm')(nat_of_P (fst vm' - p) - 1)) /\
          bounded_formula (fst vm') f /\
          (interp_bool t_i (interp_atom a) <->Zeval_formula (interp_vmap vm') isProp f).
    Proof.
      intros a vm vm' f t.
      destruct a;simpl;try discriminate.
      case_eq (build_op2 b);try discriminate.
      intros o Heq Ht.
      assert (Typ.eqb Typ.Tbool t && Typ.eqb (get_type t_i t_func t_atom i) Typ.TZ && Typ.eqb (get_type t_i t_func t_atom i0) Typ.TZ).
        destruct b;try discriminate;trivial.
        destruct t0;try discriminate;trivial.
      unfold is_true in H;rewrite !andb_true_iff in H;decompose [and] H;clear H.
      case_eq (build_pexpr vm i);intros vm0 pe1 Heq1.
      case_eq (build_pexpr vm0 i0);intros vm1 pe2 Heq2.
      intros H Hwf;inversion H;clear H;subst.
      assert (W1:= build_pexpr_correct _ _ _ _ H3 Heq1 Hwf).
      decompose [and] W1;clear W1.
      assert (W1:= build_pexpr_correct _ _ _ _ H1 Heq2 H).
      decompose [and] W1;clear W1.
      split;trivial.
      split;[ apply le_trans with (1:= H4);trivial | ].
      split.
       intros p Hlt;rewrite H0, H8;trivial.
       apply lt_le_trans with (1:= Hlt);trivial.
      split.
       unfold bounded_formula;simpl;rewrite H10, andb_true_r.
       apply (bounded_pexpr_le (fst vm0));auto with arith.
      rewrite (interp_pexpr_le _ _ H8 _ H5) in H7.
      rewrite H7,H12;destruct b;try discriminate;simpl in Heq |- *;
      inversion Heq;clear Heq;subst;simpl.
      symmetry;apply Zlt_is_lt_bool.
      rewrite Zle_is_le_bool;tauto.
      rewrite Zge_iff_le.
        unfold Zge_bool;rewrite <- Zcompare_antisym.
        rewrite Zle_is_le_bool;unfold Zle_bool.
        destruct
          (Zeval_expr (interp_vmap vm') pe2 ?= Zeval_expr (interp_vmap vm') pe1)%Z;
          simpl;tauto.
      symmetry;apply Zgt_is_gt_bool.
      destruct t0;inversion H13;clear H13;subst.
      simpl.
      apply (Z.eqb_eq (Zeval_expr (interp_vmap vm') pe1) (Zeval_expr (interp_vmap vm') pe2)).
    Qed.

    Lemma build_formula_correct :
       forall h' vm vm' f,
          build_formula vm h' = Some (vm',f) ->
          wf_vmap vm ->
          wf_vmap vm' /\
          (nat_of_P (fst vm) <= nat_of_P (fst vm'))%nat /\
          (forall p,
           (nat_of_P p < nat_of_P (fst vm))%nat ->
           nth_error (snd vm) (nat_of_P (fst vm - p) - 1) =
           nth_error (snd vm')(nat_of_P (fst vm' - p) - 1)) /\
          bounded_formula (fst vm') f /\
          (interp_form_hatom h' <-> Zeval_formula (interp_vmap vm') isProp f).
    Proof.
      unfold build_formula;intros h.
      unfold Atom.interp_form_hatom, Atom.interp_hatom.
      rewrite t_interp_wf;trivial.
      intros;apply build_formula_atom_correct with
        (get_type t_i t_func t_atom h);trivial.
      unfold wt, is_true in wt_t_atom;rewrite aforallbi_spec in wt_t_atom.
      case_eq (h < length t_atom);intros Heq;unfold get_type;auto with smtcoq_core.
      unfold get_type'.
      rewrite !PArray.get_outofbound, default_t_interp, def_t_atom;trivial; try reflexivity.
      rewrite length_t_interp;trivial.
    Qed.


    Local Notation eval_f := (eval_f (fun k x => x)).

    Lemma build_not2_pos_correct : forall vm (f:GFormula isProp) l i,
      bounded_bformula (fst vm) f -> (rho (Lit.blit l) <-> eval_f (Zeval_formula (interp_vmap vm)) f) -> Lit.is_pos l -> bounded_bformula (fst vm) (build_not2 i f) /\ (Form.interp interp_form_hatom interp_form_hatom_bv t_form (Form.Fnot2 i l) <-> eval_f (Zeval_formula (interp_vmap vm)) (build_not2 i f)).
    Proof.
      simpl; intros vm f l i H1 H2 H3; unfold build_not2.
      case (Z.le_gt_cases 1 [|i|]); [ intro Hle | intro Hlt ].
      set (a := foldi _ _ _ _); set (b := foldi _ _ _ _); pattern i, a, b; subst a b; apply foldi_ind2.
      apply leb_0.
      unfold Lit.interp; rewrite H3; auto.
      intros j f' b _ _; rewrite negb_involutive; simpl.
      intros [ H H' ]; rewrite <- H'.
      unfold is_true; rewrite not_true_iff_false, not_false_iff_true; tauto.
      rewrite 2!foldi_ge by (rewrite leb_spec, to_Z_0; lia).
      unfold Lit.interp; rewrite H3; auto.
    Qed.


    Lemma build_not2_neg_correct : forall vm (f:GFormula isProp) l i,
      bounded_bformula (fst vm) f -> (rho (Lit.blit l) <-> eval_f (Zeval_formula (interp_vmap vm)) f) -> Lit.is_pos l = false -> bounded_bformula (fst vm) (NOT (build_not2 i f)) /\ (Form.interp interp_form_hatom interp_form_hatom_bv t_form (Form.Fnot2 i l) <-> eval_f (Zeval_formula (interp_vmap vm)) (NOT (build_not2 i f))).
    Proof.
      simpl; intros vm f l i H1 H2 H3; unfold build_not2.
      case (Z.le_gt_cases 1 [|i|]); [ intro Hle | intro Hlt ].
      set (a := foldi _ _ _ _); set (b := foldi _ _ _ _); pattern i, a, b; subst a b; apply foldi_ind2.
      apply leb_0.
      unfold Lit.interp; rewrite H3, <- H2; unfold is_true; rewrite negb_true_iff, not_true_iff_false; tauto.
      intros j f' b _ _; rewrite negb_involutive; simpl.
      intros [ H H' ]; rewrite <- H'.
      unfold is_true; rewrite not_true_iff_false, not_false_iff_true; tauto.
      rewrite 2!foldi_ge by (rewrite leb_spec, to_Z_0; lia).
      unfold Lit.interp; rewrite H3, <- H2; unfold is_true; rewrite negb_true_iff, not_true_iff_false; tauto.
    Qed.


    Lemma bounded_bformula_le :
     forall p p',
       (nat_of_P p <= nat_of_P p')%nat ->
        forall (bf:BFormula (Formula Z) isProp),
        bounded_bformula p bf -> bounded_bformula p' bf.
    Proof.
      unfold is_true;induction bf;simpl;trivial.
      - destruct a;unfold bounded_formula;simpl.
        rewrite andb_true_iff;intros (H1, H2).
        rewrite (bounded_pexpr_le _ _ H _ H1), (bounded_pexpr_le _ _ H _ H2);trivial.
      - rewrite !andb_true_iff;intros (H1, H2);auto.
      - rewrite !andb_true_iff;intros (H1, H2);auto.
      - rewrite !andb_true_iff;intros (H1, H2);auto.
      - rewrite !andb_true_iff;intros (H1, H2);auto.
      - rewrite !andb_true_iff;intros (H1, H2);auto.
    Qed.

    Section Interp_bformula.

      Variables vm vm' : positive * list atom.
      Variable Hnth : forall p : positive,
          (Pos.to_nat p < Pos.to_nat (fst vm))%nat ->
          nth_error (snd vm) (Pos.to_nat (fst vm - p) - 1) =
          nth_error (snd vm') (Pos.to_nat (fst vm' - p) - 1).

      Definition P k : GFormula k -> Prop :=
        match k as k return GFormula k -> Prop with
        | isProp => fun (bf:BFormula (Formula Z) isProp) =>
                      bounded_bformula (fst vm) bf ->
                      (eval_f (Zeval_formula (interp_vmap vm)) bf <->
                       eval_f (Zeval_formula (interp_vmap vm')) bf)
        | isBool => fun (bf:BFormula (Formula Z) isBool) =>
                      bounded_bformula (fst vm) bf ->
                      (eval_f (Zeval_formula (interp_vmap vm)) bf =
                       eval_f (Zeval_formula (interp_vmap vm')) bf)
        end.

      Lemma interp_bformula_le_gen : forall k f, P k f.
      Proof.
        intro k. induction f as [k|k|k t|k t a|k f1 IHf1 f2 IHf2|k f1 IHf1 f2 IHf2|k f1 IHf1|k f1 IHf1 o f2 IHf2|k f1 IHf1 f2 IHf2|f1 IHf1 f2 IHf2]; unfold P in *;
                   try (destruct k; simpl; tauto);
                   try (destruct k; simpl; unfold is_true;rewrite andb_true_iff;intros (H1,H2);rewrite IHf1, IHf2;tauto).
        - destruct k; simpl;
            destruct t;unfold bounded_formula;simpl;
              unfold is_true;rewrite andb_true_iff;intros (H1, H2);
                rewrite !(interp_pexpr_le _ _ Hnth);tauto.
        - destruct k; simpl; intro H; now rewrite IHf1.
        - destruct k; simpl.
          + unfold is_true;rewrite andb_true_iff;intros (H1, H2).
            split.
            * intros H3 H4. rewrite <- IHf2; auto. apply H3. now rewrite IHf1.
            * intros H3 H4. rewrite IHf2; auto. apply H3. now rewrite <- IHf1.
          + unfold is_true;rewrite andb_true_iff;intros (H1, H2).
            now rewrite IHf1, IHf2.
        - simpl. unfold is_true;rewrite andb_true_iff;intros (H1, H2).
          now rewrite IHf1, IHf2.
      Qed.

      Lemma interp_bformula_le :
        forall (bf:BFormula (Formula Z) isProp),
          bounded_bformula (fst vm) bf ->
          (eval_f (Zeval_formula (interp_vmap vm)) bf <->
           eval_f (Zeval_formula (interp_vmap vm')) bf).
      Proof. exact (interp_bformula_le_gen isProp). Qed.

    End Interp_bformula.


    Lemma build_hform_correct :
      forall (build_var : vmap -> var -> option (vmap*BFormula (Formula Z) isProp)),
        (forall v vm vm' bf,
          build_var vm v = Some (vm', bf) ->
          wf_vmap vm ->
          wf_vmap vm' /\
          (nat_of_P (fst vm) <= nat_of_P (fst vm'))%nat /\
          (forall p,
            (nat_of_P p < nat_of_P (fst vm))%nat ->
            nth_error (snd vm) (nat_of_P (fst vm - p) - 1) =
            nth_error (snd vm')(nat_of_P (fst vm' - p) - 1)) /\
          bounded_bformula (fst vm') bf /\
          (Var.interp rho v <-> eval_f (Zeval_formula (interp_vmap vm')) bf)) ->
        forall f vm vm' bf,
          build_hform build_var vm f = Some (vm', bf) ->
          wf_vmap vm ->
          wf_vmap vm' /\
          (nat_of_P (fst vm) <= nat_of_P (fst vm'))%nat /\
          (forall p,
            (nat_of_P p < nat_of_P (fst vm))%nat ->
            nth_error (snd vm) (nat_of_P (fst vm - p) - 1) =
            nth_error (snd vm')(nat_of_P (fst vm' - p) - 1)) /\
          bounded_bformula (fst vm') bf /\
          (Form.interp interp_form_hatom interp_form_hatom_bv t_form f <-> eval_f (Zeval_formula (interp_vmap vm')) bf).
    Proof.
      unfold build_hform; intros build_var Hbv [h| | |i l|l|l|l|a b|a b|a b c|a ls] vm vm' bf; try discriminate.
      (* Fatom *)
      case_eq (build_formula vm h); try discriminate; intros [vm0 f] Heq H1 H2; inversion H1; subst vm0; subst bf; apply build_formula_correct; auto.
      (* Ftrue *)
      intros H H1; inversion H; subst vm'; subst bf; split; auto; split; [lia| ]; do 4 split; auto.
      (* Ffalse *)
      intros H H1; inversion H; subst vm'; subst bf; split; auto; split; [lia| ]; do 3 (split; auto with smtcoq_core); discriminate.
      (* Fnot2 *)
      case_eq (build_var vm (Lit.blit l)); try discriminate; intros [vm0 f] Heq H H1; inversion H; subst vm0; subst bf; destruct (Hbv _ _ _ _ Heq H1) as [H2 [H3 [H4 [H5 H6]]]]; do 3 (split; auto); case_eq (Lit.is_pos l); [apply build_not2_pos_correct|apply build_not2_neg_correct]; auto.
      (* Fand *)
      simpl; unfold afold_left; rewrite !length_amap; case_eq (length l == 0); [ rewrite Int63.eqb_spec | rewrite eqb_false_spec, not_0_ltb ]; intro Hl.
      intro H; inversion H; subst vm'; subst bf; simpl; intro H1; split; auto with smtcoq_core; split; [lia| ]; do 3 (split; auto with smtcoq_core).
      revert vm' bf; rewrite !get_amap by exact Hl; set (a := foldi _ _ _ _); set (b := foldi _ _ _ _); pattern (length l), a, b; subst a b; apply foldi_ind2.
      rewrite ltb_spec, to_Z_0 in Hl; rewrite leb_spec, to_Z_1; lia.
      intros vm' bf; case_eq (build_var vm (Lit.blit (l .[ 0]))); try discriminate; intros [vm0 f] Heq; case_eq (Lit.is_pos (l .[ 0])); intros Heq2 H1 H2; inversion H1; subst vm'; subst bf; destruct (Hbv _ _ _ _ Heq H2) as [H10 [H11 [H12 [H13 H14]]]]; do 4 (split; auto); unfold Lit.interp; rewrite Heq2; auto; simpl; split.
      intros H3 H4; rewrite <- H14 in H4; rewrite H4 in H3; discriminate.
      intro H3; case_eq (Var.interp rho (Lit.blit (l .[ 0]))); auto; intro H4; elim H3; rewrite <- H14; auto.
      intros i a b _ H1; case (a vm); try discriminate; intros [vm0 f0] IH vm' bf; rewrite get_amap by exact H1; case_eq (build_var vm0 (Lit.blit (l .[ i]))); try discriminate; intros [vm1 f1] Heq H2 H3; inversion H2; subst vm'; subst bf; destruct (IH _ _ (refl_equal (Some (vm0, f0))) H3) as [H5 [H6 [H7 [H8 H9]]]]; destruct (Hbv _ _ _ _ Heq H5) as [H10 [H11 [H12 [H13 H14]]]]; split; auto; split; [eauto with arith| ]; split.
      intros p H15; rewrite H7; auto; apply H12; eauto with arith.
      split.
      simpl; rewrite (bounded_bformula_le _ _ H11 _ H8); case (Lit.is_pos (l .[ i])); rewrite H13; auto with smtcoq_core.
      simpl; rewrite (interp_bformula_le _ _ H12 _ H8) in H9; rewrite <- H9; rewrite get_amap by exact H1; case_eq (Lit.is_pos (l .[ i])); intro Heq2; simpl; rewrite <- H14; unfold Lit.interp; rewrite Heq2; split; case (Var.interp rho (Lit.blit (l .[ i]))); try rewrite andb_true_r; try rewrite andb_false_r; try (intros; split; auto with smtcoq_core); try discriminate; intros [H20 H21]; auto with smtcoq_core.
      (* For *)
      simpl; unfold afold_left; rewrite !length_amap; case_eq (length l == 0); [ rewrite Int63.eqb_spec | rewrite eqb_false_spec, not_0_ltb ]; intro Hl.
      intro H; inversion H; subst vm'; subst bf; simpl; intro H1; split; auto with smtcoq_core; split; [lia| ]; do 3 (split; auto with smtcoq_core); discriminate.
      revert vm' bf; rewrite !get_amap by exact Hl; set (a := foldi _ _ _ _); set (b := foldi _ _ _ _); pattern (length l), a, b; subst a b; apply foldi_ind2.
      rewrite ltb_spec, to_Z_0 in Hl; rewrite leb_spec, to_Z_1; lia.
      intros vm' bf; case_eq (build_var vm (Lit.blit (l .[ 0]))); try discriminate; intros [vm0 f] Heq; case_eq (Lit.is_pos (l .[ 0])); intros Heq2 H1 H2; inversion H1; subst vm'; subst bf; destruct (Hbv _ _ _ _ Heq H2) as [H10 [H11 [H12 [H13 H14]]]]; do 4 (split; auto with smtcoq_core); unfold Lit.interp; rewrite Heq2; auto with smtcoq_core; simpl; split.
      intros H3 H4; rewrite <- H14 in H4; rewrite H4 in H3; discriminate.
      intro H3; case_eq (Var.interp rho (Lit.blit (l .[ 0]))); auto with smtcoq_core; intro H4; elim H3; rewrite <- H14; auto with smtcoq_core.
      intros i a b _ H1; case (a vm); try discriminate; intros [vm0 f0] IH vm' bf; rewrite get_amap by exact H1; case_eq (build_var vm0 (Lit.blit (l .[ i]))); try discriminate; intros [vm1 f1] Heq H2 H3; inversion H2; subst vm'; subst bf; destruct (IH _ _ (refl_equal (Some (vm0, f0))) H3) as [H5 [H6 [H7 [H8 H9]]]]; destruct (Hbv _ _ _ _ Heq H5) as [H10 [H11 [H12 [H13 H14]]]]; split; auto with smtcoq_core; split; [eauto with smtcoq_core arith| ]; split.
      intros p H15; rewrite H7; auto with smtcoq_core; apply H12; eauto with smtcoq_core arith.
      split.
      simpl; rewrite (bounded_bformula_le _ _ H11 _ H8); case (Lit.is_pos (l .[ i])); rewrite H13; auto with smtcoq_core.
      simpl; rewrite (interp_bformula_le _ _ H12 _ H8) in H9; rewrite <- H9; rewrite get_amap by exact H1; case_eq (Lit.is_pos (l .[ i])); intro Heq2; simpl; rewrite <- H14; unfold Lit.interp; rewrite Heq2; split; case (Var.interp rho (Lit.blit (l .[ i]))); try rewrite orb_false_r; try rewrite orb_true_r; auto with smtcoq_core; try (intros [H20|H20]; auto with smtcoq_core; discriminate); right; intro H20; discriminate.
      (* Fimp *)
      {
      simpl; unfold afold_right; rewrite !length_amap; case_eq (length l == 0); [ rewrite Int63.eqb_spec | rewrite eqb_false_spec, not_0_ltb ]; intro Hl.
      intro H; inversion H; subst vm'; subst bf; simpl; intro H1; split; auto with smtcoq_core; split; [lia| ]; do 3 (split; auto with smtcoq_core).
      revert vm' bf; rewrite !get_amap by (apply minus_1_lt; rewrite eqb_false_spec, not_0_ltb; exact Hl); set (a := foldi _ _ _ _); set (b := foldi _ _ _ _); pattern (length l), a, b; subst a b; apply foldi_ind2.
      rewrite ltb_spec, to_Z_0 in Hl; rewrite leb_spec, to_Z_1; lia.
      intros vm' bf; case_eq (build_var vm (Lit.blit (l .[ length l - 1]))); try discriminate; intros [vm0 f] Heq; case_eq (Lit.is_pos (l .[ length l - 1])); intros Heq2 H1 H2; inversion H1; subst vm'; subst bf; destruct (Hbv _ _ _ _ Heq H2) as [H10 [H11 [H12 [H13 H14]]]]; do 4 (split; auto with smtcoq_core); unfold Lit.interp; rewrite Heq2; auto with smtcoq_core; simpl; split.
      intros H3 H4; rewrite <- H14 in H4; rewrite H4 in H3; discriminate.
      intro H3; case_eq (Var.interp rho (Lit.blit (l .[ length l - 1]))); auto with smtcoq_core; intro H4; elim H3; rewrite <- H14; auto with smtcoq_core.
      intros i a b _ H1.
      rewrite get_amap by (pose proof (to_Z_bounded i); pose proof (to_Z_bounded (length l)); revert H1 Hl; rewrite !ltb_spec, to_Z_0; intros; rewrite sub_spec, to_Z_sub_1_0, Z.mod_small; lia).
      rewrite get_amap by (pose proof (to_Z_bounded i); pose proof (to_Z_bounded (length l)); revert H1 Hl; rewrite !ltb_spec, to_Z_0; intros; rewrite sub_spec, to_Z_sub_1_0, Z.mod_small; lia).
      case a; try discriminate; intros [vm0 f0] IH vm' bf; case_eq (build_var vm0 (Lit.blit (l .[length l - 1 - i]))); try discriminate; intros [vm1 f1] Heq H2 H3; inversion H2; subst vm'; subst bf; destruct (IH _ _ (refl_equal (Some (vm0, f0))) H3) as [H5 [H6 [H7 [H8 H9]]]]; destruct (Hbv _ _ _ _ Heq H5) as [H10 [H11 [H12 [H13 H14]]]]; split; auto with smtcoq_core; split; [eauto with smtcoq_core arith| ]; split.
      intros p H15; rewrite H7; auto with smtcoq_core; apply H12; eauto with smtcoq_core arith.
      split.
      simpl; rewrite (bounded_bformula_le _ _ H11 _ H8); case (Lit.is_pos (l .[length l - 1 - i])); rewrite H13; auto with smtcoq_core.
      simpl; rewrite (interp_bformula_le _ _ H12 _ H8) in H9.
      case_eq (Lit.is_pos (l .[length l - 1 - i])); intro Heq2; simpl.
      - unfold Lit.interp. rewrite Heq2. split.
        + revert H14. case (Var.interp rho (Lit.blit (l .[ length l - 1 - i]))); simpl.
          * intros H101 H102 H103. now rewrite <- H9.
          * intros H101 H102 H103. rewrite <- H101 in H103. discriminate.
        + revert H14. case (Var.interp rho (Lit.blit (l .[ length l - 1 - i]))); simpl; auto.
          intros H101 H102. rewrite H9. apply H102. now rewrite <- H101.
      - unfold Lit.interp. rewrite Heq2. split.
        + revert H14. case (Var.interp rho (Lit.blit (l .[ length l - 1 - i]))); simpl.
          * intros H101 H102 H103. elim H103. now rewrite <- H101.
          * intros H101 H102 H103. now rewrite <- H9.
        + revert H14. case (Var.interp rho (Lit.blit (l .[ length l - 1 - i]))); simpl; auto.
          intros H101 H102. rewrite H9. apply H102. now rewrite <- H101.
      }
      (* Fxor *)
      simpl; case_eq (build_var vm (Lit.blit a)); try discriminate; intros [vm1 f1] Heq1; case_eq (build_var vm1 (Lit.blit b)); try discriminate; intros [vm2 f2] Heq2 H1 H2; inversion H1; subst vm'; subst bf; destruct (Hbv _ _ _ _ Heq1 H2) as [H3 [H4 [H5 [H6 H7]]]]; destruct (Hbv _ _ _ _ Heq2 H3) as [H8 [H9 [H10 [H11 H12]]]]; split; auto with smtcoq_core; split; [eauto with smtcoq_core arith| ]; split.
      intros p H18; rewrite H5; auto with smtcoq_core; rewrite H10; eauto with smtcoq_core arith.
      split.
      case (Lit.is_pos a); case (Lit.is_pos b); simpl; rewrite H11; rewrite (bounded_bformula_le _ _ H9 _ H6); auto with smtcoq_core.
      simpl; rewrite (interp_bformula_le _ _ H10 _ H6) in H7; case_eq (Lit.is_pos a); intro Ha; case_eq (Lit.is_pos b); intro Hb; unfold Lit.interp; rewrite Ha, Hb; simpl; rewrite <- H12; rewrite <- H7; (case (Var.interp rho (Lit.blit a)); case (Var.interp rho (Lit.blit b))); split; auto with smtcoq_core; try discriminate; simpl; intuition.
      (* Fiff *)
      simpl; case_eq (build_var vm (Lit.blit a)); try discriminate; intros [vm1 f1] Heq1; case_eq (build_var vm1 (Lit.blit b)); try discriminate; intros [vm2 f2] Heq2 H1 H2; inversion H1; subst vm'; subst bf; destruct (Hbv _ _ _ _ Heq1 H2) as [H3 [H4 [H5 [H6 H7]]]]; destruct (Hbv _ _ _ _ Heq2 H3) as [H8 [H9 [H10 [H11 H12]]]]; split; auto with smtcoq_core; split; [eauto with smtcoq_core arith| ]; split.
      intros p H18; rewrite H5; auto with smtcoq_core; rewrite H10; eauto with smtcoq_core arith.
      split.
      case (Lit.is_pos a); case (Lit.is_pos b); simpl; rewrite H11; rewrite (bounded_bformula_le _ _ H9 _ H6); auto with smtcoq_core.
      simpl; rewrite (interp_bformula_le _ _ H10 _ H6) in H7; case_eq (Lit.is_pos a); intro Ha; case_eq (Lit.is_pos b); intro Hb; unfold Lit.interp; rewrite Ha, Hb; simpl; rewrite <- H12; rewrite <- H7; (case (Var.interp rho (Lit.blit a)); case (Var.interp rho (Lit.blit b))); split; auto with smtcoq_core; try discriminate; simpl; intuition.
      (* Fite *)
      simpl; case_eq (build_var vm (Lit.blit a)); try discriminate; intros [vm1 f1] Heq1; case_eq (build_var vm1 (Lit.blit b)); try discriminate; intros [vm2 f2] Heq2; case_eq (build_var vm2 (Lit.blit c)); try discriminate; intros [vm3 f3] Heq3 H1 H2; inversion H1; subst vm'; subst bf; destruct (Hbv _ _ _ _ Heq1 H2) as [H3 [H4 [H5 [H6 H7]]]]; destruct (Hbv _ _ _ _ Heq2 H3) as [H8 [H9 [H10 [H11 H12]]]]; destruct (Hbv _ _ _ _ Heq3 H8) as [H13 [H14 [H15 [H16 H17]]]]; split; auto with smtcoq_core; split; [eauto with smtcoq_core arith| ]; split.
      intros p H18; rewrite H5; auto with smtcoq_core; rewrite H10; eauto with smtcoq_core arith.
      assert (H18: (Pos.to_nat (fst vm1) <= Pos.to_nat (fst vm3))%nat) by eauto with smtcoq_core arith.
      split.
      case (Lit.is_pos a); case (Lit.is_pos b); case (Lit.is_pos c); simpl; rewrite H16; rewrite (bounded_bformula_le _ _ H14 _ H11); rewrite (bounded_bformula_le _ _ H18 _ H6); auto with smtcoq_core.
      simpl; rewrite (interp_bformula_le _ _ H15 _ H11) in H12; rewrite (interp_bformula_le _ vm3) in H7; [ |intros p Hp; rewrite H10; eauto with smtcoq_core arith|auto with smtcoq_core]; case_eq (Lit.is_pos a); intro Ha; case_eq (Lit.is_pos b); intro Hb; case_eq (Lit.is_pos c); intro Hc; unfold Lit.interp; rewrite Ha, Hb, Hc; simpl; rewrite <- H17; rewrite <- H12; rewrite <- H7; (case (Var.interp rho (Lit.blit a)); [case (Var.interp rho (Lit.blit b))|case (Var.interp rho (Lit.blit c))]); split; auto with smtcoq_core; try discriminate; try (intros [[H20 H21]|[H20 H21]]; auto with smtcoq_core); try (intros _; left; split; auto with smtcoq_core; discriminate); try (intros _; right; split; auto with smtcoq_core; discriminate); try (elim H20; discriminate); try (elim H21; discriminate); try (simpl; intro H; left; split; auto with smtcoq_core; discriminate); try (revert H; case (Var.interp rho (Lit.blit c)); discriminate); try (revert H; case (Var.interp rho (Lit.blit b)); discriminate); try (intro H20; rewrite H20 in H; discriminate); simpl.
      intro H; right; split; auto with smtcoq_core.
      intro H; right; split; auto with smtcoq_core.
      intro H; right; split; auto with smtcoq_core.
      intro H20; rewrite H20 in H; discriminate.
      revert H21; case (Var.interp rho (Lit.blit c)); auto with smtcoq_core.
      right; split; auto with smtcoq_core; intro H20; rewrite H20 in H; discriminate.
      revert H21; case (Var.interp rho (Lit.blit c)); auto with smtcoq_core.
      intro H; right; split; auto with smtcoq_core.
      intro H; right; split; auto with smtcoq_core.
      intro H; left; split; try discriminate; revert H; case (Var.interp rho (Lit.blit b)); discriminate.
      revert H21; case (Var.interp rho (Lit.blit b)); auto with smtcoq_core.
      intro H; left; split; try discriminate; revert H; case (Var.interp rho (Lit.blit b)); discriminate.
      revert H21; case (Var.interp rho (Lit.blit b)); auto with smtcoq_core.
      intro H; right; split; auto with smtcoq_core; revert H; case (Var.interp rho (Lit.blit c)); discriminate.
      revert H21; case (Var.interp rho (Lit.blit c)); auto with smtcoq_core.
      intro H; right; split; auto with smtcoq_core; revert H; case (Var.interp rho (Lit.blit c)); discriminate.
      revert H21; case (Var.interp rho (Lit.blit c)); auto with smtcoq_core.
      intro H; left; split; auto with smtcoq_core; revert H; case (Var.interp rho (Lit.blit b)); discriminate.
      revert H21; case (Var.interp rho (Lit.blit b)); auto with smtcoq_core.
      intro H; left; split; auto with smtcoq_core; revert H; case (Var.interp rho (Lit.blit b)); discriminate.
      revert H21; case (Var.interp rho (Lit.blit b)); auto with smtcoq_core.
    Qed.


    Lemma build_var_correct : forall v vm vm' bf,
      build_var vm v = Some (vm', bf) ->
      wf_vmap vm ->
      wf_vmap vm' /\
      (nat_of_P (fst vm) <= nat_of_P (fst vm'))%nat /\
      (forall p,
        (nat_of_P p < nat_of_P (fst vm))%nat ->
        nth_error (snd vm) (nat_of_P (fst vm - p) - 1) =
        nth_error (snd vm')(nat_of_P (fst vm' - p) - 1)) /\
      bounded_bformula (fst vm') bf /\
      (Var.interp rho v <-> eval_f (Zeval_formula (interp_vmap vm')) bf).
    Proof.
      unfold build_var; apply foldi_ind; try discriminate.
      apply leb_0.
      intros i cont _ Hlen Hrec v vm vm' bf; unfold is_true; intros H1 H2; replace (Var.interp rho v) with (Form.interp interp_form_hatom interp_form_hatom_bv t_form (t_form.[v])).
      apply (build_hform_correct cont); auto with smtcoq_core.
      unfold Var.interp; rewrite <- wf_interp_form; auto with smtcoq_core.
    Qed.


    Lemma build_form_correct : forall f vm vm' bf,
      build_form vm f = Some (vm', bf) ->
      wf_vmap vm ->
      wf_vmap vm' /\
      (nat_of_P (fst vm) <= nat_of_P (fst vm'))%nat /\
      (forall p,
        (nat_of_P p < nat_of_P (fst vm))%nat ->
        nth_error (snd vm) (nat_of_P (fst vm - p) - 1) =
        nth_error (snd vm')(nat_of_P (fst vm' - p) - 1)) /\
      bounded_bformula (fst vm') bf /\
      (Form.interp interp_form_hatom interp_form_hatom_bv t_form f <-> eval_f (Zeval_formula (interp_vmap vm')) bf).
    Proof. apply build_hform_correct; apply build_var_correct. Qed.


    Lemma build_nlit_correct : forall l vm vm' bf,
       build_nlit vm l = Some (vm', bf) ->
       wf_vmap vm ->
       wf_vmap vm' /\
       (nat_of_P (fst vm) <= nat_of_P (fst vm'))%nat /\
       (forall p,
           (nat_of_P p < nat_of_P (fst vm))%nat ->
           nth_error (snd vm) (nat_of_P (fst vm - p) - 1) =
           nth_error (snd vm')(nat_of_P (fst vm' - p) - 1)) /\
       bounded_bformula (fst vm') bf /\
       (negb (Lit.interp rho l) <-> eval_f (Zeval_formula (interp_vmap vm')) bf).
    Proof.
      unfold build_nlit; intros l vm vm' bf; case_eq (build_form vm (t_form .[ Lit.blit (Lit.neg l)])); try discriminate.
      intros [vm1 f] Heq H1 H2; inversion H1; subst vm1; subst bf; case_eq (Lit.is_pos (Lit.neg l)); intro Heq2.
      replace (negb (Lit.interp rho l)) with (Form.interp interp_form_hatom interp_form_hatom_bv t_form (t_form .[ Lit.blit (Lit.neg l)])).
      apply build_form_correct; auto with smtcoq_core.
      unfold Lit.interp; replace (Lit.is_pos l) with false.
      rewrite negb_involutive; unfold Var.interp; rewrite <- wf_interp_form; auto with smtcoq_core; rewrite Lit.blit_neg; auto with smtcoq_core.
      rewrite Lit.is_pos_neg in Heq2; case_eq (Lit.is_pos l); auto with smtcoq_core; intro H; rewrite H in Heq2; discriminate.
      simpl; destruct (build_form_correct (t_form .[ Lit.blit (Lit.neg l)]) vm vm' f Heq H2) as [H3 [H4 [H5 [H6 [H7 H8]]]]]; do 4 (split; auto with smtcoq_core); split.
      intros H9 H10; pose (H11 := H8 H10); unfold Lit.interp in H9; replace (Lit.is_pos l) with true in H9.
      unfold Var.interp in H9; rewrite <- wf_interp_form in H11; auto with smtcoq_core; rewrite Lit.blit_neg in H11; rewrite H11 in H9; discriminate.
       rewrite Lit.is_pos_neg in Heq2; case_eq (Lit.is_pos l); auto with smtcoq_core; intro H; rewrite H in Heq2; discriminate.
       intro H9; case_eq (Lit.interp rho l); intro Heq3; auto with smtcoq_core; elim H9; apply H7; unfold Lit.interp in Heq3; replace (Lit.is_pos l) with true in Heq3.
       unfold Var.interp in Heq3; rewrite <- wf_interp_form; auto with smtcoq_core; rewrite Lit.blit_neg; auto with smtcoq_core.
       rewrite Lit.is_pos_neg in Heq2; case_eq (Lit.is_pos l); auto with smtcoq_core; intro H; rewrite H in Heq2; discriminate.
    Qed.


    Lemma build_clause_aux_correct :
        forall cl vm vm' bf,
          build_clause_aux vm cl = Some (vm',bf) ->
          wf_vmap vm ->
          wf_vmap vm' /\
          (nat_of_P (fst vm) <= nat_of_P (fst vm'))%nat /\
          (forall p,
            (nat_of_P p < nat_of_P (fst vm))%nat ->
            nth_error (snd vm) (nat_of_P (fst vm - p) - 1) =
            nth_error (snd vm')(nat_of_P (fst vm' - p) - 1)) /\
          bounded_bformula (fst vm') bf /\
          (negb (C.interp rho cl) <-> eval_f (Zeval_formula (interp_vmap vm')) bf).
    Proof.
      induction cl;try discriminate.
      case_eq cl.
      intros _; simpl;intros;rewrite orb_false_r;apply build_nlit_correct;trivial.
      intros i l Heq vm vm' bf;rewrite <- Heq at 2.
      change (build_clause_aux vm (a :: i :: l) ) with
        ( match build_nlit vm a with
          | Some (vm0, bf1) =>
          match build_clause_aux vm0 (i::l) with
          | Some (vm1, bf2) => Some (vm1, AND bf1 bf2)
          | None => None
          end
         | None => None
         end).
      case_eq (build_nlit vm a);try discriminate.
      intros (vm0, bf1) Heq1 Heq2 Hwf.
      rewrite <- Heq in Heq2.
      assert (W:= build_nlit_correct _ _ _ _ Heq1 Hwf).
      decompose [and] W;clear W.
      revert Heq2; case_eq (build_clause_aux vm0 cl);try discriminate.
      intros (vm1, fb2) Heq2 W;inversion W;clear W Heq;subst.
      assert (W:= IHcl _ _ _ Heq2 H);decompose [and] W;clear W.
      split;trivial.
      split.
       apply le_trans with (1:= H1);trivial.
      split.
        intros p Hlt;rewrite H0, H5;trivial.
        apply lt_le_trans with (1:= Hlt);trivial.
      split.
       simpl;rewrite H7, andb_true_r.
       apply bounded_bformula_le with (2:= H2);trivial.
      simpl.
       unfold is_true;
       rewrite <- (interp_bformula_le _ _ H5), <- H4, <- H9, negb_orb,andb_true_iff;
       tauto.
    Qed.

   Lemma  build_clause_correct :
        forall cl vm vm' bf,
          build_clause vm cl = Some (vm',bf) ->
          wf_vmap vm ->
          wf_vmap vm' /\
          (nat_of_P (fst vm) <= nat_of_P (fst vm'))%nat /\
          (forall p,
            (nat_of_P p < nat_of_P (fst vm))%nat ->
            nth_error (snd vm) (nat_of_P (fst vm - p) - 1) =
            nth_error (snd vm')(nat_of_P (fst vm' - p) - 1)) /\
          bounded_bformula (fst vm') bf /\
          (C.interp rho cl <-> eval_f (Zeval_formula (interp_vmap vm')) bf).
   Proof.
    unfold build_clause;intros cl vm vm' bf.
    case_eq (build_clause_aux vm cl);try discriminate.
    intros (vm1, bf1) Heq W Hwf;inversion W;clear W;subst.
    assert (W:= build_clause_aux_correct _ _ _ _ Heq Hwf).
    decompose [and] W;clear W.
    repeat (split;[trivial;fail | ]).
    split;simpl.
    rewrite H2;reflexivity.
    unfold is_true in *;
       destruct (C.interp rho cl);split;simpl;trivial;try discriminate;
    try tauto.
    intros _ HH;destruct H4.
    apply H4 in HH;discriminate.
   Qed.

   Local Notation hinterp := (Atom.interp_hatom t_i t_func t_atom).
   Local Notation interp := (Atom.interp t_i t_func t_atom).

   Lemma get_eq_interp :
     forall (l:_lit) (f:Atom.hatom -> Atom.hatom -> C.t),
       (forall xa, t_form.[Lit.blit l] = Form.Fatom xa ->
         forall t a b, t_atom.[xa] = Atom.Abop (Atom.BO_eq t) a b ->
           Lit.is_pos l ->
           rho (Lit.blit l) =
           Atom.interp_bool t_i
           (Atom.apply_binop t_i t t Typ.Tbool (Typ.i_eqb t_i t)
             (hinterp a) (hinterp b)) ->
           Typ.eqb (get_type t_i t_func t_atom a) t -> Typ.eqb (get_type t_i t_func t_atom b) t ->
           C.interp rho (f a b)) ->
       C.interp rho (get_eq l f).
   Proof.
     intros l f Hf;unfold get_eq.
     destruct (Lit.is_pos l); case_eq (t_form.[Lit.blit l]);trivial;intros;
     try(case_eq (t_atom.[i]);trivial;intros); try (apply valid_C_true; trivial).
     destruct b; try (apply valid_C_true; trivial).
     generalize wt_t_atom;unfold Atom.wt;unfold is_true;
       rewrite aforallbi_spec;intros.
     assert (i < length t_atom).
     apply PArray.get_not_default_lt.
     rewrite H0, def_t_atom;discriminate.
     apply H1 in H2;clear H1;rewrite H0 in H2;simpl in H2.
     rewrite !andb_true_iff in H2;decompose [and] H2;clear H2.
     apply Hf with (2:= H0);trivial. auto with smtcoq_core.
     rewrite wf_interp_form, H;simpl.
     unfold Atom.interp_form_hatom, Atom.interp_hatom at 1;simpl.
     rewrite Atom.t_interp_wf, H0;simpl;trivial.
     trivial.
   Qed.

   Lemma get_not_le_interp :
     forall (l:_lit) (f:Atom.hatom -> Atom.hatom -> C.t),
       (forall xa, t_form.[Lit.blit l] = Form.Fatom xa ->
         forall a b, t_atom.[xa] = Atom.Abop Atom.BO_Zle a b ->
           negb (Lit.is_pos l) ->
           rho (Lit.blit l) =
           Atom.interp_bool t_i
           (Atom.apply_binop t_i Typ.TZ Typ.TZ Typ.Tbool Zle_bool
             (hinterp a) (hinterp b)) ->
           Typ.eqb (get_type t_i t_func t_atom a) Typ.TZ -> Typ.eqb (get_type t_i t_func t_atom b) Typ.TZ ->
           C.interp rho (f a b)) ->
       C.interp rho (get_not_le l f).
   Proof.
     intros l f Hf;unfold get_not_le.
     destruct (Lit.is_pos l); case_eq (t_form.[Lit.blit l]);trivial;intros;
     try(case_eq (t_atom.[i]);trivial;intros); try (apply valid_C_true; trivial).
     destruct b; try (apply valid_C_true; trivial).
     generalize wt_t_atom;unfold Atom.wt;unfold is_true;
       rewrite aforallbi_spec;intros.
     assert (i < length t_atom).
     apply PArray.get_not_default_lt.
     rewrite H0, def_t_atom;discriminate.
     apply H1 in H2;clear H1;rewrite H0 in H2;simpl in H2.
     rewrite !andb_true_iff in H2;decompose [and] H2;clear H2.
     simpl; apply Hf with (2:= H0);trivial. auto with smtcoq_core.
     rewrite wf_interp_form, H;simpl.
     unfold Atom.interp_form_hatom, Atom.interp_hatom at 1;simpl.
     rewrite Atom.t_interp_wf, H0;simpl;trivial.
     trivial.
   Qed.


   Lemma interp_binop_eqb_antisym:
     forall a b va vb,
       interp_atom a = Bval t_i Typ.TZ va -> interp_atom b = Bval t_i Typ.TZ vb ->
       (interp_bool t_i
         (apply_binop t_i Typ.TZ Typ.TZ Typ.Tbool (Typ.i_eqb t_i Typ.TZ)
           (interp a) (interp b)) = false) ->
       negb
       (interp_bool t_i
         (apply_binop t_i Typ.TZ Typ.TZ Typ.Tbool Z.leb
           (interp a) (interp b))) = false ->
       negb
       (interp_bool t_i
            (apply_binop t_i Typ.TZ Typ.TZ Typ.Tbool Z.leb
              (interp b) (interp a))) = false ->
       False.
   Proof.
     intros a b va vb HHa HHb.
     unfold Atom.interp, Atom.interp_hatom.
     rewrite HHa, HHb; simpl.
     intros.
     case_eq (va <=? vb)%Z; intros; subst.
     case_eq (vb <=? va)%Z; intros; subst.
     apply Zle_bool_imp_le in H2.
     apply Zle_bool_imp_le in H3.
     apply Z.eqb_neq in H.
     (*pour la beauté du geste!*) lia.
     rewrite H3 in H1; simpl in H1; elim diff_true_false; trivial.
     rewrite H2 in H0; simpl in H1; elim diff_true_false; trivial.
   Qed.


   Lemma valid_check_micromega :
     forall cl c, C.valid rho (check_micromega cl c).
   Proof.
     unfold check_micromega; intros cl c.
     case_eq (build_clause empty_vmap cl).
     intros (vm1, bf) Heq.
     destruct (build_clause_correct _ _ _ _ Heq).
      red;simpl;auto with smtcoq_core.
     decompose [and] H0.
     case_eq (ZTautoChecker bf c);intros Heq2.
     unfold C.valid;rewrite H5.
     apply ZTautoChecker_sound with c;trivial.
     apply C.interp_true.
     destruct (Form.check_form_correct interp_form_hatom interp_form_hatom_bv _ ch_form);trivial.
     intros _;apply C.interp_true.
     destruct (Form.check_form_correct interp_form_hatom interp_form_hatom_bv _ ch_form);trivial.
   Qed.


   Lemma valid_check_diseq :
     forall c, C.valid rho (check_diseq c).
   Proof.
     unfold check_diseq; intro c.
     case_eq (t_form.[Lit.blit c]);intros;subst; try (unfold C.valid; apply valid_C_true; trivial).
     case_eq ((length a) == 3); intros; try (unfold C.valid; apply valid_C_true; trivial).
     apply eqb_correct in H0.
     apply get_eq_interp; intros.
     apply get_not_le_interp; intros.
     apply get_not_le_interp; intros.
     case_eq ((a0 == a1) && (a0 == b1) && (b == b0) && (b == a2)); intros; subst;
       try (unfold C.valid; apply valid_C_true; trivial).
     repeat(apply andb_prop in H19; destruct H19).
     apply Int63.eqb_spec in H19;apply Int63.eqb_spec in H20;apply Int63.eqb_spec in H21;apply Int63.eqb_spec in H22; subst a0 b.
     unfold C.interp; simpl; rewrite orb_false_r.
     unfold Lit.interp; rewrite Lit.is_pos_lit.
     unfold Var.interp; rewrite Lit.blit_lit.
     rewrite wf_interp_form, H;simpl.
     case_eq (Lit.interp rho (a.[0]) || Lit.interp rho (a.[1]) || Lit.interp rho (a.[2])).
     intros;repeat (rewrite orb_true_iff in H19);destruct H19. destruct H19.
     apply (afold_left_orb_true 0); rewrite ?length_amap, ?get_amap; [ rewrite H0; reflexivity | assumption | rewrite H0; reflexivity ].
     apply (afold_left_orb_true 1); rewrite ?length_amap, ?get_amap; [ rewrite H0; reflexivity | assumption | rewrite H0; reflexivity ].
     apply (afold_left_orb_true 2); rewrite ?length_amap, ?get_amap; [ rewrite H0; reflexivity | assumption | rewrite H0; reflexivity ].
     intros; repeat (rewrite orb_false_iff in H19);destruct H19. destruct H19.
     unfold Lit.interp in H19.
     rewrite H3 in H19; unfold Var.interp in H19; rewrite H4 in H19.
     unfold Lit.interp in H21.
     pose (H24 := H15). apply negb_true_iff in H24.
     rewrite H24 in H21.
     unfold Var.interp in H21; rewrite H16 in H21.
     unfold Lit.interp in H23.
     pose (H25 := H9). apply negb_true_iff in H25.
     rewrite H25 in H23.
     unfold Var.interp in H23; rewrite H10 in H23.
     assert (t = Typ.TZ).
     generalize H12. clear H12.
     destruct (Typ.reflect_eqb (get_type t_i t_func t_atom b0) Typ.TZ) as [H12|H12]; [intros _|discriminate].
     generalize H6. clear H6.
     destruct (Typ.reflect_eqb (get_type t_i t_func t_atom b0) t) as [H6|H6]; [intros _|discriminate].
     rewrite <- H6. auto with smtcoq_core.
     rewrite H26 in H19.
     case_eq (interp_atom (t_atom .[ b1])); intros t1 v1 Heq1.
     assert (H50: t1 = Typ.TZ).
     unfold get_type, get_type' in H18. rewrite t_interp_wf in H18; trivial. rewrite Heq1 in H18. simpl in H18. rewrite Typ.eqb_spec in H18. assumption.
     subst t1.
     case_eq (interp_atom (t_atom .[ a2])); intros t2 v2 Heq2.
     assert (H50: t2 = Typ.TZ).
     unfold get_type, get_type' in H17. rewrite t_interp_wf in H17; trivial. rewrite Heq2 in H17. simpl in H17. rewrite Typ.eqb_spec in H17. assumption.
     subst t2.
     subst;elim (interp_binop_eqb_antisym (t_atom.[b1]) (t_atom.[a2]) v1 v2);trivial.
       unfold interp_hatom in H19; do 2 rewrite t_interp_wf in H19; trivial.
       unfold interp_hatom in H23; do 2 rewrite t_interp_wf in H23; trivial.
       unfold interp_hatom in H21; do 2 rewrite t_interp_wf in H21; trivial.
     trivial.
     destruct H19.
     case_eq ((a0 == b0) && (a0 == a2) && (b == a1) && (b == b1)); intros; subst;
       try (unfold C.valid; apply valid_C_true; trivial).
     repeat(apply andb_prop in H19; destruct H19).
     apply Int63.eqb_spec in H19;apply Int63.eqb_spec in H20;apply Int63.eqb_spec in H21;apply Int63.eqb_spec in H22;subst a0 b.
     unfold C.interp; simpl; rewrite orb_false_r.
     unfold Lit.interp; rewrite Lit.is_pos_lit.
     unfold Var.interp; rewrite Lit.blit_lit.
     rewrite wf_interp_form, H;simpl.
     case_eq (Lit.interp rho (a.[0]) || Lit.interp rho (a.[1]) || Lit.interp rho (a.[2])).
     intros;repeat (rewrite orb_true_iff in H19);destruct H19. destruct H19.
     apply (afold_left_orb_true 0); rewrite ?length_amap, ?get_amap; [ rewrite H0; reflexivity | assumption | rewrite H0; reflexivity ].
     apply (afold_left_orb_true 1); rewrite ?length_amap, ?get_amap; [ rewrite H0; reflexivity | assumption | rewrite H0; reflexivity ].
     apply (afold_left_orb_true 2); rewrite ?length_amap, ?get_amap; [ rewrite H0; reflexivity | assumption | rewrite H0; reflexivity ].
     intros; repeat (rewrite orb_false_iff in H19);destruct H19. destruct H19.
     unfold Lit.interp in H19.
     rewrite H3 in H19; unfold Var.interp in H19; rewrite H4 in H19.
     unfold Lit.interp in H21.
     case_eq (Lit.is_pos (a.[2])); intros.
     apply negb_true_iff in H15;rewrite H15 in H24; discriminate.
     rewrite H24 in H21.
     unfold Var.interp in H21;rewrite H16 in H21.
     unfold Lit.interp in H23.
     case_eq (Lit.is_pos (a.[1])); intros.
     apply negb_true_iff in H9; rewrite H9 in H25; discriminate.
     rewrite H25 in H23.
     unfold Var.interp in H23; rewrite H10 in H23.
     rewrite <-H22, <- H20 in H21.
     assert (t = Typ.TZ).
       rewrite Typ.eqb_spec in H6; rewrite Typ.eqb_spec in H18; subst; auto with smtcoq_core.
     rewrite H26 in H19.
     case_eq (interp_atom (t_atom .[ b0])); intros t1 v1 Heq1.
     assert (H50: t1 = Typ.TZ).
     unfold get_type, get_type' in H12. rewrite t_interp_wf in H12; trivial. rewrite Heq1 in H12. simpl in H12. rewrite Typ.eqb_spec in H12. assumption.
     subst t1.
     case_eq (interp_atom (t_atom .[ a1])); intros t2 v2 Heq2.
     assert (H50: t2 = Typ.TZ).
     unfold get_type, get_type' in H11. rewrite t_interp_wf in H11; trivial. rewrite Heq2 in H11. simpl in H11. rewrite Typ.eqb_spec in H11. assumption.
     subst t2.
     elim (interp_binop_eqb_antisym (t_atom.[b0]) (t_atom.[a1]) v1 v2); trivial.
       unfold interp_hatom in H19; do 2 rewrite t_interp_wf in H19; trivial.
       unfold interp_hatom in H21; do 2 rewrite t_interp_wf in H21; trivial.
       unfold interp_hatom in H23; do 2 rewrite t_interp_wf in H23; trivial.
     trivial.
   Qed.

 End Proof.

End certif.



(* 
   Local Variables:
   coq-load-path: ((rec ".." "SMTCoq"))
   End: 
*)
