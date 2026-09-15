open Bob_types

(* SPEC section 1.2: small interfaces, explicit injection, swappable
   implementations. Function records rather than functors or singletons. *)

module Clock = struct
  type t = { now : unit -> Time.t }

  (* Phase 0 is entirely deterministic: a fake clock the test drives. *)
  let fake ~start =
    let cur = ref start in
    let t = { now = (fun () -> !cur) } in
    (t, fun ms -> cur := Time.of_ms ms)
end

module Brain = struct
  type request = {
    context : string;
    utterance : string;
    speaker : Person_id.t option;
  }

  type response = { actions : Bob_control.action list }
  type t = { think : request -> (response, string) result }

  (* Returns a fixed reply; records what it was asked so tests can assert on
     the projected context. *)
  let fake ?(reply = "Jag vet inte. Ska vi ta reda på det?") () =
    let last = ref None in
    let think (r : request) =
      last := Some r;
      Ok { actions = [ Bob_control.Say reply ] }
    in
    ({ think }, fun () -> !last)

  let failing ~message = { think = (fun _ -> Error message) }
end

module Body = struct
  type command =
    | Look of { yaw : Angle.t; pitch : Angle.t }
    | Expression of string
    | Blink

  type t = { send : command -> (unit, string) result }

  let fake () =
    let log = ref [] in
    ({ send = (fun c -> log := c :: !log; Ok ()) }, fun () -> List.rev !log)
end

module Tts = struct
  type t = { speak : string -> (unit, string) result; stop : unit -> unit }

  let fake () =
    let spoken = ref [] in
    let stopped = ref 0 in
    ( { speak = (fun s -> spoken := s :: !spoken; Ok ());
        stop = (fun () -> incr stopped) },
      fun () -> (List.rev !spoken, !stopped) )
end

module Stt = struct
  type t = { feed : bytes -> unit; final : unit -> string option }

  let fake ~transcript =
    let given = ref false in
    { feed = (fun _ -> ());
      final = (fun () -> if !given then None else (given := true; Some transcript)) }
end
