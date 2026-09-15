module Confidence = struct
  type t = float

  let v f = if f < 0. then 0. else if f > 1. then 1. else f
  let to_float t = t
  let pp fmt t = Format.fprintf fmt "%.2f" t
end

module Time = struct
  (* Monotonic milliseconds since an arbitrary origin. Phase 0 uses a fake
     clock, so this is a plain float rather than Mtime.t — the replay harness
     must be able to construct any instant. *)
  type t = float

  let of_ms ms = ms
  let to_ms t = t
  let add t ms = t +. ms
  let diff_ms a b = b -. a
  let compare = Float.compare
  let pp fmt t = Format.fprintf fmt "%.3fs" (t /. 1000.)
end

module Person_id = struct
  type t = string

  let v s = s
  let to_string t = t
  let equal = String.equal
  let compare = String.compare
  let fresh () = Uuidm.v4_gen (Random.State.make_self_init ()) () |> Uuidm.to_string
end

module Track_id = struct
  type t = int

  let v i = i
  let to_int t = t
  let equal = Int.equal
  let compare = Int.compare
  let pp fmt t = Format.fprintf fmt "track_%d" t
end

module Episode_id = struct
  type t = string

  let v s = s
  let to_string t = t
  let fresh () = Uuidm.v4_gen (Random.State.make_self_init ()) () |> Uuidm.to_string
end

module Angle = struct
  (* Degrees, normalised to (-180, 180]. Robot-left is negative. *)
  type t = float

  let deg d =
    let d = Float.rem d 360. in
    if d > 180. then d -. 360. else if d <= -180. then d +. 360. else d

  let to_deg t = t
  let pp fmt t = Format.fprintf fmt "%.0f deg" t
end

module Observation = struct
  type source = Vision | Audio | Identity_model | Memory | Inference

  type 'a t = {
    value : 'a;
    confidence : Confidence.t;
    observed_at : Time.t;
    source : source;
  }

  let make ~value ~confidence ~observed_at ~source =
    { value; confidence; observed_at; source }

  let is_stale ~now ~ttl_ms t = Time.diff_ms t.observed_at now > ttl_ms

  let source_to_string = function
    | Vision -> "vision"
    | Audio -> "audio"
    | Identity_model -> "identity_model"
    | Memory -> "memory"
    | Inference -> "inference"
end
