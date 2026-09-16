(* Patch 002 §5, §11: types and modules express WHAT a subsystem may do;
   effects express WHAT IT REQUESTS; handlers decide HOW it executes. OCaml
   effects are not statically tracked, so a subsystem that must not move Bob
   is denied the Body capability here rather than relying on it not
   performing Look_at.

   §5/§11 replace the Phase 0 capability records (function-record doubles
   with `fake` constructors) with thin authority modules: each module
   signature names exactly the effects a subsystem may request, and its
   implementation forwards to the typed effect wrapper. Task 7 retired the
   `fake` constructors -- Bob_handler_sim now supersedes them for tests. *)

module type CONVERSATION_CAPABILITIES = sig
  val recall : Bob_effect.Memory.query -> Bob_effect.Memory.item list
  val think : Bob_effect.Brain.request -> Bob_effect.Brain.response
  val speak : Bob_effect.Speech.stream -> (unit, Bob_effect.Speech.error) result
end

module Conversation_with_body : CONVERSATION_CAPABILITIES = struct
  let recall = Bob_effect.Memory.recall
  let think = Bob_effect.Brain.think
  let speak = Bob_effect.Speech.say
end

(* A subsystem denied Body cannot move Bob even though the effect exists
   process-wide: its own module signature simply has no way to request
   Look_at. *)
module type PERCEPTION_CAPABILITIES = sig
  val identify : Bob_effect.Identity.request -> Bob_effect.Identity.result
end

module Perception : PERCEPTION_CAPABILITIES = struct
  let identify = Bob_effect.Identity.identify
end

module type BODY_CAPABILITIES = sig
  val look_at : Bob_effect.Body.target -> (unit, Bob_effect.Body.error) result
end

module Body_actuation : BODY_CAPABILITIES = struct
  let look_at = Bob_effect.Body.look_at
end
