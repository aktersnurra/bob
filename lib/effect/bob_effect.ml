(* Patch 002 §3: a small semantic vocabulary. Six effects. §25 forbids
   growing this into a framework.

   §6: Effect.perform appears ONLY in this file.

   The TYPES live in bob_domain. This library is the restricted one: a module
   that can name Bob_effect can act, so cognition and the replay driver do not
   depend on it. Handlers do, because they must pattern-match the
   constructors to interpret them. *)

(* --- The effects. C3: one += per constructor, GADT return on each. --- *)

type _ Effect.t += Now : Bob_types.Time.t Effect.t
type _ Effect.t += Recall : Bob_domain.Memory.query -> Bob_domain.Memory.item list Effect.t
type _ Effect.t += Think : Bob_domain.Brain.request -> Bob_domain.Brain.response Effect.t

type _ Effect.t +=
  | Speak : Bob_domain.Speech.stream -> (unit, Bob_domain.Speech.error) result Effect.t

type _ Effect.t +=
  | Look_at : Bob_domain.Body.target -> (unit, Bob_domain.Body.error) result Effect.t

type _ Effect.t +=
  | Identify : Bob_domain.Identity.request -> Bob_domain.Identity.result Effect.t

(* --- §6: typed wrappers. Nothing outside this file calls perform. --- *)

module Clock = struct
  let now () = Effect.perform Now
end

module Memory = struct
  let recall q = Effect.perform (Recall q)
end

module Brain = struct
  let think r = Effect.perform (Think r)
end

module Speech = struct
  let say s = Effect.perform (Speak s)
end

module Body = struct
  let look_at t = Effect.perform (Look_at t)
end

module Identity = struct
  let identify r = Effect.perform (Identify r)
end

(* A human-readable name per effect, for the tracing handler (§20). *)
let name_of : type a. a Effect.t -> string option = function
  | Now -> Some "Now"
  | Recall _ -> Some "Recall"
  | Think _ -> Some "Think"
  | Speak _ -> Some "Speak"
  | Look_at _ -> Some "Look_at"
  | Identify _ -> Some "Identify"
  | _ -> None
