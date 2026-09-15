open Bob_types

(* The marks SPEC section 28 names. *)
type mark =
  | Speech_start
  | Doa_update
  | Movement_start
  | Stt_first_partial
  | Stt_final
  | Speech_end
  | Memory_retrieved
  | Llm_request
  | Llm_first_token
  | Tts_first_sample
  | First_audio

let mark_name = function
  | Speech_start -> "speech-start"
  | Doa_update -> "doa-update"
  | Movement_start -> "movement-start"
  | Stt_first_partial -> "stt-first-partial"
  | Stt_final -> "stt-final"
  | Speech_end -> "speech-end"
  | Memory_retrieved -> "memory-retrieved"
  | Llm_request -> "llm-request"
  | Llm_first_token -> "llm-first-token"
  | Tts_first_sample -> "tts-first-sample"
  | First_audio -> "first-audio"

type t = (mark * Time.t) list

let empty () : t = []

(* First mark wins: a span measures the first time something happened. *)
let mark t ~at m = if List.mem_assoc m t then t else (m, at) :: t

let span t a b =
  match (List.assoc_opt a t, List.assoc_opt b t) with
  | Some ta, Some tb -> Some (Time.diff_ms ta tb)
  | _ -> None

(* SPEC section 17 budgets, in milliseconds. *)
let budgets =
  [ (("speech-start -> movement-start", Speech_start, Movement_start), 100.);
    (("speech-end -> stt-final", Speech_end, Stt_final), 500.);
    (("speech-end -> llm-first-token", Speech_end, Llm_first_token), 1000.);
    (("speech-end -> first-audio", Speech_end, First_audio), 1000.) ]

let report t =
  List.map (fun ((name, a, b), _budget) -> (name, span t a b)) budgets

let over_budget t =
  List.filter_map
    (fun ((name, a, b), budget) ->
      match span t a b with
      | Some ms when ms > budget -> Some (name, ms, budget)
      | _ -> None)
    budgets

let pp_report fmt t =
  List.iter
    (fun (name, v) ->
      match v with
      | Some ms -> Format.fprintf fmt "  %-34s %7.1f ms@." name ms
      | None -> Format.fprintf fmt "  %-34s %7s@." name "-")
    (report t);
  match over_budget t with
  | [] -> ()
  | l ->
      Format.fprintf fmt "@.  OVER BUDGET:@.";
      List.iter
        (fun (n, ms, b) -> Format.fprintf fmt "    %s: %.1f ms > %.1f ms@." n ms b)
        l
