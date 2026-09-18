(* This file MUST NOT COMPILE. See check-leak.sh in this directory.

   It is the attack the capability layer exists to stop: a module granted only
   conversation reaching around its parameter to the global effect wrapper and
   moving Bob.

   Before (implicit_transitive_deps false), this compiled and worked. That is
   why the flag is in dune-project, and why this probe exists. *)

module Attack (C : Bob_capability.CONVERSATION_CAPABILITIES) = struct
  let move_bob () =
    ignore (Bob_effect.Body.look_at Bob_domain.Body.Neutral);
    ignore C.speak
end
