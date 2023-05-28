(*******************************************************************)
(*     This is part of Explanator2, it is distributed under the    *)
(*     terms of the GNU Lesser General Public License version 3    *)
(*           (see file LICENSE for more details)                   *)
(*                                                                 *)
(*  Copyright 2023:                                                *)
(*  Dmitriy Traytel (UCPH)                                         *)
(*  Leonardo Lima (UCPH)                                           *)
(*******************************************************************)

open Base

module T = struct

  type tt = TInt | TStr | TFloat [@@deriving compare, sexp_of, hash]

  type t = Int of int | Str of string | Float of float [@@deriving compare, sexp_of, hash]

  let equal d d' = match d, d' with
    | Int v, Int v' -> Int.equal v v'
    | Str v, Str v' -> String.equal v v'
    | Float v, Float v' -> Float.equal v v'
    | _ -> false

  let tt_of_string = function
    | "int" -> TInt
    | "string" -> TStr
    | "float" -> TFloat
    | t -> raise (Invalid_argument (Printf.sprintf "type %s is not supported" t))

  let tt_of_domain = function
    | Int _ -> TInt
    | Str _ -> TStr
    | Float _ -> TFloat

  let tt_to_string = function
    | TInt -> "int"
    | TStr -> "string"
    | TFloat -> "float"

  let tt_default = function
    | TInt -> Int 0
    | TStr -> Str ""
    | TFloat -> Float 0.0

  let string_to_t s tt = match tt with
    | TInt -> (try Int (int_of_string s)
               with Failure _ -> raise (Invalid_argument (Printf.sprintf "%s is not an int" s)))
    | TStr -> Str s
    | TFloat -> (try Float (float_of_string s)
                 with Failure _ -> raise (Invalid_argument (Printf.sprintf "%s is not a float" s)))

  let to_string = function
    | Int v -> string_of_int v
    | Str v -> v
    | Float v -> string_of_float v

  let list_to_string ds =
    String.drop_suffix (List.fold ds ~init:"" ~f:(fun acc d -> acc ^ (to_string d) ^ ", ")) 2

end

include T
include Comparator.Make(T)
