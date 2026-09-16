open Bob_types
open Effect.Deep

(* Patch 002 §7 simulation environment: deterministic, records what cognition
   did so scenario tests (§21) assert on actions rather than internals. *)

type action =
  | Looked of Bob_effect.Body.target
  | Spoke of string
  | Recalled of string
  | Thought of string
  | Identified of Track_id.t

type t = {
  mutable now : Time.t;
  mutable actions : action list; (* reverse order *)
  memory : Bob_effect.Memory.item list;
  brain_reply : string;
  brain_fails_after : int option;
  identity : Bob_effect.Identity.result;
  (* Seconds to pause between chunks. 0 means never sleep, so the common
     tests stay fast. Task 8 uses a non-zero value to exercise cancellation;
     the field exists from the start so `handle`'s signature never changes. *)
  chunk_delay : float;
}

let create ~start ?(memory = []) ?(brain_reply = "Jag vet inte.")
    ?brain_fails_after ?(identity = Bob_effect.Identity.Unknown)
    ?(chunk_delay = 0.) () =
  { now = start; actions = []; memory; brain_reply; brain_fails_after; identity;
    chunk_delay }

let advance t ms = t.now <- Time.add t.now ms
let actions t = List.rev t.actions
let record t a = t.actions <- a :: t.actions

(* Split a reply into word chunks so streaming is exercised rather than
   simulated as one blob. *)
let words s = String.split_on_char ' ' s |> List.filter (fun w -> w <> "")

let drain_brain (s : Bob_effect.Brain.response) =
  let rec go acc =
    match Eio.Stream.take s with
    | Bob_effect.Brain.Text t -> go (if acc = "" then t else acc ^ " " ^ t)
    | Bob_effect.Brain.Failed _ -> acc
  in
  go ""

(* The handler. It needs a switch to fork producer fibers for streaming brain
   responses, so `run` takes one from Eio_main.

   `?clock` is optional and unused while chunk_delay is 0. It is present from
   the start so Task 8 can add pacing without changing this signature. *)
let pace t clock =
  if t.chunk_delay > 0. then
    match clock with Some c -> Eio.Time.sleep c t.chunk_delay | None -> ()

let handle t ?clock sw f =
  match_with f ()
    { retc = (fun v -> v);
      exnc = raise;
      effc =
        (fun (type a) (e : a Effect.t) ->
          match e with
          | Bob_effect.Now ->
              Some (fun (k : (a, _) continuation) -> continue k t.now)
          | Bob_effect.Recall q ->
              Some
                (fun (k : (a, _) continuation) ->
                  record t (Recalled q.Bob_effect.Memory.text);
                  continue k t.memory)
          | Bob_effect.Think r ->
              Some
                (fun (k : (a, _) continuation) ->
                  record t (Thought r.Bob_effect.Brain.utterance);
                  let stream = Eio.Stream.create 16 in
                  (* §10: produce concurrently so the consumer may start
                     before generation finishes. *)
                  Eio.Fiber.fork ~sw (fun () ->
                      let ws = words t.brain_reply in
                      List.iteri
                        (fun i w ->
                          pace t clock;
                          match t.brain_fails_after with
                          | Some n when i >= n ->
                              if i = n then
                                Eio.Stream.add stream
                                  (Bob_effect.Brain.Failed
                                     Bob_effect.Brain.Rate_limited)
                          | _ -> Eio.Stream.add stream (Bob_effect.Brain.Text w))
                        ws;
                      match t.brain_fails_after with
                      | Some n when n < List.length ws -> ()
                      | _ ->
                          Eio.Stream.add stream
                            (Bob_effect.Brain.Failed Bob_effect.Brain.Invalid_response));
                  continue k stream)
          | Bob_effect.Speak stream ->
              Some
                (fun (k : (a, _) continuation) ->
                  (* Record incrementally, not only at the end: a speech
                     cancelled partway must leave evidence of what was
                     actually said, or Task 8 cannot tell partial from
                     absent. *)
                  let buf = Buffer.create 64 in
                  let commit () =
                    t.actions <-
                      (match t.actions with
                      | Spoke _ :: rest -> Spoke (Buffer.contents buf) :: rest
                      | l -> Spoke (Buffer.contents buf) :: l)
                  in
                  let rec drain () =
                    match Eio.Stream.take stream with
                    | Bob_effect.Speech.End -> ()
                    | Bob_effect.Speech.Say s ->
                        pace t clock;
                        Buffer.add_string buf s;
                        commit ();
                        drain ()
                  in
                  drain ();
                  commit ();
                  continue k (Ok ()))
          | Bob_effect.Look_at target ->
              Some
                (fun (k : (a, _) continuation) ->
                  record t (Looked target);
                  continue k (Ok ()))
          | Bob_effect.Identify r ->
              Some
                (fun (k : (a, _) continuation) ->
                  record t (Identified r.Bob_effect.Identity.track);
                  continue k t.identity)
          | _ -> None) }

(* Convenience: run a cognitive function under the sim environment, supplying
   its own Eio runtime. Tests call this. *)
let run t f =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw -> handle t ~clock sw f

(* Like run, but hands the callback the clock so tests can impose timeouts
   (Task 8 uses this for cancellation). *)
let run_with_clock t f =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw -> handle t ~clock sw (fun () -> f clock)
