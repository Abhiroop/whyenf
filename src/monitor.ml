(*******************************************************************)
(*     This is part of Explanator2, it is distributed under the    *)
(*     terms of the GNU Lesser General Public License version 3    *)
(*           (see file LICENSE for more details)                   *)
(*                                                                 *)
(*  Copyright 2021:                                                *)
(*  Leonardo Lima (UCPH)                                           *)
(*******************************************************************)

open Io
open Mtl
open Expl
open Util
open Interval
open Checker_interface

module Deque = Core_kernel.Deque
module List = Core_kernel.List

exception INVALID_FORM

let sappend_to_deque sp1 d =
  let _ = Deque.iteri d ~f:(fun i (ts, ssp) ->
              match ssp with
              | S sp -> Deque.set_exn d i (ts, S (sappend sp sp1))
              | V _ -> raise SEXPL) in d

let vappend_to_deque vp2 d =
  let _ = Deque.iteri d ~f:(fun i (ts, vvp) ->
              match vvp with
              | V vp -> Deque.set_exn d i (ts, V (vappend vp vp2))
              | S _ -> raise VEXPL) in d

let betas_suffix_in_to_list betas_suffix_in =
  Deque.fold' betas_suffix_in ~init:[]
    ~f:(fun acc (ts, vp) -> vp::acc) `back_to_front

(* Sort proofs wrt a particular measure, i.e.,
   if |p_1| <= |p_2| in [p_1, p_2, p_3, ..., p_n]
   then p_2 must be removed (and so on).
   The order of the resulting list is reversed, which
   means that the smallest element is also the head *)
let sort_ps le new_in =
  let rec aux ps acc =
    match ps with
    | [] -> acc
    | x::x'::xs ->
       if le (snd(x)) (snd(x')) then
         aux xs (x::acc)
       else aux xs (x'::acc)
    | x::xs -> x::acc
  in aux new_in []

let sort_ps2 le l =
  let rec aux ps acc =
    match ps with
    | [] -> acc
    | (ets1, lts1, x)::(ets2, lts2, x')::xs ->
       if le x x' then
         aux xs ((ets1, lts1, x)::acc)
       else aux xs ((ets2, lts2, x')::acc)
    | x::xs -> x::acc
  in aux l []

module Past = struct
  type msaux = {
      ts_zero: timestamp option
    ; ts_in: timestamp Deque.t
    ; ts_out: timestamp Deque.t

    (* sorted deque of S^+ beta [alphas] *)
    ; beta_alphas: (timestamp * expl) Deque.t
    (* deque of S^+ beta [alphas] outside of the interval *)
    ; beta_alphas_out: (timestamp * expl) Deque.t

    (* sorted deque of S^- alpha [betas] *)
    ; alpha_betas: (timestamp * expl) Deque.t
    (* sorted deque of alpha proofs *)
    ; alphas_out: (timestamp * expl) Deque.t
    (* list of beta violations inside the interval *)
    ; betas_suffix_in: (timestamp * vexpl) Deque.t
    (* list of alpha/beta violations *)
    ; alphas_betas_out: (timestamp * vexpl option * vexpl option) Deque.t
    ; }

  let print_ts_lists { ts_zero; ts_in; ts_out } =
    Printf.fprintf stdout "%s" (
    (match ts_zero with
     | None -> ""
     | Some(ts) -> Printf.sprintf "\n\tts_zero = (%d)\n" ts) ^
    Deque.fold ts_in ~init:"\n\tts_in = ["
      ~f:(fun acc ts -> acc ^ (Printf.sprintf "%d;" ts)) ^
      (Printf.sprintf "]\n") ^
    Deque.fold ts_out ~init:"\n\tts_out = ["
      ~f:(fun acc ts -> acc ^ (Printf.sprintf "%d;" ts)) ^
      (Printf.sprintf "]\n"))

  let msaux_to_string { ts_zero
                      ; ts_in
                      ; ts_out
                      ; beta_alphas
                      ; beta_alphas_out
                      ; alpha_betas
                      ; alphas_out
                      ; betas_suffix_in
                      ; alphas_betas_out } =
    "\n\nmsaux: " ^
      (match ts_zero with
       | None -> ""
       | Some(ts) -> Printf.sprintf "\nts_zero = (%d)\n" ts) ^
      Deque.fold ts_in ~init:"\nts_in = ["
        ~f:(fun acc ts -> acc ^ (Printf.sprintf "%d;" ts)) ^
      (Printf.sprintf "]\n") ^
      Deque.fold ts_out ~init:"\nts_out = ["
        ~f:(fun acc ts -> acc ^ (Printf.sprintf "%d;" ts)) ^
      (Printf.sprintf "]\n") ^
      Deque.fold beta_alphas ~init:"\nbeta_alphas = "
        ~f:(fun acc (ts, ps) ->
          acc ^ (Printf.sprintf "\n(%d)\n" ts) ^ Expl.expl_to_string ps) ^
      Deque.fold beta_alphas_out ~init:"\nbeta_alphas_out = "
        ~f:(fun acc (ts, ps) ->
          acc ^ (Printf.sprintf "\n(%d)\n" ts) ^ Expl.expl_to_string ps) ^
      Deque.fold alpha_betas ~init:"\nalpha_betas = "
        ~f:(fun acc (ts, ps) ->
          acc ^ (Printf.sprintf "\n(%d)\n" ts) ^ Expl.expl_to_string ps) ^
      Deque.fold alphas_out ~init:"\nalphas_out = "
        ~f:(fun acc (ts, ps) ->
          acc ^ (Printf.sprintf "\n(%d)\n" ts) ^ Expl.expl_to_string ps) ^
      Deque.fold betas_suffix_in ~init:"\nbetas_suffix_in = "
        ~f:(fun acc (ts, ps) ->
          acc ^ (Printf.sprintf "\n(%d)\n" ts) ^ Expl.v_to_string "" ps) ^
      Deque.fold alphas_betas_out ~init:"\nalphas_betas_out = "
        ~f:(fun acc (ts, p1_opt, p2_opt) ->
          match p1_opt, p2_opt with
          | None, None -> acc
          | Some(p1), None -> acc ^ (Printf.sprintf "\n(%d)\nalpha = " ts) ^
                              Expl.v_to_string "" p1
          | None, Some(p2) -> acc ^ (Printf.sprintf "\n(%d)\nbeta = " ts) ^
                              Expl.v_to_string "" p2
          | Some(p1), Some(p2) -> acc ^ (Printf.sprintf "\n(%d)\nalpha = " ts) ^
                                  Expl.v_to_string "" p1 ^
                                  (Printf.sprintf "\n(%d)\nbeta = " ts) ^
                                  Expl.v_to_string "" p2)

  let update_ts (l, r) a ts msaux =
    if a = 0 then
      let _ = Deque.enqueue_back msaux.ts_in ts in
      let ts_in_lst = Deque.to_list msaux.ts_in in
      let _ = List.iter ts_in_lst
                ~f:(fun ts' -> if ts' < l then Deque.drop_front msaux.ts_in) in
      msaux
    else
      let _ = Deque.enqueue_back msaux.ts_out ts in
      let out_lst = Deque.to_list msaux.ts_out in
      let _ = List.iter out_lst
                ~f:(fun ts' -> if ts' <= r then
                                 let _ = Deque.enqueue_back msaux.ts_in ts' in
                                 Deque.drop_front msaux.ts_out) in
      let in_lst = Deque.to_list msaux.ts_in in
      let _ = List.iter in_lst
                ~f:(fun ts' -> if ts' < l then Deque.drop_front msaux.ts_in) in
      msaux

  (* Resulting list is in ascending order, e.g.,
   d = [(1, p_1), (2, p_2), ..., (n, p_n)]
   results in [(n, p_n), ...]  *)
  let split_in_out (l, r) d =
    let l = List.fold (Deque.to_list d) ~init:[]
              ~f:(fun acc (ts, p) ->
                if ts <= r then (
                  let _ = Deque.drop_front d in
                  if ts >= l then (ts, p)::acc
                  else acc)
                else acc)
    in (d, l)

  let split_in_out2 (l, r) d =
    let l = List.rev (List.fold (Deque.to_list d) ~init:[]
                        ~f:(fun acc (ts, vp1_opt, vp2_opt) ->
                          if ts <= r then (
                            let _ = Deque.drop_front d in
                            if ts >= l then (ts, vp1_opt, vp2_opt)::acc
                            else acc)
                          else acc))
    in (d, l)

  let remove_out_less l d =
    let _ = List.iter (Deque.to_list d)
              ~f:(fun (ts, _) -> if ts < l then Deque.drop_front d)
    in d

  let remove_out_leq r d =
    let _ = List.iter (Deque.to_list d)
              ~f:(fun (ts, _) -> if ts <= r then Deque.drop_front d)
    in d

  let remove_out_less2 l d =
    let _ = List.iter (Deque.to_list d)
              ~f:(fun (ts, _, _) -> if ts < l then Deque.drop_front d)
    in d

  let add_alphas_out ts vvp1 alphas_out le =
    let _ = List.iter (List.rev(Deque.to_list alphas_out))
              ~f:(fun (_, vvp) ->
                if le vvp1 vvp then Deque.drop_back alphas_out) in
    let _ = Deque.enqueue_back alphas_out (ts, vvp1)
    in alphas_out

  let update_beta_alphas new_in beta_alphas le =
    if (List.is_empty new_in) then
      beta_alphas
    else (
      let new_in' = sort_ps le new_in in
      let hd_p = List.hd_exn new_in' in
      let _ = Deque.iter beta_alphas ~f:(fun (ts, sp) ->
                  if le (snd(hd_p)) sp then
                    Deque.drop_back beta_alphas) in
      let _ = List.iter new_in' ~f:(fun (ts, sp) ->
                  Deque.enqueue_back beta_alphas (ts, sp))
      in beta_alphas)

  let update_betas_suffix_in new_in betas_suffix_in =
    if (List.is_empty new_in) then
      betas_suffix_in
    else (
      if List.exists new_in
           (fun (_, _, vp2_opt) ->
             Option.is_none vp2_opt)
      then (
        let _ = Deque.clear betas_suffix_in in
        let new_in' = List.rev (List.take_while (List.rev new_in)
                                  ~f:(fun (_, _, vp2_opt) ->
                                    Option.is_some vp2_opt)) in
        let _ = List.iter new_in'
                  ~f:(fun (ts, _, vp2_opt) ->
                    match vp2_opt with
                    | None -> ()
                    | Some (vp2) -> Deque.enqueue_back betas_suffix_in (ts, vp2))
        in betas_suffix_in)
      else (
        let _ = List.iter new_in
                  ~f:(fun (ts, _, vp2_opt) ->
                    match vp2_opt with
                    | None -> ()
                    | Some(vp2) -> Deque.enqueue_back betas_suffix_in (ts, vp2))
        in betas_suffix_in))

  let construct_vsinceps tp new_in =
    List.rev(List.fold new_in ~init:[]
               ~f:(fun acc (ts, vp1_opt, vp2_opt) ->
                 match vp1_opt with
                 | None ->
                    let vp2 = Option.get vp2_opt in
                    List.map ~f:(fun (ts, vvp) ->
                        match vvp with
                        | V vp -> (ts, V (vappend vp vp2))
                        | S _ -> raise VEXPL) acc
                 | Some(vp1) ->
                    let vp2 = Option.get vp2_opt in
                    let new_acc =
                      List.map ~f:(fun (ts, vvp) ->
                          match vvp with
                          | V vp -> (ts, V (vappend vp vp2))
                          | S _ -> raise VEXPL) acc in
                    let vp = V (VSince (tp, vp1, [vp2])) in
                    (ts, vp)::new_acc))

  let add_new_ps_alpha_betas tp new_in alpha_betas =
    let new_vps_in = construct_vsinceps tp new_in in
    let _ = List.iter new_vps_in
              ~f:(fun (ts, vp) ->
                Deque.enqueue_back alpha_betas (ts, vp))
    in alpha_betas

  let update_alpha_betas_tps tp alpha_betas =
    let alpha_betas_updated = Deque.create () in
    let _ = Deque.iter alpha_betas
              ~f:(fun (ts, vvp) ->
                match vvp with
                | V vp -> (match vp with
                           | VSince (tp', vp1, vp2s) ->
                              Deque.enqueue_back alpha_betas_updated (ts, V (VSince (tp, vp1, vp2s)))
                           | _ -> raise INVALID_FORM)
                | S _ -> raise VEXPL)
    in alpha_betas_updated

  let update_alpha_betas tp new_in alpha_betas =
    if (List.is_empty new_in) then
      (update_alpha_betas_tps tp alpha_betas)
    else (
      if List.exists new_in
           ~f:(fun (_, _, vp2_opt) ->
             Option.is_none vp2_opt)
      then
        let _ = Deque.clear alpha_betas in
        let new_in' = List.rev (List.take_while (List.rev new_in)
                                  ~f:(fun (_, _, vp2_opt) ->
                                    Option.is_some vp2_opt)) in
        let alpha_betas' = add_new_ps_alpha_betas tp new_in' alpha_betas in
        (update_alpha_betas_tps tp alpha_betas')
      else (
        let alpha_betas_vapp = List.fold new_in ~init:alpha_betas
                                 ~f:(fun d (_, _, vp2_opt) ->
                                   match vp2_opt with
                                   | None -> d
                                   | Some(vp2) -> vappend_to_deque vp2 d) in
        let alpha_betas' = add_new_ps_alpha_betas tp new_in alpha_betas_vapp in
        (update_alpha_betas_tps tp alpha_betas')))

  let optimal_proof tp msaux =
    if not (Deque.is_empty msaux.beta_alphas) then
      [snd(Deque.peek_front_exn msaux.beta_alphas)]
    else
      let p1_l = if not (Deque.is_empty msaux.alpha_betas) then
                   [snd(Deque.peek_front_exn msaux.alpha_betas)]
                 else [] in
      let p2_l = if not (Deque.is_empty msaux.alphas_out) then
                   let vp_f2 = snd(Deque.peek_front_exn msaux.alphas_out) in
                   match vp_f2 with
                   | V f2 -> [V (VSince (tp, f2, []))]
                   | S _ -> raise VEXPL
                 else [] in
      let p3_l = if (Deque.length msaux.betas_suffix_in) = (Deque.length msaux.ts_in) then
                   let betas_suffix = betas_suffix_in_to_list msaux.betas_suffix_in in
                   [V (VSinceInf (tp, betas_suffix))]
                 else [] in
      (p1_l @ p2_l @ p3_l)

  let add_to_msaux ts p1 p2 msaux le =
    match p1, p2 with
    | S sp1, S sp2 ->
       let beta_alphas = sappend_to_deque sp1 msaux.beta_alphas in
       let beta_alphas_out = sappend_to_deque sp1 msaux.beta_alphas_out in
       let sp = S (SSince (sp2, [])) in
       let _ = Deque.enqueue_back beta_alphas_out (ts, sp) in
       let _ = Deque.enqueue_back msaux.alphas_betas_out (ts, None, None) in
       { msaux with
         beta_alphas = beta_alphas
       ; beta_alphas_out = beta_alphas_out }
    | S sp1, V vp2 ->
       let beta_alphas = sappend_to_deque sp1 msaux.beta_alphas in
       let beta_alphas_out = sappend_to_deque sp1 msaux.beta_alphas_out in
       let _ = Deque.enqueue_back msaux.alphas_betas_out (ts, None, Some(vp2)) in
       { msaux with
         beta_alphas = beta_alphas
       ; beta_alphas_out = beta_alphas_out }
    | V vp1, S sp2 ->
       let alphas_out = add_alphas_out ts (V vp1) msaux.alphas_out le in
       let _ = Deque.enqueue_back msaux.alphas_betas_out (ts, Some(vp1), None) in
       let _ = Deque.clear msaux.beta_alphas in
       let _ = Deque.clear msaux.beta_alphas_out in
       let sp = S (SSince (sp2, [])) in
       let _ = Deque.enqueue_back msaux.beta_alphas_out (ts, sp) in
       { msaux with alphas_out = alphas_out }
    | V vp1, V vp2 ->
       let alphas_out = add_alphas_out ts (V vp1) msaux.alphas_out le in
       let _ = Deque.enqueue_back msaux.alphas_betas_out (ts, Some(vp1), Some(vp2)) in
       let _ = Deque.clear msaux.beta_alphas in
       let _ = Deque.clear msaux.beta_alphas_out in
       { msaux with alphas_out = alphas_out }

  let remove_from_msaux (l, r) msaux =
    let beta_alphas = remove_out_less l msaux.beta_alphas in
    let beta_alphas_out = remove_out_less l msaux.beta_alphas_out in
    let alpha_betas = remove_out_less l msaux.alpha_betas in
    let alphas_out = remove_out_leq r msaux.alphas_out in
    let betas_suffix_in = remove_out_less l msaux.betas_suffix_in in
    let alphas_betas_out = remove_out_less2 l msaux.alphas_betas_out in
    { msaux with
      beta_alphas = beta_alphas
    ; beta_alphas_out = beta_alphas_out
    ; alpha_betas = alpha_betas
    ; alphas_out = alphas_out
    ; betas_suffix_in = betas_suffix_in
    ; alphas_betas_out = alphas_betas_out }

  let advance_msaux (l, r) tp ts p1 p2 msaux le =
    let msaux_plus_new = add_to_msaux ts p1 p2 msaux le in
    let msaux_minus_old = remove_from_msaux (l, r) msaux_plus_new in
    let beta_alphas_out, new_in_sat = split_in_out (l, r) msaux_minus_old.beta_alphas_out in
    let beta_alphas = update_beta_alphas new_in_sat msaux_minus_old.beta_alphas le in
    let alphas_betas_out, new_in_viol = split_in_out2 (l, r) msaux_minus_old.alphas_betas_out in
    let betas_suffix_in = update_betas_suffix_in new_in_viol msaux_minus_old.betas_suffix_in in
    let alpha_betas = update_alpha_betas tp new_in_viol msaux_minus_old.alpha_betas in
    { msaux_minus_old with
      beta_alphas = beta_alphas
    ; beta_alphas_out = beta_alphas_out
    ; alpha_betas = alpha_betas
    ; betas_suffix_in = betas_suffix_in }

  let update_since interval tp ts p1 p2 msaux le =
    let a = get_a_I interval in
    (* Case 1: interval has not yet started, i.e.,
     \tau_{tp} < \tau_{0} + a OR \tau_{tp} - a < 0 *)
    if ((Option.is_none msaux.ts_zero) && (ts - a) < 0) ||
         (Option.is_some msaux.ts_zero) && ts < (Option.get msaux.ts_zero) + a then
      let l = (-1) in
      let r = (-1) in
      let msaux_ts_zero_updated = if Option.is_none msaux.ts_zero then
                                    { msaux with ts_zero = Some(ts) }
                                  else msaux in
      let msaux_ts_updated = update_ts (l, r) a ts msaux_ts_zero_updated in
      let msaux_updated = advance_msaux (l, r) tp ts p1 p2 msaux_ts_updated le in
      let p = V (VSinceOutL tp) in
      ([p], msaux_updated)
    (* Case 2: \tau_{tp-1} exists *)
    else
      let b = get_b_I interval in
      let l = if (Option.is_some b) then max 0 (ts - (Option.get b))
              else (Option.get msaux.ts_zero) in
      let r = ts - a in
      let msaux_ts_updated = update_ts (l, r) a ts msaux in
      let msaux_updated = advance_msaux (l, r) tp ts p1 p2 msaux_ts_updated le in
      (optimal_proof tp msaux_updated, msaux_updated)
end

module Future = struct
  type muaux = {
      ts_tp_in: (timestamp * timepoint) Deque.t
    ; ts_tp_out: (timestamp * timepoint) Deque.t
    (* deque of sorted deques of U^+ beta [alphas] proofs where (ets, lts, expl):
     * etc corresponds to the timestamp of the first alpha proof
     * lts corresponds to the timestamp of the beta proof *)
    ; alphas_beta: ((timestamp * timestamp * expl) Deque.t) Deque.t
    (* most recent sequence of alpha satisfactions w/o holes *)
    ; alphas_suffix: (timestamp * sexpl) Deque.t
    (* deque of sorted deques of U^- ~alpha [~betas] proofs where (ets, lts, expl):
     * ets corresponds to the timestamp of the first ~beta proof
     * lts corresponds to the timestamp of the ~alpha proof *)
    ; betas_alpha: ((timestamp * timestamp * expl) Deque.t) Deque.t
    (* deque of alpha proofs outside the interval *)
    ; alphas_out: (timestamp * expl) Deque.t
    (* deque of alpha violations inside the interval *)
    ; alphas_in: (timestamp * timepoint * vexpl option) Deque.t
    (* deque of beta violations inside the interval *)
    ; betas_suffix_in: (timestamp * vexpl) Deque.t
    ; }

  let muaux_to_string { ts_tp_in
                      ; ts_tp_out
                      ; alphas_beta
                      ; alphas_suffix
                      ; betas_alpha
                      ; alphas_out
                      ; alphas_in
                      ; betas_suffix_in } =
    "\n\nmuaux: " ^
      Deque.fold ts_tp_in ~init:"\nts_tp_in = ["
        ~f:(fun acc (ts, tp) -> acc ^ (Printf.sprintf "(%d,%d);" ts tp)) ^
      (Printf.sprintf "]\n") ^
      Deque.fold ts_tp_out ~init:"\nts_tp_out = ["
        ~f:(fun acc (ts, tp) -> acc ^ (Printf.sprintf "(%d,%d);" ts tp)) ^
      (Printf.sprintf "]\n") ^
      Deque.foldi alphas_beta ~init:"\nalphas_beta = \n"
        ~f:(fun i acc1 d ->
          acc1 ^ Printf.sprintf "\n%d.\n" i ^
          Deque.fold d ~init:"["
            ~f:(fun acc2 (ts1, ts2, ps) ->
              acc2 ^ (Printf.sprintf "\n(%d, %d)\n" ts1 ts2) ^
              Expl.expl_to_string ps) ^ "\n]\n") ^
      Deque.fold alphas_suffix ~init:"\nalphas_suffix = "
        ~f:(fun acc (ts, ps) ->
          acc ^ (Printf.sprintf "\n(%d)\n" ts) ^ Expl.s_to_string "" ps) ^
      Deque.foldi betas_alpha ~init:"\nbetas_alpha = \n"
        ~f:(fun i acc1 d ->
          acc1 ^ Printf.sprintf "\n%d.\n" i ^
          Deque.fold d ~init:"["
            ~f:(fun acc2 (ts1, ts2, ps) ->
              acc2 ^ (Printf.sprintf "\n(%d, %d)\n" ts1 ts2) ^
              Expl.expl_to_string ps) ^ "\n]\n") ^
      Deque.fold alphas_out ~init:"\nalphas_out = "
        ~f:(fun acc (ts, ps) ->
          acc ^ (Printf.sprintf "\n(%d)\n" ts) ^ Expl.expl_to_string ps) ^
      Deque.fold alphas_in ~init:"\nalphas_in = "
        ~f:(fun acc (ts1, ts2, ps) ->
          match ps with
          | None -> acc
          | Some(ps') ->
             acc ^ (Printf.sprintf "\n(%d, %d)\n" ts1 ts2) ^ Expl.v_to_string "" ps') ^
      Deque.fold betas_suffix_in ~init:"\nbetas_suffix_in = "
        ~f:(fun acc (ts, ps) ->
          acc ^ (Printf.sprintf "\n(%d)\n" ts) ^ Expl.v_to_string "" ps)

  let sdrop_from_deque tp z l d =
    let _ = List.iteri (Deque.to_list d) ~f:(fun i (ets, lts, ssp) ->
                match ssp with
                | S sp -> (if ets < z then
                             (if lts < z then Deque.drop_front d
                              else (match sp with
                                    | SUntil (sp2, sp1s) ->
                                       if not (List.is_empty sp1s) then
                                         Deque.set_exn d i (ets, lts, S (sdrop sp))
                                    | _ -> raise VEXPL))
                           else
                             (if lts < l then Deque.drop_front d
                              else (match sp with
                                    | SUntil (sp2, sp1s) ->
                                       if not (List.is_empty sp1s) then
                                         Deque.enqueue_back d (ets, lts, S (sdrop sp))
                                    | _ -> raise VEXPL)))
                | V _ -> raise SEXPL) in d

  let vdrop_from_deque tp l d =
    let _ = List.iteri (Deque.to_list d) ~f:(fun i (ets, lts, vvp) ->
                match vvp with
                | V vp ->
                   if ets < l then
                     (if lts < l then (Deque.drop_front d)
                      else (match vp with
                            | VUntil (tp, vp1, vp2s) ->
                               if not (List.is_empty vp2s) then
                                 Deque.set_exn d i (ets, lts, V (vdrop vp))
                            | _ -> raise SEXPL))
                   else
                     (if lts < l then Deque.drop_front d
                      else (match vp with
                            | VUntil (tp, vp1, vp2s) ->
                               if not (List.is_empty vp2s) then
                                 Deque.enqueue_back d (ets, lts, V (vdrop vp))
                            | _ -> raise SEXPL))
                | S _ -> raise VEXPL) in d

  let current ts_tp_out ts_tp_in =
    let ts_tp_list = (Deque.to_list ts_tp_out) @ (Deque.to_list ts_tp_in) in
    match List.hd ts_tp_list with
    | None -> []
    | Some((cur_ts, _)) -> List.filter ts_tp_list ~f:(fun (ts, tp) -> cur_ts = ts)

  let update_ts z l ts tp muaux =
    let _ = Deque.enqueue_back muaux.ts_tp_in (ts, tp) in
    let _ = List.iter (Deque.to_list muaux.ts_tp_in)
              ~f:(fun (ts', tp') ->
                if ts' < l then
                  let _ = Deque.enqueue_back muaux.ts_tp_out (ts', tp') in
                  Deque.drop_front muaux.ts_tp_in) in
    let _ = List.iter (Deque.to_list muaux.ts_tp_out)
              ~f:(fun (ts', tp') ->
                if ts' < z then Deque.drop_front muaux.ts_tp_out)
    in muaux

  let remove_out_less_dd lim d =
    let _ = Deque.iter d ~f:(fun d' ->
                List.iter (Deque.to_list d') ~f:(fun (ts1, ts2, _) ->
                    if ts2 < lim then Deque.drop_front d'))
    in d

  let remove_out_less lim d =
    let _ = List.iter (Deque.to_list d)
              ~f:(fun (ts, _) -> if ts < lim then Deque.drop_front d)
    in d

  let remove_out_less2 lim d =
    let _ = List.iter (Deque.to_list d)
              ~f:(fun (ts, _, _) -> if ts < lim then Deque.drop_front d)
    in d

  let split_in_out (l, r) d =
    let l = List.fold (Deque.to_list d) ~init:[]
              ~f:(fun acc (ts, p) ->
                if ts >= l then (
                  let _ = Deque.drop_front d in
                  if ts <= r then (ts, p)::acc
                  else acc)
                else acc)
    in (d, l)

  let split_in_out2 z l d =
    let lst = List.fold (Deque.to_list d) ~init:[]
                ~f:(fun acc (ts, _, vp1_opt) ->
                  if ts < l then (
                    let _ = Deque.drop_front d in
                    if ts >= z then
                      (match vp1_opt with
                       | None -> acc
                       | Some(vp1) -> (ts, V vp1)::acc)
                       else acc)
                    else acc)
    in (d, lst)

  let add_alphas_out ts vvp1 alphas_out le =
    let _ = List.iter (Deque.to_list alphas_out)
              ~f:(fun (_, vvp) ->
                if le vvp1 vvp then Deque.drop_front alphas_out) in
    let _ = Deque.enqueue_front alphas_out (ts, vvp1)
    in alphas_out

  let update_alphas_out ts alphas_out new_out_alphas le =
    let new_out_alphas_sorted = sort_ps le new_out_alphas in
    List.fold_left (List.rev (new_out_alphas_sorted)) ~init:(Deque.create ())
      ~f:(fun acc (_, vvp1) -> add_alphas_out ts vvp1 alphas_out le)

  let alphas_suffix_to_list alphas_suffix =
    List.rev(List.fold_left (Deque.to_list alphas_suffix) ~init:[]
               ~f:(fun acc (_, sp1) -> sp1::acc))

  let betas_suffix_in_to_list betas_suffix_in =
    List.rev(List.fold_left (Deque.to_list betas_suffix_in) ~init:[]
               ~f:(fun acc (_, vp2) -> vp2::acc))

  let add_to_muaux lts tp p1 p2 muaux le =
    match p1, p2 with
    | S sp1, S sp2 ->
       Printf.printf "SS\n";
       (* alphas_beta *)
       let cur_alphas_beta = Deque.peek_back_exn muaux.alphas_beta in
       let p1 = S (SUntil (sp2, (alphas_suffix_to_list muaux.alphas_suffix))) in
       let ets = match Deque.peek_front muaux.alphas_suffix with
         | Some(ts, _) -> ts
         | None -> lts in
       let _ = Deque.enqueue_back cur_alphas_beta (ets, lts, p1) in
       let cur_alphas_beta_sorted_list = sort_ps2 le (List.rev (Deque.to_list cur_alphas_beta)) in
       let _ = Deque.clear cur_alphas_beta in
       let _ = List.iter cur_alphas_beta_sorted_list ~f:(fun (e, l, p) ->
                   Deque.enqueue_back cur_alphas_beta (e, l, p)) in
       let _ = Deque.drop_back muaux.alphas_beta in
       let _ = Deque.enqueue_back muaux.alphas_beta cur_alphas_beta in
       (* alphas_suffix *)
       let _ = Deque.enqueue_back muaux.alphas_suffix (lts, sp1) in
       (* alphas_in *)
       let _ = Deque.enqueue_back muaux.alphas_in (lts, tp, None) in
       (* betas_suffix_in *)
       let _ = Deque.clear muaux.betas_suffix_in in
       muaux
    | S sp1, V vp2 ->
       Printf.printf "SV\n";
       (* alphas_suffix *)
       let _ = Deque.enqueue_back muaux.alphas_suffix (lts, sp1) in
       (* alphas_in *)
       let _ = Deque.enqueue_back muaux.alphas_in (lts, tp, None) in
       (* betas_suffix_in *)
       let _ = Deque.enqueue_back muaux.betas_suffix_in (lts, vp2) in
       muaux
    | V vp1, S sp2 ->
       Printf.printf "VS\n";
       (* alphas_beta *)
       let cur_alphas_beta = if not (Deque.is_empty (Deque.peek_back_exn muaux.alphas_beta))
                             then Deque.create ()
                             else Deque.peek_back_exn muaux.alphas_beta in
       let p1 = S (SUntil (sp2, (alphas_suffix_to_list muaux.alphas_suffix))) in
       let ets = match Deque.peek_front muaux.alphas_suffix with
         | Some(ts, _) -> ts
         | None -> lts in
       let _ = Deque.enqueue_back cur_alphas_beta (ets, lts, p1) in
       let cur_alphas_beta_sorted_list = sort_ps2 le (List.rev (Deque.to_list cur_alphas_beta)) in
       let _ = Deque.clear cur_alphas_beta in
       let _ = List.iter cur_alphas_beta_sorted_list ~f:(fun (e, l, p) ->
                   Deque.enqueue_back cur_alphas_beta (e, l, p)) in
       let _ = Deque.drop_back muaux.alphas_beta in
       let _ = Deque.enqueue_back muaux.alphas_beta cur_alphas_beta in
       (* alphas_suffix *)
       let _ = Deque.clear muaux.alphas_suffix in
       (* alphas_in *)
       let _ = Deque.enqueue_back muaux.alphas_in (lts, tp, Some(vp1)) in
       (* betas_suffix_in *)
       let _ = Deque.clear muaux.betas_suffix_in in
       muaux
    | V vp1, V vp2 ->
       Printf.printf "VV\n";
       (* alphas_suffix *)
       let _ = Deque.clear muaux.alphas_suffix in
       (* betas_suffix_in *)
       let _ = Deque.enqueue_back muaux.betas_suffix_in (lts, vp2) in
       (* betas_alpha *)
       let cur_betas_alpha = if not (Deque.is_empty (Deque.peek_back_exn muaux.betas_alpha))
                             then Deque.create ()
                             else Deque.peek_back_exn muaux.betas_alpha in
       let vp = V (VUntil (tp, vp1, (betas_suffix_in_to_list muaux.betas_suffix_in))) in
       let ets = match Deque.peek_front muaux.betas_suffix_in with
         | Some(ts, _) -> ts
         | None -> lts in
       let _ = Deque.enqueue_back cur_betas_alpha (ets, lts, vp) in
       let cur_betas_alpha_sorted_list = sort_ps2 le (List.rev (Deque.to_list cur_betas_alpha)) in
       let _ = Deque.clear cur_betas_alpha in
       let _ = List.iter cur_betas_alpha_sorted_list ~f:(fun (e, l, p) ->
                   Deque.enqueue_back cur_betas_alpha (e, l, p)) in
       let _ = Deque.drop_back muaux.betas_alpha in
       let _ = Deque.enqueue_back muaux.betas_alpha cur_betas_alpha in
       (* alphas_in *)
       let _ = Deque.enqueue_back muaux.alphas_in (lts, tp, Some(vp1)) in
       muaux

  let remove_from_muaux z l muaux =
    let alphas_suffix = remove_out_less z muaux.alphas_suffix in
    let alphas_out = remove_out_less z muaux.alphas_out in
    let alphas_in = remove_out_less2 z muaux.alphas_in in
    let betas_suffix_in = remove_out_less l muaux.betas_suffix_in in
    { muaux with
      alphas_suffix = alphas_suffix
    ; alphas_out = alphas_out
    ; alphas_in = alphas_in
    ; betas_suffix_in = betas_suffix_in }

  let drop_alphas_beta tp z l alphas_beta =
    let _ = if not (Deque.is_empty alphas_beta) then
              (if Deque.is_empty (Deque.peek_front_exn alphas_beta)
                  && (Deque.length alphas_beta) > 1 then
                 Deque.drop_front alphas_beta) in
    let _ = (match Deque.peek_front alphas_beta with
             | None -> failwith "muaux.alphas_beta must never be empty"
             | Some(d) -> if not (Deque.is_empty d) then
                            let first_alphas_beta = sdrop_from_deque tp z l d in
                            if not (Deque.is_empty first_alphas_beta) then
                              (let _ = Deque.drop_front alphas_beta in
                               Deque.enqueue_front alphas_beta first_alphas_beta))
    in alphas_beta

  let drop_betas_alpha tp l betas_alpha =
    let _ = if not (Deque.is_empty betas_alpha) then
              (if Deque.is_empty (Deque.peek_front_exn betas_alpha)
                  && (Deque.length betas_alpha) > 1 then
                 Deque.drop_front betas_alpha) in
    let _ = (match Deque.peek_front betas_alpha with
             | None -> failwith "muaux.betas_alpha must never be empty"
             | Some(d) -> if not (Deque.is_empty d) then
                            let first_betas_alpha = vdrop_from_deque tp l d in
                            if not (Deque.is_empty first_betas_alpha) then
                              (let _ = Deque.drop_front betas_alpha in
                               Deque.enqueue_front betas_alpha first_betas_alpha))
    in betas_alpha

  let drop_from_muaux tp z l muaux =
    let alphas_beta = drop_alphas_beta tp z l muaux.alphas_beta in
    let betas_alpha = drop_betas_alpha tp l muaux.betas_alpha in
    { muaux with
      alphas_beta
    ; betas_alpha }

  let advance_muaux (l, r) z ts tp p1 p2 muaux le =
    let muaux_minus_old = remove_from_muaux z l muaux in
    let muaux_dropped = drop_from_muaux tp z l muaux_minus_old in
    let muaux = add_to_muaux ts tp p1 p2 muaux_dropped le in
    let alphas_in, new_out_alphas = split_in_out2 z l muaux.alphas_in in
    let alphas_out = update_alphas_out ts muaux.alphas_out new_out_alphas le in
    { muaux with
      alphas_in
    ; alphas_out }

  let update_until interval tp ts p1 p2 muaux le =
    let a = get_a_I interval in
    let b = match get_b_I interval with
      | None -> failwith "Unbounded interval for future operators is not supported"
      | Some(b') -> b' in
    let z = max 0 (ts - b) in
    let l = max 0 (ts - (b - a)) in
    let r = ts in
    (* Printf.fprintf stdout "z = %d; l = %d; r = %d\n" z l r; *)
    let muaux_ts_updated = update_ts z l ts tp muaux in
    let muaux_updated = advance_muaux (l, r) z ts tp p1 p2 muaux_ts_updated le
    in muaux_updated

  let eval_until interval ts tp future_ts muaux =
    let _ = Printf.printf "eval tp = %d; ts = %d; future_ts = %d\n" tp ts future_ts in
    let b = match get_b_I interval with
      | None -> failwith "Unbounded interval for future operators is not supported"
      | Some(b') -> b' in
    if ts + b < future_ts then
      let _ = Printf.printf "SHOULD OUTPUT SOMETHING\n" in
      if not (Deque.is_empty muaux.alphas_beta) then
        let cur_alphas_beta = Deque.peek_front_exn muaux.alphas_beta in
        if not (Deque.is_empty cur_alphas_beta) then
          (match Deque.peek_front_exn cur_alphas_beta with
           | (_, _, S sp) -> if (s_at sp) = tp then [(S sp)]
                             else []
           | _ -> raise VEXPL)
        else (let p1_l = if not (Deque.is_empty muaux.betas_alpha) then
                           let cur_betas_alpha = Deque.peek_front_exn muaux.betas_alpha in
                           (if not (Deque.is_empty cur_betas_alpha) then
                              (* Every time we consider a VUntil proof its tp must be fixed *)
                              match Deque.peek_front_exn cur_betas_alpha with
                              | (_, _, V vp) -> if (v_at vp) = tp then [V vp]
                                                else []
                              | _ -> raise INVALID_FORM
                            else [])
                         else [] in
              let p2_l = if not (Deque.is_empty muaux.alphas_out) then
                           let vvp1 = snd(Deque.peek_front_exn muaux.alphas_out) in
                           match vvp1 with
                           | V vp1 -> [V (VUntil (tp, vp1, []))]
                           | S _ -> raise VEXPL
                         else [] in
              let p3_l = if (Deque.length muaux.betas_suffix_in) = (Deque.length muaux.ts_tp_in) then
                           let betas_suffix = betas_suffix_in_to_list muaux.betas_suffix_in in
                           [V (VUntilInf (tp, betas_suffix))]
                         else [] in
              (p1_l @ p2_l @ p3_l))
      else []
    else []
end

(* mbuf2: auxiliary data structure for the conj/disj operators *)
type mbuf2 = expl Deque.t * expl Deque.t

let mbuf2_add p1s p2s (d1, d2) =
  let _ = List.iter p1s ~f:(fun p1 -> Deque.enqueue_front d1 p1) in
  let _ = List.iter p2s ~f:(fun p2 -> Deque.enqueue_front d2 p2) in
  (d1, d2)

let rec mbuf2_take f (p1s, p2s) =
  match (Deque.is_empty p1s, Deque.is_empty p2s) with
  | true, _ -> (Deque.create (), (p1s, p2s))
  | _, true -> (Deque.create (), (p1s, p2s))
  | false, false -> let p1 = Deque.dequeue_front_exn p1s in
                    let p2 = Deque.dequeue_front_exn p2s in
                    let (p3s, buf') = mbuf2_take f (p1s, p2s) in
                    let _ = Deque.enqueue_front p3s (f p1 p2) in
                    (p3s, buf')

let rec mbuf2t_take f z (p1s, p2s) tss =
  match (Deque.is_empty p1s, Deque.is_empty p2s, Deque.is_empty tss) with
  | true, _, _ -> (z, (p1s, p2s), tss)
  | _, true, _ -> (z, (p1s, p2s), tss)
  | _, _, true -> (z, (p1s, p2s), tss)
  | false, false, false -> let p1 = Deque.dequeue_front_exn p1s in
                           let p2 = Deque.dequeue_front_exn p2s in
                           let ts = Deque.dequeue_front_exn tss in
                           mbuf2t_take f (f p1 p2 ts z) (p1s, p2s) tss

type mformula =
  | MTT
  | MFF
  | MP of string
  | MNeg of mformula
  | MConj of mformula * mformula * mbuf2
  | MDisj of mformula * mformula * mbuf2
  | MPrev of interval * mformula * bool * expl list * timestamp list
  | MNext of interval * mformula * bool * timestamp list
  | MSince of interval * mformula * mformula * mbuf2 * timestamp Deque.t * Past.msaux
  | MUntil of interval * mformula * mformula * mbuf2 * timestamp Deque.t * Future.muaux

let rec mformula_to_string l f =
  match f with
  | MP x -> Printf.sprintf "%s" x
  | MTT -> Printf.sprintf "⊤"
  | MFF -> Printf.sprintf "⊥"
  | MConj (f, g, _) -> Printf.sprintf (paren l 4 "%a ∧ %a") (fun x -> mformula_to_string 4) f (fun x -> mformula_to_string 4) g
  | MDisj (f, g, _) -> Printf.sprintf (paren l 3 "%a ∨ %a") (fun x -> mformula_to_string 3) f (fun x -> mformula_to_string 4) g
  | MNeg f -> Printf.sprintf "¬%a" (fun x -> mformula_to_string 5) f
  | MPrev (i, f, _, _, _) -> Printf.sprintf (paren l 5 "●%a %a") (fun x -> interval_to_string) i (fun x -> mformula_to_string 5) f
  | MNext (i, f, _, _) -> Printf.sprintf (paren l 5 "○%a %a") (fun x -> interval_to_string) i (fun x -> mformula_to_string 5) f
  | MSince (i, f, g, _, _, _) -> Printf.sprintf (paren l 0 "%a S%a %a") (fun x -> mformula_to_string 5) f (fun x -> interval_to_string) i (fun x -> mformula_to_string 5) g
  | MUntil (i, f, g, _, _, _) -> Printf.sprintf (paren l 0 "%a U%a %a") (fun x -> mformula_to_string 5) f (fun x -> interval_to_string) i (fun x -> mformula_to_string 5) g
let mformula_to_string = mformula_to_string 0

let relevant_ap mf =
  let rec aux mf =
    match mf with
    | MP x -> [x]
    | MTT -> []
    | MFF -> []
    | MConj (f, g, _) -> aux f @ aux g
    | MDisj (f, g, _) -> aux f @ aux g
    | MNeg f -> aux f
    | MPrev (i, f, _, _, _) -> aux f
    | MNext (i, f, _, _) -> aux f
    | MSince (i, f, g, _, _, _) -> aux f @ aux g
    | MUntil (i, f, g, _, _, _) -> aux f @ aux g in
  let lst_with_dup = aux mf in
  List.fold_left lst_with_dup ~init:[] ~f:(fun acc s ->
      if (List.mem acc s ~equal:(fun x y -> x = y)) then acc
      else s::acc)

let filter_ap sap mf_ap =
  Util.SS.filter (fun s -> List.mem mf_ap s ~equal:(fun x y -> x = y)) sap

type context =
  { tp: timepoint
  ; mf: mformula
  ; events: (Util.SS.t * timestamp) list
  }

let print_ps_list l =
  List.iter l ~f:(fun (ts, p) -> Printf.fprintf stdout "%s\n" (expl_to_string p))

(* Convert formula into a formula state *)
let rec minit f =
  match (value f) with
  | TT -> MTT
  | FF -> MFF
  | P (x) -> MP (x)
  | Neg (f) -> MNeg (minit f)
  | Conj (f, g) ->
     let buf = (Deque.create (), Deque.create ()) in
     MConj (minit f, minit g, buf)
  | Disj (f, g) ->
     let buf = (Deque.create (), Deque.create ()) in
     MDisj (minit f, minit g, buf)
  | Prev (i, f) -> MPrev (i, minit f, true, [], [])
  | Next (i, f) -> MNext (i, minit f, true, [])
  | Since (i, f, g) ->
     let buf = (Deque.create (), Deque.create ()) in
     let msaux = { Past.ts_zero = None
                 ; ts_in = Deque.create ()
                 ; ts_out = Deque.create ()
                 ; beta_alphas = Deque.create ()
                 ; beta_alphas_out = Deque.create ()
                 ; alpha_betas = Deque.create ()
                 ; alphas_out = Deque.create ()
                 ; betas_suffix_in = Deque.create ()
                 ; alphas_betas_out = Deque.create ()
                 ; } in
     MSince (i, minit f, minit g, buf, Deque.create (), msaux)
  | Until (i, f, g) ->
     let buf = (Deque.create (), Deque.create ()) in
     let empty_d1 = Deque.create () in
     let empty_d2 = Deque.create () in
     let alphas_beta = Deque.create () in
     let betas_alpha = Deque.create () in
     let _ = Deque.enqueue_front alphas_beta empty_d1 in
     let _ = Deque.enqueue_front betas_alpha empty_d2 in
     let muaux = { Future.ts_tp_in = Deque.create ()
                 ; ts_tp_out = Deque.create ()
                 ; alphas_beta = alphas_beta
                 ; alphas_suffix = Deque.create ()
                 ; betas_alpha = betas_alpha
                 ; alphas_out = Deque.create ()
                 ; alphas_in = Deque.create ()
                 ; betas_suffix_in = Deque.create ()
                 ; } in
     MUntil (i, minit f, minit g, buf, Deque.create (), muaux)
  | _ -> failwith "This formula cannot be monitored"

let do_disj minimum2 expl_f1 expl_f2 =
  match expl_f1, expl_f2 with
  | S f1, S f2 -> minimum2 (S (SDisjL (f1))) (S (SDisjR(f2)))
  | S f1, V _ -> S (SDisjL (f1))
  | V _ , S f2 -> S (SDisjR (f2))
  | V f1, V f2 -> V (VDisj (f1, f2))

let do_conj minimum2 expl_f1 expl_f2 =
  match expl_f1, expl_f2 with
  | S f1, S f2 -> S (SConj (f1, f2))
  | S _ , V f2 -> V (VConjR (f2))
  | V f1, S _ -> V (VConjL (f1))
  | V f1, V f2 -> minimum2 (V (VConjL (f1))) (V (VConjR (f2)))

let meval' tp ts sap mform le minimuml =
  let minimum2 a b = minimuml [a; b] in
  (* TODO: This function should return (Deque.t, mformula) *)
  let rec meval tp ts sap mform =
    match mform with
    | MTT -> ([S (STT tp)], MTT)
    | MFF -> ([V (VFF tp)], MFF)
    | MP a ->
       if Util.SS.mem a sap then ([S (SAtom (tp, a))], MP a)
       else ([V (VAtom (tp, a))], MP a)
    | MNeg (mf) ->
       let (ps_f, mf') = meval tp ts sap mf in
       let ps_z = List.map ps_f ~f:(fun p ->
                      match p with
                      | S p' -> V (VNeg p')
                      | V p' -> S (SNeg p')) in
       (ps_z, MNeg(mf'))
    | MConj (mf1, mf2, buf) ->
       let op p1 p2 = do_conj minimum2 p1 p2 in
       let (p1s, mf1') = meval tp ts sap mf1 in
       let (p2s, mf2') = meval tp ts sap mf2 in
       let (ps, buf') = mbuf2_take op (mbuf2_add p1s p2s buf) in
       ((Deque.to_list ps), MConj (mf1', mf2', buf'))
    | MDisj (mf1, mf2, buf) ->
       let op p1 p2 = do_disj minimum2 p1 p2 in
       let (p1s, mf1') = meval tp ts sap mf1 in
       let (p2s, mf2') = meval tp ts sap mf2 in
       let (ps, buf') = mbuf2_take op (mbuf2_add p1s p2s buf) in
       ((Deque.to_list ps), MDisj (mf1', mf2', buf'))
    (* | MPrev (interval, mf, b, expl_lst, ts_d_lst) ->
     * | MNext (interval, mf, b, ts_a_lst) -> *)
    | MSince (interval, mf1, mf2, buf, tss, msaux) ->
       let (p1s, mf1') = meval tp ts sap mf1 in
       let (p2s, mf2') = meval tp ts sap mf2 in
       let _ = Deque.enqueue_back tss ts in
       let ((ps, msaux'), buf', tss') =
         mbuf2t_take
           (fun p1 p2 ts (ps, aux) ->
             let (cps, aux) = Past.update_since interval tp ts p1 p2 msaux le in
             let op = minimuml cps in
             let _ = Deque.enqueue_back ps op in
             (ps, aux))
           (Deque.create (), msaux) (mbuf2_add p1s p2s buf) tss
       (* let _ = Printf.fprintf stdout "---------------\n%s\n\n" (Past.msaux_to_string new_msaux) in
        * let _ = Printf.fprintf stdout "Optimal proof:\n%s\n\n" (Expl.expl_to_string p) in *)
       in ((Deque.to_list ps), MSince (interval, mf1', mf2', buf', tss', msaux'))
    (* | MUntil (interval, mf1, mf2, buf, tss, muaux) ->
     *    let (ps_f1, mf1') = meval tp ts sap mf1 in
     *    let (ps_f2, mf2') = meval tp ts sap mf2 in
     *    if not (List.is_empty ps_f1) && not (List.is_empty ps_f2) then
     *      let p1 = minimuml ps_f1 in
     *      let p2 = minimuml ps_f2 in
     *      (\* let _ = Printf.printf "---------------\n" in
     *       * let _ = Printf.printf "mf = %s\n" (mformula_to_string (MUntil (interval, mf1, mf2, buf, muaux))) in *\)
     *      let new_muaux = Future.update_until interval tp ts p1 p2 muaux le in
     *      let ts_tp_list = Future.current new_muaux.ts_tp_out new_muaux.ts_tp_in in
     *      (\* let _ = Printf.fprintf stdout "%s\n\n" (Future.muaux_to_string new_muaux) in
     *       * let _ = Printf.printf "current ts = %d\n" ts in
     *       * let _ = List.iter ts_tp_list ~f:(fun (ts', tp') -> (Printf.printf "ts' = %d; tp' = %d\n" ts' tp')) in *\)
     *      let ops = List.rev (List.fold ts_tp_list ~init:[] ~f:(fun acc (ts', tp') ->
     *                              let ps = Future.eval_until interval ts' tp' ts new_muaux in
     *                              if (List.is_empty ps) then acc
     *                              else (minimuml ps)::acc)) in
     *      (\* let _ = if not (List.is_empty ops) then
     *       *           List.iter ops ~f:(fun p ->
     *       *               Printf.fprintf stdout "Optimal proof:\n%s\n\n" (Expl.expl_to_string p)) in *\)
     *      (ops, MUntil (interval, mf1', mf2', buf, new_muaux))
     *    else ([], MUntil (interval, mf1', mf2', buf, muaux)) *)
    | _ -> failwith "This formula cannot be monitored" in
  meval tp ts sap mform

let monitor in_ch out_ch mode debug check le f =
  let minimuml ps = minsize_list (get_mins le ps) in
  let rec loop f x = loop f (f x) in
  let mf = minit f in
  let mf_ap = relevant_ap mf in
  let _ = preamble out_ch mode f in
  let ctx = { tp = 0
            ; mf = mf
            ; events = [] } in
  let s (ctx, in_ch) =
    let ((sap, ts), in_ch) = input_event in_ch out_ch in
    let sap_filtered = filter_ap sap mf_ap in
    let events_updated = (sap_filtered, ts)::ctx.events in
    let (ps, mf_updated) = meval' ctx.tp ts sap_filtered ctx.mf le minimuml in
    let checker_ps = if check || debug then Some (check_ps events_updated f ps) else None in
    let _ = print_ps out_ch mode ts ctx.tp ps checker_ps debug in
    let ctx_updated = { tp = ctx.tp+1
                      ; mf = mf_updated
                      ; events = events_updated } in
    (ctx_updated, in_ch) in
  loop s (ctx, in_ch)
