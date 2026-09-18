(* Patch 002 §7 live environment and §9: the handler owns provider, model,
   authentication, transport, retry and timeouts. Cognition knows none of it.

   STATUS: compiles, NOT validated end to end. No OpenRouter key, no TTS, no
   OpenRB hardware and no vision worker exist on the development machine.
   Correction C6: acceptance criterion 6b stays PENDING. *)

module Brain = struct
  type config = { api_key : string; model : string; base_url : string }

  let default_base_url = "https://openrouter.ai/api/v1"
  let default_model = "anthropic/claude-sonnet-5"

  let config_of_env ~getenv =
    match getenv "OPENROUTER_API_KEY" with
    | None | Some "" -> Error "OPENROUTER_API_KEY is not set"
    | Some api_key ->
        Ok
          { api_key;
            model = (match getenv "BOB_BRAIN_MODEL" with Some m when m <> "" -> m | _ -> default_model);
            base_url =
              (match getenv "BOB_BRAIN_BASE_URL" with Some u when u <> "" -> u | _ -> default_base_url) }

  (* §9: Brain.request already contains the projected context. The handler
     only shapes it for the wire. *)
  let request_body c (r : Bob_domain.Brain.request) =
    let system = `String r.Bob_domain.Brain.context in
    Yojson.Safe.to_string
      (`Assoc
        [ ("model", `String c.model);
          ("stream", `Bool true);
          ( "messages",
            `List
              [ `Assoc [ ("role", `String "system"); ("content", system) ];
                `Assoc
                  [ ("role", `String "user");
                    ("content", `String r.Bob_domain.Brain.utterance) ] ] ) ])

  (* §19: operational failures become typed domain errors. *)
  let error_of_status = function
    | 429 -> Bob_domain.Brain.Rate_limited
    | 408 | 504 -> Bob_domain.Brain.Timeout
    | s when s >= 500 -> Bob_domain.Brain.Unavailable
    | _ -> Bob_domain.Brain.Invalid_response

  (* OpenRouter streams server-sent events. Returns the content delta, or None
     for terminators, comments and anything unparseable. *)
  let parse_sse_line line =
    let prefix = "data: " in
    let pl = String.length prefix in
    if String.length line <= pl || String.sub line 0 pl <> prefix then None
    else
      let payload = String.sub line pl (String.length line - pl) in
      if payload = "[DONE]" then None
      else
        match Yojson.Safe.from_string payload with
        | exception _ -> None
        | json -> (
            match json with
            | `Assoc kvs -> (
                match List.assoc_opt "choices" kvs with
                | Some (`List (`Assoc c :: _)) -> (
                    match List.assoc_opt "delta" c with
                    | Some (`Assoc d) -> (
                        match List.assoc_opt "content" d with
                        | Some (`String s) when s <> "" -> Some s
                        | _ -> None)
                    | _ -> None)
                | _ -> None)
            | _ -> None)
end

(* The live handler itself is deferred: wiring cohttp-eio streaming, the TTS
   process and the OpenRB serial link cannot be validated on this machine, and
   patch 002 forbids claiming a capability that has not been exercised.

   What exists above is the part that IS testable without credentials:
   configuration, request construction, error mapping and SSE parsing.

   The remaining work, to be done when credentials and hardware exist:
     - Brain.handle : config -> sw -> Eio.Switch.t -> ... forking a fiber that
       reads the SSE body and adds Text chunks to the stream as they arrive,
       so the consumer starts before generation finishes (§10), with
       Eio cancellation propagating to the HTTP request (§13).
     - Memory.handle backed by Bob_memory (SQLite), which CAN be written now.
     - Body.handle over the OpenRB serial protocol.
     - Speech.handle driving TTS.
   Record progress in docs/patches/002-...-CORRECTIONS.md under C6. *)
