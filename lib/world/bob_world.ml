open Bob_types

(* TTLs are configurable (SPEC section 14). Defaults are the spec's
   conceptual orders of magnitude. *)
type ttl = {
  track_ms : float;
  bearing_ms : float;
  identity_ms : float;
  doa_ms : float;
  speaker_ms : float;
}

let default_ttl =
  { track_ms = 5_000.; bearing_ms = 5_000.; identity_ms = 30_000.;
    doa_ms = 2_000.; speaker_ms = 5_000. }

module Track_map = Map.Make (struct
  type t = Track_id.t

  let compare = Track_id.compare
end)

type track = {
  id : Track_id.t;
  bearing : Angle.t Observation.t;
  identity : (Person_id.t * Confidence.t) Observation.t option;
  last_seen : Time.t;
}

type t = {
  ttl : ttl;
  tracks : track Track_map.t;
  doa : Angle.t Observation.t option;
  speaker : Track_id.t Observation.t option;
  head_yaw : Angle.t;
  head_pitch : Angle.t;
  speech_active : bool;
}

let empty ~ttl =
  { ttl; tracks = Track_map.empty; doa = None; speaker = None;
    head_yaw = Angle.deg 0.; head_pitch = Angle.deg 0.; speech_active = false }

let obs ~value ~confidence ~observed_at ~source =
  Observation.make ~value ~confidence ~observed_at ~source

let rec apply w (e : Bob_events.t) =
  match e with
  | Bob_events.Person_entered x ->
      let t =
        { id = x.track;
          bearing =
            obs ~value:x.bearing ~confidence:(Confidence.v 1.0)
              ~observed_at:x.at ~source:Observation.Vision;
          identity = None;
          last_seen = x.at }
      in
      { w with tracks = Track_map.add x.track t w.tracks }
  | Bob_events.Person_moved x -> (
      match Track_map.find_opt x.track w.tracks with
      | None ->
          (* A move for an unseen track is treated as an appearance. *)
          apply w
            (Bob_events.Person_entered
               { at = x.at; track = x.track; bearing = x.bearing })
      | Some t ->
          let t =
            { t with
              bearing =
                obs ~value:x.bearing ~confidence:(Confidence.v 1.0)
                  ~observed_at:x.at ~source:Observation.Vision;
              last_seen = x.at }
          in
          { w with tracks = Track_map.add x.track t w.tracks })
  | Bob_events.Person_left x ->
      { w with tracks = Track_map.remove x.track w.tracks }
  | Bob_events.Person_identified x -> (
      match Track_map.find_opt x.track w.tracks with
      | None -> w (* identity for a track we do not have: ignore *)
      | Some t ->
          let incoming =
            obs
              ~value:(x.person, x.confidence)
              ~confidence:x.confidence ~observed_at:x.at
              ~source:Observation.Identity_model
          in
          let keep =
            match t.identity with
            | Some cur
              when Confidence.to_float cur.Observation.confidence
                   > Confidence.to_float x.confidence ->
                Some cur
            | _ -> Some incoming
          in
          { w with tracks = Track_map.add x.track { t with identity = keep } w.tracks })
  | Bob_events.Speech_direction x ->
      { w with
        doa =
          Some
            (obs ~value:x.doa ~confidence:x.confidence ~observed_at:x.at
               ~source:Observation.Audio) }
  | Bob_events.Speech_started x ->
      let w = { w with speech_active = true } in
      (match x.doa with
      | None -> w
      | Some d ->
          { w with
            doa =
              Some
                (obs ~value:d ~confidence:x.confidence ~observed_at:x.at
                   ~source:Observation.Audio) })
  | Bob_events.Speech_ended _ -> { w with speech_active = false }
  | Bob_events.Head_moved x -> { w with head_yaw = x.yaw; head_pitch = x.pitch }
  | Bob_events.Partial_utterance _ | Bob_events.Utterance _ -> w

let fresh ~now ~ttl_ms (o : 'a Observation.t) =
  if Observation.is_stale ~now ~ttl_ms o then None else Some o

let visible_tracks ~now w =
  Track_map.bindings w.tracks
  |> List.filter_map (fun (_, t) ->
         if Time.diff_ms t.last_seen now > w.ttl.track_ms then None else Some t)

let track_count w = Track_map.cardinal w.tracks

let bearing_of ~now w id =
  match Track_map.find_opt id w.tracks with
  | None -> None
  | Some t ->
      fresh ~now ~ttl_ms:w.ttl.bearing_ms t.bearing
      |> Option.map (fun o -> o.Observation.value)

let identity_of ~now w id =
  match Track_map.find_opt id w.tracks with
  | None -> None
  | Some t -> (
      match t.identity with
      | None -> None
      | Some o ->
          fresh ~now ~ttl_ms:w.ttl.identity_ms o
          |> Option.map (fun o -> o.Observation.value))

let last_doa ~now w =
  match w.doa with
  | None -> None
  | Some o ->
      fresh ~now ~ttl_ms:w.ttl.doa_ms o
      |> Option.map (fun o -> o.Observation.value)

let speaker_track ~now w =
  match w.speaker with
  | None -> None
  | Some o ->
      fresh ~now ~ttl_ms:w.ttl.speaker_ms o
      |> Option.map (fun o -> o.Observation.value)

let set_speaker ~at ~confidence w track =
  { w with
    speaker =
      Some
        (obs ~value:track ~confidence ~observed_at:at ~source:Observation.Inference) }

let head_pose w = (w.head_yaw, w.head_pitch)
let speech_active w = w.speech_active

(* Physically drop anything past its TTL. Accessors already hide stale data;
   this keeps memory bounded during long runs. *)
let expire ~now w =
  let tracks =
    Track_map.filter
      (fun _ t -> Time.diff_ms t.last_seen now <= w.ttl.track_ms)
      w.tracks
  in
  let doa =
    match w.doa with
    | Some o when not (Observation.is_stale ~now ~ttl_ms:w.ttl.doa_ms o) -> Some o
    | _ -> None
  in
  let speaker =
    match w.speaker with
    | Some o when not (Observation.is_stale ~now ~ttl_ms:w.ttl.speaker_ms o) -> Some o
    | _ -> None
  in
  { w with tracks; doa; speaker }
