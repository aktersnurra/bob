open Bob_types

(* Patch 002 §3: a small semantic vocabulary. Six effects. §25 forbids
   growing this into a framework.

   §6: Effect.perform appears ONLY in this file. Everything else calls the
   typed wrappers below. *)

module Memory0 = struct
  type query = { text : string; person : Person_id.t option }
  type item = { text : string; source : string }

  type error = Unavailable | Corrupt of string

  let error_to_string = function
    | Unavailable -> "memory unavailable"
    | Corrupt m -> "memory corrupt: " ^ m
end

module Brain0 = struct
  type request = {
    context : string;
    utterance : string;
    speaker : Person_id.t option;
  }

  type error = Timeout | Unavailable | Rate_limited | Invalid_response

  let error_to_string = function
    | Timeout -> "timeout"
    | Unavailable -> "unavailable"
    | Rate_limited -> "rate_limited"
    | Invalid_response -> "invalid_response"

  (* C4: §10 wants a stream, §19 wants typed errors. A stream that has already
     been returned cannot fail with a result-typed error, because the failure
     happens after Think returned. So the error travels IN the stream.
     Consumers must handle Failed at any position, including first. *)
  type chunk = Text of string | Failed of error

  type response = chunk Eio.Stream.t
end

module Speech0 = struct
  (* §11: speech is incremental. The handler consumes chunks as they arrive
     rather than waiting for a complete utterance. *)
  type chunk = Say of string | End
  type stream = chunk Eio.Stream.t
  type error = Device_unavailable | Interrupted

  let error_to_string = function
    | Device_unavailable -> "speech device unavailable"
    | Interrupted -> "interrupted"
end

module Body0 = struct
  (* §3: semantic, not mechanical. Look_at a target, never Set_servo_pwm. *)
  type target =
    | Bearing of Angle.t
    | Person of Person_id.t
    | Track of Track_id.t
    | Neutral

  type error = Unreachable | Rejected of string | Disconnected

  let error_to_string = function
    | Unreachable -> "target unreachable"
    | Rejected m -> "rejected: " ^ m
    | Disconnected -> "body disconnected"
end

module Identity0 = struct
  type request = { track : Track_id.t }

  type result =
    | Matched of Person_id.t * Confidence.t
    | Unknown
    | Uncertain of (Person_id.t * Confidence.t) list

  type error = Worker_unavailable | No_face
end

(* --- The effects. C3: one += per constructor, GADT return on each. --- *)

type _ Effect.t += Now : Time.t Effect.t
type _ Effect.t += Recall : Memory0.query -> Memory0.item list Effect.t
type _ Effect.t += Think : Brain0.request -> Brain0.response Effect.t
type _ Effect.t += Speak : Speech0.stream -> (unit, Speech0.error) result Effect.t
type _ Effect.t += Look_at : Body0.target -> (unit, Body0.error) result Effect.t
type _ Effect.t += Identify : Identity0.request -> Identity0.result Effect.t

(* --- §6: typed wrappers. The rest of Bob calls these, never perform. --- *)

module Clock = struct
  let now () = Effect.perform Now
end

module Memory_op = struct
  let recall q = Effect.perform (Recall q)
end

module Brain_op = struct
  let think r = Effect.perform (Think r)
end

module Speech_op = struct
  let say s = Effect.perform (Speak s)
end

module Body_op = struct
  let look_at t = Effect.perform (Look_at t)
end

module Identity_op = struct
  let identify r = Effect.perform (Identify r)
end

(* Re-export the wrappers onto the type modules so call sites read as
   Bob_effect.Memory.recall rather than Bob_effect.Memory_op.recall. *)
module Memory = struct
  include Memory0

  let recall = Memory_op.recall
end

module Brain = struct
  include Brain0

  let think = Brain_op.think
end

module Speech = struct
  include Speech0

  let say = Speech_op.say
end

module Body = struct
  include Body0

  let look_at = Body_op.look_at
end

module Identity = struct
  include Identity0

  let identify = Identity_op.identify
end

(* A human-readable name per effect, for the tracing handler (§20). *)
let name_of : type a. a Effect.t -> string option = function
  | Now -> Some "Now"
  | Recall _ -> Some "Recall"
  | Think _ -> Some "Think"
  | Speak _ -> Some "Speak"
  | Look_at _ -> Some "Look_at"
  | Identify _ -> Some "Identify"
  | _ -> None
