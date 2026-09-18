open Bob_types

module Replay = Bob_trace.Make (Bob_capability.Embodied)

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
      let sim =
        Bob_handler_sim.create ~start:(Bob_events.at (List.hd evs))
          ~brain_reply:"Jag vet inte. Ska vi ta reda på det?" ()
      in
      let r = ref None in
      Bob_runtime.run_sim sim (fun _sw -> r := Some (Replay.replay evs));
      let r = Option.get !r in

      print_endline "DECISIONS";
      List.iter
        (fun (t, d) ->
          Printf.printf "  %8.3fs  %s\n" (Time.to_ms t /. 1000.)
            (Format.asprintf "%a" Bob_control.pp_decision d))
        r.Bob_trace.decisions;
      print_newline ();

      print_endline "BODY";
      List.iter
        (fun a ->
          match a with
          | Bob_handler_sim.Looked (Bob_domain.Body.Bearing yaw) ->
              Printf.printf "  look yaw=%.0f pitch=%.0f\n" (Angle.to_deg yaw) 0.
          | Bob_handler_sim.Looked (Bob_domain.Body.Person _) -> print_endline "  look at person"
          | Bob_handler_sim.Looked (Bob_domain.Body.Track _) -> print_endline "  look at track"
          | Bob_handler_sim.Looked Bob_domain.Body.Neutral -> print_endline "  look neutral"
          | _ -> ())
        (Bob_handler_sim.actions sim);
      print_newline ();

      print_endline "SPEECH";
      let spoken =
        List.filter_map
          (function Bob_handler_sim.Spoke s -> Some s | _ -> None)
          (Bob_handler_sim.actions sim)
      in
      List.iter (fun s -> Printf.printf "  %S\n" s) spoken;
      print_newline ();

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
