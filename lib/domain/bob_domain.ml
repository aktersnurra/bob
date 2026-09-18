open Bob_types

(* Patch 002 §3 domain vocabulary, split out of bob_effect so that modules
   which must NOT be able to act can still name the types they exchange.

   This library holds types ONLY. The effect constructors and the perform
   wrappers live in bob_effect, which cognition and the replay driver are
   deliberately unable to depend on. See
   docs/superpowers/specs/2026-09-17-capability-authority-design.md *)

module Memory = struct
  type query = { text : string; person : Person_id.t option }
  type item = { text : string; source : string }

  type error = Unavailable | Corrupt of string

  let error_to_string = function
    | Unavailable -> "memory unavailable"
    | Corrupt m -> "memory corrupt: " ^ m
end

module Brain = struct
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

module Speech = struct
  (* §11: speech is incremental. The handler consumes chunks as they arrive
     rather than waiting for a complete utterance. *)
  type chunk = Say of string | End
  type stream = chunk Eio.Stream.t
  type error = Device_unavailable | Interrupted

  let error_to_string = function
    | Device_unavailable -> "speech device unavailable"
    | Interrupted -> "interrupted"
end

module Body = struct
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

module Identity = struct
  type request = { track : Track_id.t }

  type result =
    | Matched of Person_id.t * Confidence.t
    | Unknown
    | Uncertain of (Person_id.t * Confidence.t) list

  type error = Worker_unavailable | No_face
end
