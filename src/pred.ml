(*******************************************************************)
(*     This is part of WhyMon, and it is distributed under the     *)
(*     terms of the GNU Lesser General Public License version 3    *)
(*           (see file LICENSE for more details)                   *)
(*                                                                 *)
(*  Copyright 2023:                                                *)
(*  Dmitriy Traytel (UCPH)                                         *)
(*  Leonardo Lima (UCPH)                                           *)
(*******************************************************************)

open Base
open Stdio

module Term = struct

  module T = struct

    type t = Var of string | Const of Dom.t | App of string * t list [@@deriving sexp_of, hash]

    let rec compare t t' =
      match t, t' with
      | Var s, Var s' -> String.compare s s'
      | Var _, _ -> -1
      | Const d, Const d' -> Dom.compare d d'
      | Const _, Var _ -> 1
      | Const _, App _ -> -1
      | App (s, [Var x; trm]), App (s', [Var x'; trm']) when Funcs.is_eq s && Funcs.is_eq s' ->
         Etc.lexicographic2 String.compare compare (x, trm) (x', trm')
      | App (s, [Var x; trm]), App _ when Funcs.is_eq s -> -1
      | App _, App (s', [Var x'; trm']) when Funcs.is_eq s' -> 1
      | App (s, ts), App (s', ts') ->
         Etc.lexicographic2 String.compare (Etc.lexicographics compare) (s, ts) (s', ts')
      | App _, _ -> 1

    let var x = Var x
    let const d = Const d
    let app f trms = App (f, trms)

    let unvar = function
      | Var x -> x
      | Const _ -> raise (Invalid_argument "unvar is undefined for Consts")
      | App _ -> raise (Invalid_argument "unvar is undefined for Apps")

    let unconst = function
      | Var _ -> raise (Invalid_argument "unconst is undefined for Vars")
      | App _ -> raise (Invalid_argument "unconst is undefined for Apps")
      | Const c -> c

    let rec fv_list = function
      | [] -> []
      | Const c :: trms -> fv_list trms
      | Var x :: trms -> x :: fv_list trms
      | App (_, trms) :: trms' -> fv_list trms @ fv_list trms'

    let rec equal t t' = match t, t' with
      | Var x, Var x' -> String.equal x x'
      | Const d, Const d' -> Dom.equal d d'
      | App (f, ts), App (f', ts') ->
         String.equal f f' &&
           (match List.map2 ts ts' ~f:equal with
            | Ok b -> List.for_all b (fun x -> x)
            | Unequal_lengths -> false)
      | _ -> false

    let rec to_string = function
      | Var x -> Printf.sprintf "Var %s" x
      | Const d -> Printf.sprintf "Const %s" (Dom.to_string d)
      | App (f, ts) -> Printf.sprintf "App %s(%s)" f (String.concat ~sep:", " (List.map ts ~f:to_string))

    let rec value_to_string = function
      | Var x -> Printf.sprintf "%s" x
      | Const d -> Printf.sprintf "%s" (Dom.to_string d)
      | App (f, ts) -> Printf.sprintf "%s(%s)" f (String.concat ~sep:", " (List.map ts ~f:value_to_string))

    let rec list_to_string trms = String.concat ~sep:", " (List.map trms ~f:value_to_string)

    let filter_vars = List.filter_map ~f:(function Var x -> Some x | _ -> None)

    let rec reorder l = function
      | [] -> l
      | h::t when not (List.mem l (Var h) ~equal) -> reorder l t
      | h::t -> (Var h) :: (reorder (List.filter l (fun x -> not (equal x (Var h)))) t)

  end

  include T
  include Comparator.Make(T)

end

module EnfType = struct

  type t = Cau | Sup | CauSup | Obs [@@deriving compare, sexp_of, hash]

  let neg = function
    | Cau    -> Sup
    | Sup    -> Cau
    | CauSup -> CauSup
    | Obs    -> Obs

  let to_int = function
    | Cau    -> 1
    | Sup    -> 2
    | CauSup -> 3
    | Obs    -> 0

  let to_string = function
    | Cau    -> "Cau"
    | Sup    -> "Sup"
    | CauSup -> "CauSup"
    | Obs    -> "Obs"

  let meet a b = match a, b with
    | _, _ when a == b -> a
    | Cau, Sup | Sup, Cau | CauSup, _ | _, CauSup -> CauSup
    | Obs, x | x, Obs -> x

  let join a b = match a, b with
    | _, _ when a == b -> a
    | Cau, Sup | Sup, Cau | Obs, _ | _, Obs -> Obs
    | Cau, _ | _, Cau -> Cau
    | _, _ -> Sup

  let leq a b = (join a b) == a
  let geq a b = (meet a b) == b

  let specialize a b = if leq b a then Some b else None

end

let tilde_tp_event_name = "~tp"
let tick_event_name = "tick"
let tp_event_name = "tp"
let ts_event_name = "ts"


module Sig = struct

  type pred_kind = Trace | Predicate | External | Builtin | Let [@@deriving compare, sexp_of, hash, equal]

  type pred = { arity: int;
                arg_tts: (string * Dom.tt) list;
                enftype: EnfType.t;
                rank: int;
                kind: pred_kind } [@@deriving compare, sexp_of, hash]

  let string_of_pred name pred =
    let f acc (var, tt) = acc ^ "," ^ var ^ ":" ^ (Dom.tt_to_string tt) in
    Printf.sprintf "%s(%s)" name
      (String.drop_prefix (List.fold pred.arg_tts ~init:"" ~f) 1)


  type ty = Pred of pred | Func of Funcs.t (*[@@deriving compare, sexp_of, hash]*)

  let string_of_ty name = function
    | Pred pred -> string_of_pred name pred
    | Func func -> Funcs.to_string name func

  let arity = function
    | Pred pred -> pred.arity
    | Func func -> func.arity

  let arg_tts = function
    | Pred pred -> pred.arg_tts
    | Func func -> func.arg_tts

  let unpred = function
    | Pred pred -> pred
    | Func func -> raise (Invalid_argument "unpred is undefined for Funs")

  let unfunc = function
    | Func func -> func
    | Pred pred -> raise (Invalid_argument "unfunc is undefined for Preds")

  type elt = string * ty (*[@@deriving compare, sexp_of, hash]*)

  type t = (string, ty) Hashtbl.t

  let table: t =
    let table = Hashtbl.of_alist_exn (module String)
                  (List.map Funcs.builtins ~f:(fun (k,v) -> (k, Func v))) in
    Hashtbl.add_exn table ~key:tilde_tp_event_name
      ~data:(Pred { arity = 0; arg_tts = []; enftype = Cau; rank = 0; kind = Trace });
    Hashtbl.add_exn table ~key:tick_event_name
      ~data:(Pred { arity = 0; arg_tts = []; enftype = Obs; rank = 0; kind = Trace });
    Hashtbl.add_exn table ~key:tp_event_name
      ~data:(Pred { arity = 1; arg_tts = [("i", TInt)]; enftype = Obs; rank = 0; kind = Builtin });
    Hashtbl.add_exn table ~key:ts_event_name
      ~data:(Pred { arity = 1; arg_tts = [("t", TInt)]; enftype = Obs; rank = 0; kind = Builtin });
    table

  let add_letpred p_name arg_tts =
    Hashtbl.add_exn table ~key:p_name
      ~data:(Pred { arity = List.length arg_tts; arg_tts; enftype = Obs; rank = 0; kind = Let })

  let add_pred p_name arg_tts enftype rank kind =
    if equal_pred_kind kind Predicate then
      Hashtbl.add_exn table ~key:p_name
        ~data:(Func { arity = List.length arg_tts; arg_tts; ret_tt = TInt; kind = External })
    else
      Hashtbl.add_exn table ~key:p_name
        ~data:(Pred { arity = List.length arg_tts; arg_tts; enftype; rank; kind })

  let add_func f_name arg_tts ret_tt kind =
    Hashtbl.add_exn table ~key:f_name ~data:(Func { arity = List.length arg_tts; arg_tts; ret_tt; kind })

  let update_enftype name enftype =
    Hashtbl.update table name ~f:(fun (Some (Pred x)) -> Pred { x with enftype })

  let vars_of_pred name = List.map (unpred (Hashtbl.find_exn table name)).arg_tts ~f:fst

  let arg_tts_of_pred name = List.map (unpred (Hashtbl.find_exn table name)).arg_tts ~f:snd

  let arg_tts_of_func name = List.map (unfunc (Hashtbl.find_exn table name)).arg_tts ~f:snd

  let ret_tt_of_func name = (unfunc (Hashtbl.find_exn table name)).ret_tt

  let enftype_of_pred name = (unpred (Hashtbl.find_exn table name)).enftype

  let rank_of_pred name = (unpred (Hashtbl.find_exn table name)).rank

  let kind_of_pred name = (unpred (Hashtbl.find_exn table name)).kind

  let func ff ds =
    let the_func = unfunc (Hashtbl.find_exn table ff) in
    match the_func.kind with
    | Builtin f -> f ds
    | External -> Funcs.Python.call ff ds the_func.ret_tt

  let print_table () =
    Hashtbl.iteri table ~f:(fun ~key:n ~data:ps -> Stdio.printf "%s\n" (string_of_ty n ps))

  let rec eval (v: Etc.valuation) = function
    | Term.Var x ->
       (match Map.find v x with
        | Some d -> Term.Const d
        | None -> Var x)
    | Const c -> Const c
    | App (ff, trms) ->
       let trms = List.map trms ~f:(eval v) in
       let f = function Term.Const d -> Some d | _ -> None in
       match Option.all (List.map trms ~f) with
       | Some ds -> Const (func ff ds)
       | None -> App (ff, trms)

  let rec set_eval (v: Setc.valuation) = function
    | Term.Var x ->
       (match Map.find v x with
        | Some (Setc.Finite s) -> Setc.Finite (Set.map (module Term) s ~f:Term.const)
        | Some (Setc.Complement s) -> Setc.Complement (Set.map (module Term) s ~f:Term.const)
        | None -> Setc.singleton (module Term) (Var x))
    | Const c -> Setc.singleton (module Term) (Const c)
    | App (ff, trms) ->
       let trms' = List.map trms ~f:(set_eval v) in
       let f trms =
         match Option.all (List.map trms ~f:(function Term.Const d -> Some d | _ -> None)) with
         | Some ds -> Term.Const (func ff ds)
         | None -> Term.App (ff, trms) in
       match Option.all (List.map trms' ~f:(function Setc.Finite s -> Some s | _ -> None)) with
       | Some ds -> let prod   = Etc.cartesian (List.map ds ~f:Set.elements) in
                    let trms'' = List.map prod ~f in
                    Setc.Finite (Set.of_list (module Term) trms'')
       | None -> Setc.singleton (module Term) (Term.App (ff, trms))

  let rec var_tt_of_term x tt = function
    | Term.Var x' when String.equal x x' -> Some tt
    | Var x' -> None
    | App (f, trms) -> var_tt_of_terms x (arg_tts_of_func f) trms
    | Const c -> None
  and var_tt_of_terms x tts trms =
    List.find_map (List.zip_exn tts trms)
      ~f:(fun (tt, trm) -> var_tt_of_term x tt trm)

  let rec var_tt_of_term_exn vt = function
    | Term.Var x -> Map.find_exn vt x
    | Const d -> Dom.tt_of_domain d
    | App (f, _) -> ret_tt_of_func f

end

module Lbl = struct

  module S = struct
    type t = (string, String.comparator_witness) Set.t
    let equal = Set.equal 
    let compare = Set.compare_direct 
    let sexp_of_t s = Sexp.List (List.map (Set.elements s) ~f:(fun x -> Sexp.Atom x))
    let empty = Set.empty (module String)
    let is_empty = Set.is_empty
    let mem = Set.mem
    let filter = Set.filter
    let singleton = Set.singleton (module String)
    let of_list = Set.of_list (module String)
    let length = Set.length
    let elements = Set.elements
    let to_string s =
      Printf.sprintf "{%s}" (String.concat ~sep:", " (elements s))
  end

  module T = struct
    
    type t = LVar of string | LEx of string | LAll of string | LClos of string * Term.t list * S.t [@@deriving equal, compare, sexp_of]

    let var s = LVar s
    let ex s = LEx s
    let all s = LAll s
    let clos s terms vars = LClos (s, terms, vars)

    let is_var = function
      | LVar _ -> true
      | _ -> false

    let term = function
      | LVar s -> Term.Var s
      | LClos (f, ts, v) -> App (f, ts)

    let of_term = function
      | Term.Var s -> LVar s
      | App (f, ts) -> LClos (f, ts, S.empty)

    let to_string = function
      | LVar x -> Printf.sprintf "LVar %s" x
      | LEx x -> Printf.sprintf "LEx %s" x
      | LAll x -> Printf.sprintf "LAll %s" x
      | LClos (f, ts, v) ->
         Printf.sprintf "LClos %s(%s; [%s])"
           f (String.concat ~sep:", " (List.map ts ~f:Term.to_string)) (S.to_string v)

    let to_string_list lbls =
      String.concat ~sep:", " (List.map ~f:to_string lbls)

    let rec fv = function
      | LVar s -> S.singleton s
      | LClos (f, ts, vars) ->
         S.filter (S.of_list (Term.fv_list ts)) ~f:(fun x -> not (S.mem vars x))

    let quantify ~forall x = function
      | LVar x' when String.equal x x' ->
         if forall then LAll x' else LEx x'
      | LClos (f, ts, vars) as lbl ->
         let fvs = fv lbl in
         (if S.mem fvs x then
            LClos (f, ts, Set.add vars x)
          else
            LClos (f, ts, vars))
      | lbl -> lbl

    let quantify_list ~forall x lbls =
      List.map lbls ~f:(quantify ~forall x)

    let rec unquantify_list x =
      let rec unquantify_list2 = function
        | [] -> []
        | (LAll x' as lbl) :: terms | (LEx x' as lbl) :: terms when String.equal x x'
          -> lbl :: terms
        | LClos (f, ts, vars) :: terms
          -> LClos (f, ts, Set.remove vars x) :: unquantify_list2 terms
        | lbl :: terms
          -> lbl :: unquantify_list2 terms in
      function
      | [] -> []
      | LAll x' :: terms | LEx x' :: terms when String.equal x x' ->
         LVar x' :: (unquantify_list2 terms)
      | lbl :: terms -> lbl :: (unquantify_list x terms)


    let rec eval (v: Etc.valuation) = function
      | LVar s when Map.mem v s -> Term.Const (Map.find_exn v s)
      | LVar s -> Var s
      | LClos (f, ts, _) ->
         let aux = function | `Left y | `Right y | `Both (y, _) -> Some y in
         Sig.eval v (App (f, ts))
      | _ -> assert false

  end

  include T
  include Comparator.Make(T)
  
end

let check_const types c tt =
  if Dom.tt_equal (Dom.tt_of_domain c) tt then
    types
  else
    raise (Invalid_argument (
               Printf.sprintf "type clash for constant %s: found %s, expected %s"
                 (Dom.to_string c)
                 (Dom.tt_to_string (Dom.tt_of_domain c))
                 (Dom.tt_to_string tt)))

let check_var types v tt =
  match Map.find types v with
  | None -> Map.add_exn types ~key:v ~data:tt
  | Some tt' when Dom.tt_equal tt tt' -> types
  | Some tt' ->
     raise (Invalid_argument (
                Printf.sprintf "type clash for variable %s: found %s, expected %s"
                  v (Dom.tt_to_string tt) (Dom.tt_to_string tt')))

let check_app types f tt =
  if Dom.tt_equal (Sig.ret_tt_of_func f) tt then
    types
  else
    raise (Invalid_argument (
               Printf.sprintf "type clash for return type of %s: found %s, expected %s"
                 f
                 (Dom.tt_to_string (Sig.ret_tt_of_func f))
                 (Dom.tt_to_string tt)))

let rec check_term types tt trm =
  match trm with
  | Term.Var x -> check_var types x tt
  | Const c -> check_const types c tt
  | App (f, trms) -> check_app (check_terms types f trms) f tt

and check_terms types p_name trms =
  let sig_pred = Hashtbl.find_exn Sig.table p_name in
  if List.length trms = Sig.arity sig_pred then
    List.fold2_exn trms (Sig.arg_tts sig_pred) ~init:types
      ~f:(fun types trm ntc -> check_term types (snd ntc) trm)
  else raise (Invalid_argument (
                  Printf.sprintf "arity of %s is %d" p_name (Sig.arity sig_pred)))
