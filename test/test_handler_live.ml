(* These tests do NOT contact OpenRouter. They check the parts of the live
   handler that are testable without credentials: request construction, error
   mapping, and that the module's surface matches what cognition expects.

   Live end-to-end validation is PENDING (correction C6). *)

let test_config_requires_an_api_key () =
  match Bob_handler_live.Brain.config_of_env ~getenv:(fun _ -> None) with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected an error when OPENROUTER_API_KEY is unset"

let test_config_reads_model_from_env () =
  match
    Bob_handler_live.Brain.config_of_env ~getenv:(function
      | "OPENROUTER_API_KEY" -> Some "sk-test"
      | "BOB_BRAIN_MODEL" -> Some "some/model"
      | _ -> None)
  with
  | Ok c -> Alcotest.(check string) "model" "some/model" c.Bob_handler_live.Brain.model
  | Error m -> Alcotest.failf "unexpected error: %s" m

let test_request_body_contains_the_projected_context () =
  let c =
    Bob_handler_live.Brain.{ api_key = "sk-test"; model = "m"; base_url = "https://example.invalid" }
  in
  let body =
    Bob_handler_live.Brain.request_body c
      Bob_domain.Brain.{ context = "CURRENT\nGustaf is speaking."; utterance = "where?";
                         speaker = None }
  in
  let contains h n =
    let nl = String.length n and hl = String.length h in
    let rec go i = i + nl <= hl && (String.sub h i nl = n || go (i + 1)) in
    nl = 0 || go 0
  in
  Alcotest.(check bool) "context present" true (contains body "Gustaf is speaking");
  Alcotest.(check bool) "utterance present" true (contains body "where?");
  Alcotest.(check bool) "streaming requested" true (contains body "\"stream\":true")

(* §19: HTTP failures become typed domain errors, not raw exceptions. *)
let test_status_codes_map_to_typed_errors () =
  let m = Bob_handler_live.Brain.error_of_status in
  Alcotest.(check string) "429" "rate_limited"
    (Bob_domain.Brain.error_to_string (m 429));
  Alcotest.(check string) "503" "unavailable"
    (Bob_domain.Brain.error_to_string (m 503));
  Alcotest.(check string) "408" "timeout"
    (Bob_domain.Brain.error_to_string (m 408));
  Alcotest.(check string) "400" "invalid_response"
    (Bob_domain.Brain.error_to_string (m 400))

let test_sse_line_parsing () =
  (* OpenRouter streams server-sent events; the handler must extract deltas
     and recognise the terminator. *)
  Alcotest.(check (option string)) "content delta" (Some "Hello")
    (Bob_handler_live.Brain.parse_sse_line
       {|data: {"choices":[{"delta":{"content":"Hello"}}]}|});
  Alcotest.(check (option string)) "done" None
    (Bob_handler_live.Brain.parse_sse_line "data: [DONE]");
  Alcotest.(check (option string)) "comment ignored" None
    (Bob_handler_live.Brain.parse_sse_line ": keep-alive")

let () =
  Alcotest.run "handler_live"
    [ ("config",
       [ Alcotest.test_case "requires key" `Quick test_config_requires_an_api_key;
         Alcotest.test_case "reads model" `Quick test_config_reads_model_from_env ]);
      ("request",
       [ Alcotest.test_case "carries context" `Quick
           test_request_body_contains_the_projected_context ]);
      ("errors",
       [ Alcotest.test_case "status mapping" `Quick test_status_codes_map_to_typed_errors ]);
      ("sse", [ Alcotest.test_case "line parsing" `Quick test_sse_line_parsing ]) ]
