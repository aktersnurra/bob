open Bob_types

let max_chars = 4000

(* Display names come from the profile's first heading when available, else a
   capitalised person id. The brain sees names, never ids. *)
let display_name p =
  let s = Person_id.to_string p in
  if s = "" then "someone"
  else String.make 1 (Char.uppercase_ascii s.[0]) ^ String.sub s 1 (String.length s - 1)

let truncate n s =
  if String.length s <= n then s
  else
    let marker = "\n[...]" in
    String.sub s 0 (n - String.length marker) ^ marker

let section title body =
  if String.trim body = "" then "" else Printf.sprintf "%s\n%s\n\n" title body

let render ~now ~world ~workspace ~profile ~episodes =
  let tracks = Bob_world.visible_tracks ~now world in
  let identified, unidentified =
    List.partition_map
      (fun (t : Bob_world.track) ->
        match Bob_world.identity_of ~now world t.Bob_world.id with
        | Some (p, _) -> Left p
        | None -> Right ())
      tracks
  in
  let speaker = Bob_workspace.speaker workspace in
  let current =
    let who =
      match speaker with
      | Some p -> Printf.sprintf "%s is speaking to Bob." (display_name p)
      | None -> "Nobody is currently identified as speaking."
    in
    let others =
      let named =
        List.filter
          (fun p -> match speaker with Some s -> not (Person_id.equal s p) | None -> true)
          identified
      in
      let named_part =
        match named with
        | [] -> ""
        | l -> Printf.sprintf "Also visible: %s." (String.concat ", " (List.map display_name l))
      in
      let unknown_part =
        match List.length unidentified with
        | 0 -> ""
        | 1 -> "One other unidentified person is visible nearby."
        | n -> Printf.sprintf "%d other unidentified people are visible nearby." n
      in
      String.concat " " (List.filter (fun s -> s <> "") [ named_part; unknown_part ])
    in
    String.concat "\n" (List.filter (fun s -> s <> "") [ who; others ])
  in
  let memory = match profile with None -> "" | Some p -> String.trim p in
  let past =
    episodes
    |> List.filter_map (fun (e : Bob_memory.episode) ->
           match e.Bob_memory.summary with
           | Some s -> Some ("- " ^ s)
           | None -> (
               match e.Bob_memory.turns with
               | [] -> None
               | (_, _, t) :: _ -> Some ("- " ^ t)))
    |> String.concat "\n"
  in
  let conversation =
    Bob_workspace.recent_turns workspace
    |> List.map (fun (t : Bob_workspace.turn) ->
           let who =
             match t.Bob_workspace.speaker with
             | Some p -> display_name p
             | None -> "Someone"
           in
           Printf.sprintf "%s: %s" who t.Bob_workspace.text)
    |> String.concat "\n"
  in
  let topic =
    match Bob_workspace.topic workspace with
    | Some t -> Printf.sprintf "Topic: %s" t
    | None -> ""
  in
  let out =
    section "CURRENT" current
    ^ section "RELEVANT PERSON MEMORY" memory
    ^ section "RELEVANT PAST EVENTS" past
    ^ section "RECENT CONVERSATION" conversation
    ^ section "FOCUS" topic
  in
  truncate max_chars (String.trim out)
