open Bob_types

(* --- Parsing --- *)

(* Split a line into tokens, keeping "quoted strings" together. *)
let tokenise line =
  let buf = Buffer.create 32 in
  let out = ref [] in
  let in_quotes = ref false in
  String.iter
    (fun c ->
      match c with
      | '"' -> in_quotes := not !in_quotes
      | ' ' when not !in_quotes ->
          if Buffer.length buf > 0 then (
            out := Buffer.contents buf :: !out;
            Buffer.clear buf)
      | c -> Buffer.add_char buf c)
    line;
  if Buffer.length buf > 0 then out := Buffer.contents buf :: !out;
  List.rev !out

let split_kv tok =
  match String.index_opt tok '=' with
  | None -> None
  | Some i ->
      Some
        (String.sub tok 0 i, String.sub tok (i + 1) (String.length tok - i - 1))

let parse_event_line line =
  let toks = tokenise line in
  match toks with
  | [] -> Ok None
  | t_tok :: kind :: kvs -> (
      match split_kv t_tok with
      | Some ("t", secs) -> (
          match float_of_string_opt secs with
          | None -> Error ("bad timestamp: " ^ secs)
          | Some s ->
              let fields = List.filter_map split_kv kvs in
              let json =
                `Assoc
                  (("kind", `String kind)
                  :: ("at", `Float (s *. 1000.))
                  :: List.filter_map
                       (fun (k, v) ->
                         match k with
                         | "text" | "person" | "language" -> Some (k, `String v)
                         | "track" | "speaker_track" -> (
                             match int_of_string_opt v with
                             | Some i -> Some (k, `Int i)
                             | None -> None)
                         | "speaker" -> Some (k, `String v)
                         | _ -> (
                             match float_of_string_opt v with
                             | Some f -> Some (k, `Float f)
                             | None -> Some (k, `String v)))
                       fields)
              in
              (* confidence defaults to 1.0 when a trace omits it *)
              let json =
                match json with
                | `Assoc kvs when not (List.mem_assoc "confidence" kvs) ->
                    `Assoc (("confidence", `Float 1.0) :: kvs)
                | j -> j
              in
              Bob_events.of_json json |> Result.map Option.some)
      | _ -> Error ("expected t=<seconds> at line start: " ^ line))
  | _ -> Error ("malformed line: " ^ line)

let is_blank s = String.trim s = ""
let is_comment s = String.length (String.trim s) > 0 && (String.trim s).[0] = '#'

let parse_string contents =
  let lines = String.split_on_char '\n' contents in
  let rec go acc = function
    | [] -> Ok (List.rev acc)
    | l :: rest ->
        if is_blank l || is_comment l then go acc rest
        else (
          match parse_event_line l with
          | Error m -> Error m
          | Ok None -> go acc rest
          | Ok (Some e) -> go (e :: acc) rest)
  in
  go [] lines

let parse_file path =
  let ic = open_in_bin path in
  let contents =
    Fun.protect
      ~finally:(fun () -> close_in ic)
      (fun () -> really_input_string ic (in_channel_length ic))
  in
  parse_string contents

(* --- Replay driver --- *)

type result = {
  world : Bob_world.t;
  workspace : Bob_workspace.t;
  obs : Bob_obs.t;
  decisions : (Time.t * Bob_control.decision) list;
  errors : string list;
}

(* The replay driver drives the body: Look_at_angle is the reflex path, so
   this takes the embodied grant rather than the conversational one. Parsing
   stays outside the functor - bin/bob_replay.ml parses before it has a
   handler stack to run under. *)
module Make (C : Bob_capability.EMBODIED_CAPABILITIES) = struct
  let replay ?(config = Bob_control.default_config)
      ?(ttl = Bob_world.default_ttl)
      ?(ws_config = Bob_workspace.default_config) evs =
    let world = ref (Bob_world.empty ~ttl) in
    let workspace = ref (Bob_workspace.empty ~config:ws_config) in
    let obs = ref (Bob_obs.empty ()) in
    let decisions = ref [] in
    let errors = ref [] in
    let err m = errors := m :: !errors in

    let execute ~now (d : Bob_control.decision) =
      decisions := (now, d) :: !decisions;
      match d with
      | Bob_control.Look_at_angle p -> (
          obs := Bob_obs.mark !obs ~at:now Bob_obs.Movement_start;
          match C.look_at (Bob_domain.Body.Bearing p.yaw) with
          | Ok () -> ()
          | Error e -> err ("body: " ^ Bob_domain.Body.error_to_string e))
      | Bob_control.Set_attention t -> workspace := Bob_workspace.set_attention !workspace (Some t)
      | Bob_control.Interrupt_speech -> ()
      | Bob_control.Recognise _ -> ()
      | Bob_control.Preload_profile _ -> ()
      | Bob_control.Invoke_brain b ->
          obs := Bob_obs.mark !obs ~at:now Bob_obs.Llm_request;
          let items =
            match b.speaker with
            | Some person ->
                C.recall
                  Bob_domain.Memory.{ text = b.utterance; person = Some person }
            | None -> []
          in
          let profile =
            match items with
            | [] -> None
            | l -> Some (String.concat "\n" (List.map (fun i -> "- " ^ i.Bob_domain.Memory.text) l))
          in
          obs := Bob_obs.mark !obs ~at:now Bob_obs.Memory_retrieved;
          let context =
            Bob_project.render ~now ~world:!world ~workspace:!workspace ~profile ~episodes:[]
          in
          let req =
            Bob_domain.Brain.
              { context; utterance = b.utterance; speaker = b.speaker }
          in
          let stream = C.think req in
          obs := Bob_obs.mark !obs ~at:now Bob_obs.Llm_first_token;
          let buf = Buffer.create 128 in
          let failed = ref None in
          let rec drain () =
            match Eio.Stream.take stream with
            | Bob_domain.Brain.Text t ->
                if Buffer.length buf > 0 then Buffer.add_char buf ' ';
                Buffer.add_string buf t;
                drain ()
            | Bob_domain.Brain.Failed e -> failed := Some e
          in
          drain ();
          let reply = Buffer.contents buf in
          if reply = "" then (
            match !failed with
            | Some e -> err ("brain: " ^ Bob_domain.Brain.error_to_string e)
            | None -> ())
          else (
            match Bob_control.validate ~config (Bob_control.Say reply) with
            | Error m -> err ("rejected action: " ^ m)
            | Ok (Bob_control.Say s) -> (
                obs := Bob_obs.mark !obs ~at:now Bob_obs.Tts_first_sample;
                let out = Eio.Stream.create 4 in
                Eio.Stream.add out (Bob_domain.Speech.Say s);
                Eio.Stream.add out Bob_domain.Speech.End;
                match C.speak out with
                | Ok () -> obs := Bob_obs.mark !obs ~at:now Bob_obs.First_audio
                | Error e -> err ("tts: " ^ Bob_domain.Speech.error_to_string e))
            | Ok (Bob_control.Look_at p) -> (
                match C.look_at (Bob_domain.Body.Bearing p.yaw) with
                | Ok () -> ()
                | Error e -> err ("body: " ^ Bob_domain.Body.error_to_string e))
            | Ok (Bob_control.Ask_name _) -> ()
            | Ok (Bob_control.Recall_more _) -> ()
            | Ok Bob_control.Noop -> ())
    in

    List.iter
      (fun e ->
        let now = Bob_events.at e in
        (* Observability marks that come straight from the event stream. *)
        (match e with
        | Bob_events.Speech_started _ -> obs := Bob_obs.mark !obs ~at:now Bob_obs.Speech_start
        | Bob_events.Speech_ended _ -> obs := Bob_obs.mark !obs ~at:now Bob_obs.Speech_end
        | Bob_events.Speech_direction _ -> obs := Bob_obs.mark !obs ~at:now Bob_obs.Doa_update
        | Bob_events.Partial_utterance _ ->
            obs := Bob_obs.mark !obs ~at:now Bob_obs.Stt_first_partial
        | Bob_events.Utterance _ -> obs := Bob_obs.mark !obs ~at:now Bob_obs.Stt_final
        | _ -> ());
        (* Reduce, decide, execute. This is SPEC section 33's direction.

           The controller decides against the world as it was WHEN THE EVENT
           ARRIVED, not after the event has been folded in. "Was Bob speaking
           when this speech started?" is a question about the prior state; asking
           it of the post-apply world makes Speech_started interrupt itself. *)
        let world_before = !world in
        world := Bob_world.apply !world e;
        workspace := Bob_workspace.apply !workspace e;
        let ds =
          Bob_control.decide ~config ~now ~world:world_before ~workspace:!workspace e
        in
        List.iter (execute ~now) ds;
        world := Bob_world.expire ~now !world;
        workspace := Bob_workspace.tick ~now !workspace)
      evs;

    { world = !world;
      workspace = !workspace;
      obs = !obs;
      decisions = List.rev !decisions;
      errors = List.rev !errors }
end
