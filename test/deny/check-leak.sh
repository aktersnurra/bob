#!/usr/bin/env bash
# Asserts that test/deny/leak.ml does NOT compile.
#
# leak.ml names Bob_effect.Body.look_at while its dune stanza lists only the
# libraries a functorised subsystem may use. If it compiles, the capability
# boundary is open - most likely because bob_effect was added back to a
# library's dune stanza, or because (implicit_transitive_deps false) was
# removed from dune-project.
#
# Run standalone, NOT from a dune rule: a nested dune cannot take the build
# lock, so it always appears to fail and the guard always appears to pass.
set -u

cd "$(dirname "$0")/../.." || exit 2

if BOB_CHECK_LEAK=true opam exec -- dune build test/deny/ >/dev/null 2>&1; then
  echo "FAIL: test/deny/leak.ml compiled."
  echo "The capability boundary is open. Check that:"
  echo "  - dune-project still sets (implicit_transitive_deps false)"
  echo "  - lib/cognition/dune and lib/trace/dune do not name bob_effect"
  exit 1
fi

echo "OK: test/deny/leak.ml correctly failed to compile."
exit 0
