open Bob_types
open Effect.Deep

(* Patch 002 §7 replay environment, §8 replayability.

   A recorded interaction must run with no hardware, no network and no LLM.
   Running out of recorded results is an ERROR, never a silent fallback -- a
   replay that quietly starts behaving live is worse than one that stops. *)

exception Exhausted of string

type recording = {
  times : Time.t list;
  recalls : Bob_domain.Memory.item list list;
  thinks : string list;
  identities : Bob_domain.Identity.result list;
}

type action = Looked of Bob_domain.Body.target | Spoke of string

type t = {
  mutable times : Time.t list;
  mutable recalls : Bob_domain.Memory.item list list;
  mutable thinks : string list;
  mutable identities : Bob_domain.Identity.result list;
  mutable actions : action list;
}

let create (r : recording) =
  { times = r.times; recalls = r.recalls; thinks = r.thinks;
    identities = r.identities; actions = [] }

let actions t = List.rev t.actions

let pop name lst =
  match !lst with
  | [] -> raise (Exhausted name)
  | x :: rest ->
      lst := rest;
      x

let words s = String.split_on_char ' ' s |> List.filter (fun w -> w <> "")

let handle t _sw f =
  match_with f ()
    { retc = (fun v -> v);
      exnc = raise;
      effc =
        (fun (type a) (e : a Effect.t) ->
          match e with
          | Bob_effect.Now ->
              Some
                (fun (k : (a, _) continuation) ->
                  let r = ref t.times in
                  let v = pop "Now" r in
                  t.times <- !r;
                  continue k v)
          | Bob_effect.Recall _ ->
              Some
                (fun (k : (a, _) continuation) ->
                  let r = ref t.recalls in
                  let v = pop "Recall" r in
                  t.recalls <- !r;
                  continue k v)
          | Bob_effect.Think _ ->
              Some
                (fun (k : (a, _) continuation) ->
                  let r = ref t.thinks in
                  let reply = pop "Think" r in
                  t.thinks <- !r;
                  let s = Eio.Stream.create (List.length (words reply) + 2) in
                  List.iter (fun w -> Eio.Stream.add s (Bob_domain.Brain.Text w)) (words reply);
                  Eio.Stream.add s (Bob_domain.Brain.Failed Bob_domain.Brain.Invalid_response);
                  continue k s)
          | Bob_effect.Speak stream ->
              Some
                (fun (k : (a, _) continuation) ->
                  let b = Buffer.create 64 in
                  let rec d () =
                    match Eio.Stream.take stream with
                    | Bob_domain.Speech.End -> ()
                    | Bob_domain.Speech.Say s -> Buffer.add_string b s; d ()
                  in
                  d ();
                  t.actions <- Spoke (Buffer.contents b) :: t.actions;
                  continue k (Ok ()))
          | Bob_effect.Look_at target ->
              Some
                (fun (k : (a, _) continuation) ->
                  t.actions <- Looked target :: t.actions;
                  continue k (Ok ()))
          | Bob_effect.Identify _ ->
              Some
                (fun (k : (a, _) continuation) ->
                  let r = ref t.identities in
                  let v = pop "Identify" r in
                  t.identities <- !r;
                  continue k v)
          | _ -> None) }

let run t f = Eio_main.run @@ fun _env -> Eio.Switch.run @@ fun sw -> handle t sw f

(* `handle` takes the switch for signature symmetry with the sim handler even
   though replay spawns no fiber: every chunk is added to a stream sized to
   hold all of them, so nothing blocks and nothing needs forking. *)
