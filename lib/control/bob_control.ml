open Bob_types

type config = {
  yaw_limit_deg : float;
  pitch_limit_deg : float;
  association_tolerance_deg : float;
  association_margin_deg : float;
  max_say_chars : int;
  identity_threshold : float;
}

let default_config =
  { yaw_limit_deg = 90.;
    pitch_limit_deg = 30.;
    association_tolerance_deg = 35.;
    (* Nearest track must beat the runner-up by this margin, else refuse. *)
    association_margin_deg = 15.;
    max_say_chars = 600;
    identity_threshold = 0.6 }

(* Actions the brain may propose (SPEC section 22). *)
type action =
  | Say of string
  | Look_at of { yaw : Angle.t; pitch : Angle.t }
  | Ask_name of Track_id.t
  | Recall_more of string
  | Noop

(* Decisions the controller emits. These are not side effects; the driver
   interprets them. *)
type decision =
  | Look_at_angle of { yaw : Angle.t; pitch : Angle.t; reason : string }
  | Recognise of Track_id.t
  | Invoke_brain of { utterance : string; speaker : Person_id.t option }
  | Set_attention of Track_id.t
  | Interrupt_speech
  | Preload_profile of Person_id.t

(* Speaker association (SPEC section 10): nearest visible track to the DoA,
   but only if it is within tolerance AND clearly better than the runner-up.
   Ambiguity refuses rather than guesses. *)
let associate_speaker ~config ~now ~world ~doa =
  let tracks = Bob_world.visible_tracks ~now world in
  let scored =
    List.filter_map
      (fun (t : Bob_world.track) ->
        match Bob_world.bearing_of ~now world t.Bob_world.id with
        | None -> None
        | Some b ->
            let d = Float.abs (Angle.to_deg b -. Angle.to_deg doa) in
            Some (t.Bob_world.id, d))
      tracks
  in
  let sorted = List.sort (fun (_, a) (_, b) -> Float.compare a b) scored in
  match sorted with
  | [] -> None
  | [ (id, d) ] -> if d <= config.association_tolerance_deg then Some id else None
  | (id, d1) :: (_, d2) :: _ ->
      if d1 <= config.association_tolerance_deg
         && d2 -. d1 >= config.association_margin_deg
      then Some id
      else None

let clamp limit d =
  let v = Angle.to_deg d in
  Angle.deg (if v > limit then limit else if v < -.limit then -.limit else v)

(* Validation (SPEC section 30): the brain proposes, the controller disposes.
   Out-of-range yaw is REJECTED, not silently clamped, because a model asking
   for 200 degrees has misunderstood something and should be told. Pitch
   inside its own limit passes through unchanged. *)
let validate ~config (a : action) : (action, string) result =
  match a with
  | Say "" -> Error "empty speech"
  | Say s when String.length s > config.max_say_chars ->
      Error
        (Printf.sprintf "speech too long: %d > %d" (String.length s)
           config.max_say_chars)
  | Say _ -> Ok a
  | Look_at p ->
      let y = Angle.to_deg p.yaw and pi = Angle.to_deg p.pitch in
      if Float.abs y > config.yaw_limit_deg then
        Error (Printf.sprintf "yaw %.0f outside limit %.0f" y config.yaw_limit_deg)
      else if Float.abs pi > config.pitch_limit_deg then
        Error
          (Printf.sprintf "pitch %.0f outside limit %.0f" pi config.pitch_limit_deg)
      else
        Ok
          (Look_at
             { yaw = clamp config.yaw_limit_deg p.yaw;
               pitch = clamp config.pitch_limit_deg p.pitch })
  | Ask_name _ -> Ok a
  | Recall_more "" -> Error "empty recall query"
  | Recall_more _ -> Ok a
  | Noop -> Ok a

(* The deterministic attention/cognition policy (SPEC section 16). *)
let decide ~config ~now ~world ~workspace (e : Bob_events.t) : decision list =
  ignore workspace;
  match e with
  | Bob_events.Speech_started x -> (
      (* Reflex path. No STT, no brain. SPEC section 34. *)
      let interrupt =
        if Bob_world.speech_active world then [ Interrupt_speech ] else []
      in
      match x.doa with
      | None -> interrupt
      | Some doa ->
          let look =
            Look_at_angle
              { yaw = clamp config.yaw_limit_deg doa;
                pitch = Angle.deg 0.;
                reason = "speech onset" }
          in
          let attend =
            match associate_speaker ~config ~now ~world ~doa with
            | Some t -> [ Set_attention t ]
            | None -> []
          in
          interrupt @ (look :: attend))
  | Bob_events.Speech_direction x -> (
      match associate_speaker ~config ~now ~world ~doa:x.doa with
      | Some t -> [ Set_attention t ]
      | None -> [])
  | Bob_events.Person_entered x ->
      (* A new face is worth identifying, but presence alone never triggers
         cognition (SPEC section 16: "nobody is interacting -> do not invoke
         brain"). *)
      [ Recognise x.track ]
  | Bob_events.Person_identified x ->
      if Confidence.to_float x.confidence >= config.identity_threshold then
        [ Preload_profile x.person ]
      else []
  | Bob_events.Utterance x ->
      [ Invoke_brain { utterance = x.text; speaker = x.speaker } ]
  | Bob_events.Partial_utterance _ -> []
  | Bob_events.Speech_ended _ | Bob_events.Person_moved _
  | Bob_events.Person_left _ | Bob_events.Head_moved _ ->
      []

let pp_decision fmt = function
  | Look_at_angle p ->
      Format.fprintf fmt "look yaw=%.0f pitch=%.0f (%s)" (Angle.to_deg p.yaw)
        (Angle.to_deg p.pitch) p.reason
  | Recognise t -> Format.fprintf fmt "recognise %a" Track_id.pp t
  | Invoke_brain b -> Format.fprintf fmt "invoke_brain %S" b.utterance
  | Set_attention t -> Format.fprintf fmt "attention %a" Track_id.pp t
  | Interrupt_speech -> Format.fprintf fmt "interrupt_speech"
  | Preload_profile p -> Format.fprintf fmt "preload %s" (Person_id.to_string p)
