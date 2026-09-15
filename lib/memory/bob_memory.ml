open Bob_types

let max_profile_bytes = 8 * 1024

type turn = Time.t * string option * string

type episode = {
  id : Episode_id.t;
  started_at : Time.t;
  ended_at : Time.t;
  participants : Person_id.t list;
  turns : turn list;
  summary : string option;
}

type store = { db : Sqlite3.db; dir : string }

exception Memory_error of string

let check rc msg =
  match rc with
  | Sqlite3.Rc.OK | Sqlite3.Rc.DONE -> ()
  | r -> raise (Memory_error (msg ^ ": " ^ Sqlite3.Rc.to_string r))

let exec db sql = check (Sqlite3.exec db sql) ("exec: " ^ sql)

let schema =
  {|
  create table if not exists episodes (
    id           text primary key,
    started_at   real not null,
    ended_at     real not null,
    summary      text
  );
  create table if not exists episode_participants (
    episode_id   text not null,
    person_id    text not null,
    primary key (episode_id, person_id)
  );
  create table if not exists turns (
    episode_id   text not null,
    at           real not null,
    speaker      text,
    text         text not null
  );
  create virtual table if not exists episode_fts using fts5(
    episode_id unindexed,
    body
  );
  create index if not exists idx_part_person
    on episode_participants(person_id);
  |}

let open_store ~dir =
  if not (Sys.file_exists dir) then Unix.mkdir dir 0o700;
  let people = Filename.concat dir "people" in
  if not (Sys.file_exists people) then Unix.mkdir people 0o700;
  let db = Sqlite3.db_open (Filename.concat dir "bob.db") in
  exec db "pragma journal_mode=WAL;";
  exec db "pragma foreign_keys=ON;";
  exec db schema;
  { db; dir }

let close s = ignore (Sqlite3.db_close s.db)

let bind_exec db sql args =
  let st = Sqlite3.prepare db sql in
  List.iteri (fun i v -> check (Sqlite3.bind st (i + 1) v) "bind") args;
  let rec loop () =
    match Sqlite3.step st with
    | Sqlite3.Rc.ROW -> loop ()
    | Sqlite3.Rc.DONE -> ()
    | r -> raise (Memory_error ("step: " ^ Sqlite3.Rc.to_string r))
  in
  loop ();
  check (Sqlite3.finalize st) "finalize"

let query db sql args row_fn =
  let st = Sqlite3.prepare db sql in
  List.iteri (fun i v -> check (Sqlite3.bind st (i + 1) v) "bind") args;
  let acc = ref [] in
  let rec loop () =
    match Sqlite3.step st with
    | Sqlite3.Rc.ROW ->
        acc := row_fn (Sqlite3.row_data st) :: !acc;
        loop ()
    | Sqlite3.Rc.DONE -> ()
    | r -> raise (Memory_error ("step: " ^ Sqlite3.Rc.to_string r))
  in
  loop ();
  check (Sqlite3.finalize st) "finalize";
  List.rev !acc

let text = function
  | Sqlite3.Data.TEXT s -> s
  | Sqlite3.Data.NULL -> ""
  | d -> Sqlite3.Data.to_string_coerce d

let opt_text = function
  | Sqlite3.Data.NULL -> None
  | Sqlite3.Data.TEXT s -> Some s
  | d -> Some (Sqlite3.Data.to_string_coerce d)

let real = function
  | Sqlite3.Data.FLOAT f -> f
  | Sqlite3.Data.INT i -> Int64.to_float i
  | _ -> 0.

let put_episode s (e : episode) =
  let id = Episode_id.to_string e.id in
  exec s.db "begin immediate;";
  (try
     bind_exec s.db
       "insert or replace into episodes(id, started_at, ended_at, summary) \
        values(?,?,?,?)"
       [ Sqlite3.Data.TEXT id;
         Sqlite3.Data.FLOAT (Time.to_ms e.started_at);
         Sqlite3.Data.FLOAT (Time.to_ms e.ended_at);
         (match e.summary with
         | None -> Sqlite3.Data.NULL
         | Some s -> Sqlite3.Data.TEXT s) ];
     bind_exec s.db "delete from episode_participants where episode_id=?"
       [ Sqlite3.Data.TEXT id ];
     List.iter
       (fun p ->
         bind_exec s.db
           "insert or ignore into episode_participants(episode_id, person_id) \
            values(?,?)"
           [ Sqlite3.Data.TEXT id; Sqlite3.Data.TEXT (Person_id.to_string p) ])
       e.participants;
     bind_exec s.db "delete from turns where episode_id=?" [ Sqlite3.Data.TEXT id ];
     List.iter
       (fun (t, spk, txt) ->
         bind_exec s.db
           "insert into turns(episode_id, at, speaker, text) values(?,?,?,?)"
           [ Sqlite3.Data.TEXT id;
             Sqlite3.Data.FLOAT (Time.to_ms t);
             (match spk with
             | None -> Sqlite3.Data.NULL
             | Some s -> Sqlite3.Data.TEXT s);
             Sqlite3.Data.TEXT txt ])
       e.turns;
     bind_exec s.db "delete from episode_fts where episode_id=?"
       [ Sqlite3.Data.TEXT id ];
     let body =
       String.concat " "
         (List.map (fun (_, _, t) -> t) e.turns
         @ match e.summary with None -> [] | Some s -> [ s ])
     in
     bind_exec s.db "insert into episode_fts(episode_id, body) values(?,?)"
       [ Sqlite3.Data.TEXT id; Sqlite3.Data.TEXT body ];
     exec s.db "commit;"
   with ex ->
     exec s.db "rollback;";
     raise ex)

let load_turns s id =
  query s.db "select at, speaker, text from turns where episode_id=? order by at"
    [ Sqlite3.Data.TEXT id ]
    (fun row -> (Time.of_ms (real row.(0)), opt_text row.(1), text row.(2)))

let load_participants s id =
  query s.db "select person_id from episode_participants where episode_id=?"
    [ Sqlite3.Data.TEXT id ]
    (fun row -> Person_id.v (text row.(0)))

let get_episode s eid =
  let id = Episode_id.to_string eid in
  match
    query s.db "select id, started_at, ended_at, summary from episodes where id=?"
      [ Sqlite3.Data.TEXT id ]
      (fun row -> (text row.(0), real row.(1), real row.(2), opt_text row.(3)))
  with
  | [] -> None
  | (id, st, en, summary) :: _ ->
      Some
        { id = Episode_id.v id;
          started_at = Time.of_ms st;
          ended_at = Time.of_ms en;
          participants = load_participants s id;
          turns = load_turns s id;
          summary }

(* Isolation (SPEC section 30): the participant join is not optional. There is
   no code path that returns an episode the person did not take part in. *)
let search_episodes s ~person ~query:q ~limit =
  let ids =
    query s.db
      "select f.episode_id from episode_fts f \
       join episode_participants p on p.episode_id = f.episode_id \
       where p.person_id = ? and episode_fts match ? \
       order by rank limit ?"
      [ Sqlite3.Data.TEXT (Person_id.to_string person);
        Sqlite3.Data.TEXT q;
        Sqlite3.Data.INT (Int64.of_int limit) ]
      (fun row -> text row.(0))
  in
  List.filter_map (fun id -> get_episode s (Episode_id.v id)) ids

(* --- Semantic profiles --- *)

let valid_person_id p =
  let s = Person_id.to_string p in
  s <> "" && s <> "." && s <> ".."
  && not (String.contains s '/')
  && not (String.contains s '\000')

let profile_dir s p = Filename.concat (Filename.concat s.dir "people") (Person_id.to_string p)
let profile_path s p = Filename.concat (profile_dir s p) "profile.md"

let read_profile s p =
  if not (valid_person_id p) then None
  else
    let path = profile_path s p in
    if not (Sys.file_exists path) then None
    else
      let ic = open_in_bin path in
      Fun.protect
        ~finally:(fun () -> close_in ic)
        (fun () -> Some (really_input_string ic (in_channel_length ic)))

(* Atomic: write to a temp file in the same directory, then rename. *)
let write_profile s p content =
  if not (valid_person_id p) then raise (Memory_error "invalid person id");
  let dir = profile_dir s p in
  if not (Sys.file_exists dir) then Unix.mkdir dir 0o700;
  let tmp = Filename.concat dir ".profile.md.tmp" in
  let oc = open_out_bin tmp in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () -> output_string oc content);
  Sys.rename tmp (profile_path s p)

let write_profile_checked s p content =
  if not (valid_person_id p) then Error "invalid person id"
  else if String.length content > max_profile_bytes then
    Error
      (Printf.sprintf "profile too large: %d > %d" (String.length content)
         max_profile_bytes)
  else (
    write_profile s p content;
    Ok ())

let delete_person s p =
  if not (valid_person_id p) then Error "invalid person id"
  else (
    let dir = profile_dir s p in
    if Sys.file_exists (profile_path s p) then Sys.remove (profile_path s p);
    if Sys.file_exists dir then (try Unix.rmdir dir with Unix.Unix_error _ -> ());
    bind_exec s.db "delete from episode_participants where person_id=?"
      [ Sqlite3.Data.TEXT (Person_id.to_string p) ];
    Ok ())
