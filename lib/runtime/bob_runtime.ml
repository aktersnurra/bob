open Effect.Deep

(* Patch 002 §12 + correction C1.

   Effect handlers do NOT cross Eio.Fiber.fork: a perform inside a forked
   fiber raises Effect.Unhandled, because Eio fibers are themselves built on
   effects and forking installs Eio's own handler.

   Therefore every fiber must install its own handler stack. All forking in
   cognitive code goes through Bob_runtime.fork. A bare Eio.Fiber.fork in
   cognitive code is a bug, and test_runtime asserts that it fails loudly. *)

type trace_entry = string * float
type trace = { mutable entries : trace_entry list }

let new_trace () = { entries = [] }
let trace_entries t = List.rev t.entries
let trace_names t = List.rev_map fst t.entries |> List.rev

(* §20 + correction C5.

   A perform inside a handler escapes OUTWARD to the enclosing handler, so
   tracing must nest INSIDE the interpreting handler:

     with_sim (fun () -> with_tracing (fun () -> f ()))   captures
     with_tracing (fun () -> with_sim (fun () -> f ()))   captures NOTHING

   The wrong order does not error, so getting it backwards is a silent
   failure. Only names and durations are recorded: §20 forbids logging raw
   prompts or audio. *)
let with_tracing trace f =
  match_with f ()
    { retc = (fun v -> v);
      exnc = raise;
      effc =
        (fun (type a) (e : a Effect.t) ->
          match Bob_effect.name_of e with
          | None -> None
          | Some name ->
              Some
                (fun (k : (a, _) continuation) ->
                  let t0 = Unix.gettimeofday () in
                  (* Re-perform: the enclosing interpreting handler services it. *)
                  let v = Effect.perform e in
                  let dt = (Unix.gettimeofday () -. t0) *. 1000. in
                  trace.entries <- (name, dt) :: trace.entries;
                  continue k v)) }

let maybe_trace trace f =
  match trace with None -> f | Some tr -> fun () -> with_tracing tr f

(* Install the sim handler stack around f. Interpreting handler outside,
   tracing inside (C5). *)
let with_sim ?trace ?clock sim sw f =
  Bob_handler_sim.handle sim ?clock sw (maybe_trace trace f)

(* THE spawn helper. Every fork in cognitive code uses this. *)
let fork ~sw ~sim ?trace ?clock f =
  Eio.Fiber.fork ~sw (fun () -> with_sim ?trace ?clock sim sw f)

(* Run a whole simulated session. The callback receives the switch so it can
   fork further fibers through Bob_runtime.fork. *)
let run_sim ?trace sim f =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw -> with_sim ?trace ~clock sim sw (fun () -> f sw)
