open Bob_types

type speech_started = {
  at : Time.t;
  doa : Angle.t option;
  confidence : Confidence.t;
}

type speech_ended = { at : Time.t }

type speech_direction = {
  at : Time.t;
  doa : Angle.t;
  confidence : Confidence.t;
}

type person_entered = { at : Time.t; track : Track_id.t; bearing : Angle.t }
type person_left = { at : Time.t; track : Track_id.t }

type person_moved = { at : Time.t; track : Track_id.t; bearing : Angle.t }

type person_identified = {
  at : Time.t;
  track : Track_id.t;
  person : Person_id.t;
  confidence : Confidence.t;
}

type partial_utterance = { at : Time.t; text : string }

type utterance = {
  at : Time.t;
  text : string;
  speaker : Person_id.t option;
  speaker_track : Track_id.t option;
  language : string option;
}

type head_moved = { at : Time.t; yaw : Angle.t; pitch : Angle.t }

type t =
  | Speech_started of speech_started
  | Speech_direction of speech_direction
  | Speech_ended of speech_ended
  | Partial_utterance of partial_utterance
  | Utterance of utterance
  | Person_entered of person_entered
  | Person_moved of person_moved
  | Person_left of person_left
  | Person_identified of person_identified
  | Head_moved of head_moved

let at = function
  | Speech_started e -> e.at
  | Speech_direction e -> e.at
  | Speech_ended e -> e.at
  | Partial_utterance e -> e.at
  | Utterance e -> e.at
  | Person_entered e -> e.at
  | Person_moved e -> e.at
  | Person_left e -> e.at
  | Person_identified e -> e.at
  | Head_moved e -> e.at

let kind = function
  | Speech_started _ -> "speech_started"
  | Speech_direction _ -> "speech_direction"
  | Speech_ended _ -> "speech_ended"
  | Partial_utterance _ -> "partial_utterance"
  | Utterance _ -> "utterance"
  | Person_entered _ -> "person_entered"
  | Person_moved _ -> "person_moved"
  | Person_left _ -> "person_left"
  | Person_identified _ -> "person_identified"
  | Head_moved _ -> "head_moved"

let equal a b = a = b

let pp fmt e =
  Format.fprintf fmt "%s@%.0fms" (kind e) (at e |> Time.to_ms)

(* --- JSON --- *)

let jf name v = (name, `Float v)
let js name v = (name, `String v)

let opt_angle = function
  | None -> `Null
  | Some a -> `Float (Angle.to_deg a)

let base e extra =
  `Assoc
    (("kind", `String (kind e))
    :: jf "at" (at e |> Time.to_ms)
    :: extra)

let to_json e =
  match e with
  | Speech_started x ->
      base e
        [ ("doa", opt_angle x.doa);
          jf "confidence" (Confidence.to_float x.confidence) ]
  | Speech_direction x ->
      base e
        [ jf "doa" (Angle.to_deg x.doa);
          jf "confidence" (Confidence.to_float x.confidence) ]
  | Speech_ended _ -> base e []
  | Partial_utterance x -> base e [ js "text" x.text ]
  | Utterance x ->
      base e
        [ js "text" x.text;
          ( "speaker",
            match x.speaker with
            | None -> `Null
            | Some p -> `String (Person_id.to_string p) );
          ( "speaker_track",
            match x.speaker_track with
            | None -> `Null
            | Some t -> `Int (Track_id.to_int t) );
          ( "language",
            match x.language with None -> `Null | Some l -> `String l ) ]
  | Person_entered x ->
      base e
        [ ("track", `Int (Track_id.to_int x.track));
          jf "bearing" (Angle.to_deg x.bearing) ]
  | Person_moved x ->
      base e
        [ ("track", `Int (Track_id.to_int x.track));
          jf "bearing" (Angle.to_deg x.bearing) ]
  | Person_left x -> base e [ ("track", `Int (Track_id.to_int x.track)) ]
  | Person_identified x ->
      base e
        [ ("track", `Int (Track_id.to_int x.track));
          js "person" (Person_id.to_string x.person);
          jf "confidence" (Confidence.to_float x.confidence) ]
  | Head_moved x ->
      base e
        [ jf "yaw" (Angle.to_deg x.yaw); jf "pitch" (Angle.to_deg x.pitch) ]

(* Decoding helpers. Return Error rather than raising: a malformed event from
   a Phase 1 worker must not take the core down. *)

exception Bad of string

let mem k = function
  | `Assoc kvs -> ( try Some (List.assoc k kvs) with Not_found -> None)
  | _ -> None

let num k j =
  match mem k j with
  | Some (`Float f) -> f
  | Some (`Int i) -> float_of_int i
  | _ -> raise (Bad ("missing number: " ^ k))

let str k j =
  match mem k j with
  | Some (`String s) -> s
  | _ -> raise (Bad ("missing string: " ^ k))

let int_ k j =
  match mem k j with
  | Some (`Int i) -> i
  | Some (`Float f) -> int_of_float f
  | _ -> raise (Bad ("missing int: " ^ k))

let opt_str k j =
  match mem k j with Some (`String s) -> Some s | _ -> None

let opt_int k j =
  match mem k j with
  | Some (`Int i) -> Some i
  | Some (`Float f) -> Some (int_of_float f)
  | _ -> None

let opt_num k j =
  match mem k j with
  | Some (`Float f) -> Some f
  | Some (`Int i) -> Some (float_of_int i)
  | _ -> None

let of_json j =
  try
    let at = Time.of_ms (num "at" j) in
    let conf () = Confidence.v (num "confidence" j) in
    match str "kind" j with
    | "speech_started" ->
        Ok
          (Speech_started
             { at;
               doa = Option.map Angle.deg (opt_num "doa" j);
               confidence = conf () })
    | "speech_direction" ->
        Ok
          (Speech_direction
             { at; doa = Angle.deg (num "doa" j); confidence = conf () })
    | "speech_ended" -> Ok (Speech_ended { at })
    | "partial_utterance" ->
        Ok (Partial_utterance { at; text = str "text" j })
    | "utterance" ->
        Ok
          (Utterance
             { at;
               text = str "text" j;
               speaker = Option.map Person_id.v (opt_str "speaker" j);
               speaker_track = Option.map Track_id.v (opt_int "speaker_track" j);
               language = opt_str "language" j })
    | "person_entered" ->
        Ok
          (Person_entered
             { at;
               track = Track_id.v (int_ "track" j);
               bearing = Angle.deg (num "bearing" j) })
    | "person_moved" ->
        Ok
          (Person_moved
             { at;
               track = Track_id.v (int_ "track" j);
               bearing = Angle.deg (num "bearing" j) })
    | "person_left" ->
        Ok (Person_left { at; track = Track_id.v (int_ "track" j) })
    | "person_identified" ->
        Ok
          (Person_identified
             { at;
               track = Track_id.v (int_ "track" j);
               person = Person_id.v (str "person" j);
               confidence = conf () })
    | "head_moved" ->
        Ok
          (Head_moved
             { at; yaw = Angle.deg (num "yaw" j); pitch = Angle.deg (num "pitch" j) })
    | k -> Error ("unknown event kind: " ^ k)
  with
  | Bad m -> Error m
  | Not_found -> Error "malformed event"
