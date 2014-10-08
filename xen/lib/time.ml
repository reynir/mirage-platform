(* Lightweight thread library for Objective Caml
 * http://www.ocsigen.org/lwt
 * Module Lwt_mirage, based on Lwt_unix
 * Copyright (C) 2010 Anil Madhavapeddy
 * Copyright (C) 2005-2008 J�r�me Vouillon
 * Laboratoire PPS - CNRS Universit� Paris Diderot
 *                    2009 J�r�mie Dimino
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as
 * published by the Free Software Foundation, with linking exceptions;
 * either version 2.1 of the License, or (at your option) any later
 * version. See COPYING file for details.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA
 * 02111-1307, USA.
 *)

open Lwt

type +'a io = 'a Lwt.t

module Monotonic = struct
  type time_kind = [`Time | `Interval]
  type 'a t = int64 constraint 'a = [< time_kind]

  external time : unit -> int64 = "caml_get_monotonic_time"

  let of_seconds x = Int64.of_float (x *. 1_000_000_000.)
  let to_seconds x = Int64.to_float x /.  1_000_000_000.

  let ( + ) = ( Int64.add )
  let ( - ) = ( Int64.sub )
  let interval = ( Int64.sub )
end

(* +-----------------------------------------------------------------+
   | Sleepers                                                        |
   +-----------------------------------------------------------------+ *)

type sleep = {
  time : [`Time] Monotonic.t;
  mutable canceled : bool;
  thread : unit Lwt.u;
}

module SleepQueue =
  Lwt_pqueue.Make (struct
                     type t = sleep
                     let compare { time = t1 } { time = t2 } = compare t1 t2
                   end)

(* Threads waiting for a timeout to expire: *)
let sleep_queue = ref SleepQueue.empty

(* Sleepers added since the last iteration of the main loop:

   They are not added immediatly to the main sleep queue in order to
   prevent them from being wakeup immediatly by [restart_threads].
*)
let new_sleeps = ref []

let sleep d =
  let (res, w) = MProf.Trace.named_task "sleep" in
  let t = if d <= 0. then 0L else Monotonic.(time () + of_seconds d) in
  let sleeper = { time = t; canceled = false; thread = w } in
  new_sleeps := sleeper :: !new_sleeps;
  Lwt.on_cancel res (fun _ -> sleeper.canceled <- true);
  res

exception Timeout

let timeout d = sleep d >> Lwt.fail Timeout

let with_timeout d f = Lwt.pick [timeout d; Lwt.apply f ()]

let in_the_past now t =
  t = 0L || t <= now ()

let rec restart_threads now =
  match SleepQueue.lookup_min !sleep_queue with
    | Some{ canceled = true } ->
        sleep_queue := SleepQueue.remove_min !sleep_queue;
        restart_threads now
    | Some{ time = time; thread = thread } when in_the_past now time ->
        sleep_queue := SleepQueue.remove_min !sleep_queue;
        Lwt.wakeup thread ();
        restart_threads now
    | _ ->
        ()

(* +-----------------------------------------------------------------+
   | Event loop                                                      |
   +-----------------------------------------------------------------+ *)

let min_timeout a b = match a, b with
  | None, b -> b
  | a, None -> a
  | Some a, Some b -> Some(min a b)

let rec get_next_timeout () =
  match SleepQueue.lookup_min !sleep_queue with
    | Some{ canceled = true } ->
        sleep_queue := SleepQueue.remove_min !sleep_queue;
        get_next_timeout ()
    | Some{ time = time } ->
        Some time
    | None ->
        None

let select_next () =
  (* Transfer all sleepers added since the last iteration to the main
     sleep queue: *)
  sleep_queue :=
    List.fold_left
      (fun q e -> SleepQueue.add e q) !sleep_queue !new_sleeps;
  new_sleeps := [];
  get_next_timeout ()
