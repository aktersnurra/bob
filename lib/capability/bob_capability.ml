(* Patch 002 §5 and §11, and SPEC §1.2 "prefer explicit module injection over
   global singletons".

   Effects are a global singleton: any module that can name Bob_effect can
   perform any effect. This layer is the counterweight. A subsystem takes its
   authority as a module parameter, so what it may do is decided at its
   instantiation site rather than by its own restraint.

   The enforcement has two halves, and BOTH are required:

     1. The signature omits what is denied, so the name is unbound.
     2. dune-project sets (implicit_transitive_deps false), so a functorised
        module cannot reach around its parameter to Bob_effect directly.

   Without (2), (1) is decoration - measured: the attack compiled and moved
   Bob. See docs/superpowers/specs/2026-09-17-capability-authority-design.md,
   including its Limits section: a module may still declare its OWN effect and
   perform it. That compiles, reaches no handler, and raises Effect.Unhandled
   with zero actions recorded. The guarantee is that a subsystem cannot reach
   Bob's body through Bob's own vocabulary, and any route around it fails
   loudly rather than silently. *)

module type CONVERSATION_CAPABILITIES = sig
  val now : unit -> Bob_types.Time.t
  val recall : Bob_domain.Memory.query -> Bob_domain.Memory.item list
  val think : Bob_domain.Brain.request -> Bob_domain.Brain.response
  val speak : Bob_domain.Speech.stream -> (unit, Bob_domain.Speech.error) result
end

(* Everything a conversation may do, plus the body. Including rather than
   restating means a module granted the body can still instantiate a
   conversation-only functor, which the replay driver relies on. *)
module type EMBODIED_CAPABILITIES = sig
  include CONVERSATION_CAPABILITIES

  val look_at : Bob_domain.Body.target -> (unit, Bob_domain.Body.error) result
end

module Conversation : CONVERSATION_CAPABILITIES = struct
  let now = Bob_effect.Clock.now
  let recall = Bob_effect.Memory.recall
  let think = Bob_effect.Brain.think
  let speak = Bob_effect.Speech.say
end

module Embodied : EMBODIED_CAPABILITIES = struct
  include Conversation

  let look_at = Bob_effect.Body.look_at
end

(* Perception has no consumer yet: the vision worker arrives in Phase 3.
   The signature is here so that when it does, identity resolution is granted
   deliberately rather than by default. It gates nothing today, and this
   comment exists so nobody claims otherwise. *)
module type PERCEPTION_CAPABILITIES = sig
  val identify : Bob_domain.Identity.request -> Bob_domain.Identity.result
end

module Perception : PERCEPTION_CAPABILITIES = struct
  let identify = Bob_effect.Identity.identify
end
