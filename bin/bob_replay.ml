open Bob_types

let run trace_path verbose =
  match Bob_trace.parse_file trace_path with
  | Error m ->
      Printf.eprintf "parse error: %s\n" m;
      1
  | Ok evs ->
      Printf.printf "Replaying %d events from %s\n\n" (List.length evs) trace_path;
      if verbose then (
        print_endline "EVENTS";
        List.iter
          (fun e -> Printf.printf "  %8.3fs  %s\n" (Bob_events.at e |> Time.to_ms |> fun m -> m /. 1000.) (Bob_events.kind e))
          evs;
        print_newline ());
      let brain, last_request =
        Bob_capability.Brain.fake ~reply:"Jag vet inte. Ska vi ta reda på det?" ()
      in
      let body, body_log = Bob_capability.Body.fake () in
      let tts, tts_log = Bob_capability.Tts.fake () in
      let r = Bob_trace.replay ~brain ~body ~tts ~memory:None evs in

      print_endline "DECISIONS";
      List.iter
        (fun (t, d) ->
          Printf.printf "  %8.3fs  %s\n" (Time.to_ms t /. 1000.)
            (Format.asprintf "%a" Bob_control.pp_decision d))
        r.Bob_trace.decisions;
      print_newline ();

      print_endline "BODY";
      List.iter
        (fun c ->
          match c with
          | Bob_capability.Body.Look p ->
              Printf.printf "  look yaw=%.0f pitch=%.0f\n" (Angle.to_deg p.yaw)
                (Angle.to_deg p.pitch)
          | Bob_capability.Body.Expression e -> Printf.printf "  expression %s\n" e
          | Bob_capability.Body.Blink -> print_endline "  blink")
        (body_log ());
      print_newline ();

      print_endline "SPEECH";
      let spoken, stops = tts_log () in
      List.iter (fun s -> Printf.printf "  %S\n" s) spoken;
      if stops > 0 then Printf.printf "  (interrupted %d time(s))\n" stops;
      print_newline ();

      (match last_request () with
      | Some req when verbose ->
          print_endline "PROJECTED CONTEXT SENT TO BRAIN";
          print_endline (req.Bob_capability.Brain.context);
          print_newline ()
      | _ -> ());

      print_endline "LATENCY (SPEC section 28)";
      Format.printf "%a" Bob_obs.pp_report r.Bob_trace.obs;
      print_newline ();

      (match r.Bob_trace.errors with
      | [] -> ()
      | errs ->
          print_endline "ERRORS";
          List.iter (fun e -> Printf.printf "  %s\n" e) errs;
          print_newline ());

      print_endline
        "NOTE: simulated replay. No hardware moved, no audio was captured or \
         played, and no model was called.";
      0

open Cmdliner

let trace_arg =
  Arg.(required & pos 0 (some file) None & info [] ~docv:"TRACE" ~doc:"Trace file to replay.")

let verbose_arg =
  Arg.(value & flag & info [ "v"; "verbose" ] ~doc:"Print events and the projected context.")

let cmd =
  let doc = "Replay an event trace through Bob's cognitive core." in
  let info = Cmd.info "bob-replay" ~version:"0.1.0" ~doc in
  Cmd.v info Term.(const run $ trace_arg $ verbose_arg)

let () = exit (Cmd.eval' cmd)
