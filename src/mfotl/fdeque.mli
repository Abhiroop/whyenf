(*******************************************************************)
(*     This is part of Explanator2, it is distributed under the    *)
(*     terms of the GNU Lesser General Public License version 3    *)
(*           (see file LICENSE for more details)                   *)
(*                                                                 *)
(*  Copyright 2023:                                                *)
(*  Dmitriy Traytel (UCPH)                                         *)
(*  Leonardo Lima (UCPH)                                           *)
(*******************************************************************)

open Core_kernel

type 'a t = 'a Deque.t

val enqueue_front: 'a t -> 'a -> 'a t

val enqueue_back: 'a t -> 'a -> 'a t

val drop_front: 'a t -> 'a t

val is_empty: 'a t -> bool

val peek_back_exn: 'a t -> 'a

val peek_front_exn: 'a t -> 'a

val fold: 'a t -> init: 'b -> f:('b -> 'a -> 'b) -> 'b
