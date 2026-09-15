open Bob_types

type config = {
  episode_idle_ms : float;
  max_turns : int;
}

let default_config = { episode_idle_ms = 600_000. (* 10 min *); max_turns = 20 }

type turn = {
  at : Time.t;
  text : string;
  speaker : Person_id.t option;
}

type episode = {
  id : Episode_id.t;
  started_at : Time.t;
  participants : Person_id.t list;
  turns : turn list; (* chronological *)
}

type t = {
  config : config;
  episode : episode option;
  speaker : Person_id.t option;
  attention : Track_id.t option;
  topic : string option;
  goal : string option;
  last_activity : Time.t;
  (* Set when tick closes an episode; cleared once read. *)
  just_closed : episode option;
}

let empty ~config =
  { config; episode = None; speaker = None; attention = None; topic = None;
    goal = None; last_activity = Time.of_ms 0.; just_closed = None }

let take_last n l =
  let len = List.length l in
  if len <= n then l else List.filteri (fun i _ -> i >= len - n) l

let add_participant p ps =
  match p with
  | None -> ps
  | Some p -> if List.exists (Person_id.equal p) ps then ps else ps @ [ p ]

let apply ws (e : Bob_events.t) =
  match e with
  | Bob_events.Utterance x ->
      let turn = { at = x.at; text = x.text; speaker = x.speaker } in
      let ep =
        match ws.episode with
        | Some ep ->
            { ep with
              turns = take_last ws.config.max_turns (ep.turns @ [ turn ]);
              participants = add_participant x.speaker ep.participants }
        | None ->
            { id = Episode_id.fresh ();
              started_at = x.at;
              participants = add_participant x.speaker [];
              turns = [ turn ] }
      in
      { ws with
        episode = Some ep;
        speaker = (match x.speaker with Some _ -> x.speaker | None -> ws.speaker);
        last_activity = x.at }
  | Bob_events.Speech_started x -> { ws with last_activity = x.at }
  | Bob_events.Partial_utterance x -> { ws with last_activity = x.at }
  | Bob_events.Person_identified x ->
      (* If this track is who we are attending to, it names the speaker. *)
      if ws.attention = Some x.track then
        { ws with speaker = Some x.person }
      else ws
  | Bob_events.Speech_ended _ | Bob_events.Speech_direction _
  | Bob_events.Person_entered _ | Bob_events.Person_moved _
  | Bob_events.Person_left _ | Bob_events.Head_moved _ ->
      ws

let close_episode ws =
  match ws.episode with
  | None -> ws
  | Some ep ->
      { ws with
        episode = None;
        just_closed = Some ep;
        speaker = None;
        topic = None;
        goal = None;
        attention = None }

let tick_with_closed ~now ws =
  let ws = { ws with just_closed = None } in
  match ws.episode with
  | Some _ when Time.diff_ms ws.last_activity now > ws.config.episode_idle_ms ->
      let closed = close_episode ws in
      (closed, closed.just_closed)
  | _ -> (ws, None)

let tick ~now ws = fst (tick_with_closed ~now ws)

(* Accessors *)
let episode ws = Option.map (fun e -> e.id) ws.episode
let episode_record ws = ws.episode
let speaker ws = ws.speaker
let attention ws = ws.attention
let topic ws = ws.topic
let goal ws = ws.goal
let recent_turns ws = match ws.episode with None -> [] | Some e -> e.turns
let participants ws = match ws.episode with None -> [] | Some e -> e.participants

(* Setters used by the controller *)
let set_speaker ws p = { ws with speaker = p }
let set_attention ws t = { ws with attention = t }
let set_topic ws t = { ws with topic = t }
let set_goal ws g = { ws with goal = g }

let close_now ws = close_episode ws
