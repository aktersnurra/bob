module Confidence = struct
  type t = float

  let v f = if f < 0. then 0. else if f > 1. then 1. else f
  let to_float t = t
  let pp fmt t = Format.fprintf fmt "%.2f" t
end
