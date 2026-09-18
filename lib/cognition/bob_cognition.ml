open Bob_types

(* Patch 002 §15: memory SELECTION is pure policy. Only the retrieval is
   effectful. This module stays testable without any handler. *)
module Memory_policy = struct
  let queries ~workspace ~utterance =
    let person = Bob_workspace.speaker workspace in
    let topic =
      match Bob_workspace.topic workspace with Some t -> [ t ] | None -> []
    in
    (* The utterance itself is always a query; the topic adds a second when
       the workspace is maintaining one. *)
    List.map
      (fun text -> Bob_domain.Memory.{ text; person })
      (utterance :: topic)
end

(* §4: this function does not know whether Recall hits SQLite or a fixture,
   whether Think reaches OpenRouter or a canned reply, or whether Speak drives
   a speaker or appends to a trace. *)
let handle_utterance ~config ~world ~workspace ~event =
  match event with
  | Bob_events.Utterance u ->
      (* 1. Pure policy decides what to look for. *)
      let qs = Memory_policy.queries ~workspace ~utterance:u.Bob_events.text in
      (* 2. Effectful retrieval. *)
      let items = List.concat_map Bob_effect.Memory.recall qs in
      (* 3. Pure projection: perception becomes meaning (§21 of SPEC). *)
      let now = Bob_effect.Clock.now () in
      let profile =
        match items with
        | [] -> None
        | l -> Some (String.concat "\n" (List.map (fun i -> "- " ^ i.Bob_domain.Memory.text) l))
      in
      let context =
        Bob_project.render ~now ~world ~workspace ~profile ~episodes:[]
      in
      (* 4. Effectful inference, streamed. *)
      let stream =
        Bob_effect.Brain.think
          Bob_domain.Brain.
            { context; utterance = u.Bob_events.text; speaker = u.Bob_events.speaker }
      in
      (* 5. Collect the reply. A Failed chunk at any position ends it (C4). *)
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
      (* 6. §17: the brain PROPOSES; Control validates; only then do we act. *)
      if reply <> "" then (
        match Bob_control.validate ~config (Bob_control.Say reply) with
        | Error _ -> () (* rejected: nothing reaches the body or speaker *)
        | Ok (Bob_control.Say approved) ->
            (* Fill-then-perform: no fiber is spawned, so the handler stack is
               intact. Capacity must exceed the item count or Stream.add
               blocks forever with no consumer. See correction C1. *)
            let out = Eio.Stream.create 4 in
            Eio.Stream.add out (Bob_domain.Speech.Say approved);
            Eio.Stream.add out Bob_domain.Speech.End;
            ignore (Bob_effect.Speech.say out)
        | Ok _ -> ())
  | _ -> ()
