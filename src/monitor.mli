(*******************************************************************)
(*     This is part of WhyMon, and it is distributed under the     *)
(*     terms of the GNU Lesser General Public License version 3    *)
(*           (see file LICENSE for more details)                   *)
(*                                                                 *)
(*  Copyright 2023:                                                *)
(*  Leonardo Lima (UCPH)                                           *)
(*******************************************************************)

open Base
open Etc

module MFormula : sig

  type t

  val to_string: t -> string

  val init: Formula.t -> t

end

module MState : sig

  type t

  val tp_cur: t -> timepoint

  val tsdbs: t -> (timestamp * Db.t) Queue.t

  val init: MFormula.t -> t

end

val mstep: Out.Plain.mode -> string list -> timestamp -> Db.t -> MState.t ->
           ((timestamp * timepoint) * Expl.Proof.t Expl.Pdt.t) list * MState.t

val exec: Out.Plain.mode -> string -> Formula.t -> in_channel -> unit

val exec_vis: MState.t option -> Formula.t -> string -> (MState.t * string)
