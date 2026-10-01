#!/usr/bin/env bash
# Run the coding-runtime conformance suite against an adapter image.
#
# The suite ships inside the base image, so it is extracted from the image under
# test rather than fetched from a tag: the checks then always match the runtime
# being checked, and the probe the terminal check needs is already beside it in
# the image. Nothing here needs to know a coding-runtime version — the only pin
# is ARG BASE in the Dockerfile.
#
# One check cannot pass for this adapter. "a keystroke reaches the program under
# tmux" types plain text into the terminal and greps `tmux capture-pane` for it.
# That holds for a shell showing a command line, and for a TUI showing its prompt
# box — but only once the TUI has reached that prompt box. The conformance
# container has no credentials, so Claude Code sits on its first-run onboarding
# screen, which is a menu rather than a text field and renders none of the typed
# characters. The captured pane on failure is the theme picker:
#
#       2 -  console.log("Hello, World!");
#       2 +  console.log("Hello, Claude!");
#       3  }
#      ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
#       Syntax theme: Monokai Extended (ctrl+t to disable)
#
# Still the case on base 0.1.2: 34 passed, 1 failed, image-test on main at
# ddf4daf (run 36901189492, 2026-10-01).
#
# The terminal path itself is proven by the check before it — "the terminal
# socket carries traffic both ways" passes, and the tmux session exists — so what
# fails is the assumption about what the program does with the keystrokes, not
# their delivery.
#
# Tracked upstream: https://github.com/language-operator/coding-runtime/pull/27
#
# Not #4, which this comment used to cite. #4 was the *predecessor* check, which
# required a shell to reconstitute a marker and so could not pass for any TUI;
# replacing it was the right fix and closing it as completed was correct. The
# replacement works for a TUI showing its prompt box — opencode-adapter passes it
# outright and has no wrapper at all — it just still assumes the program got that
# far, which Claude Code without credentials does not.
#
# So it is tolerated — by name, and nothing else is. Any other failure fails the
# run, as does this one disappearing: if the suite starts passing outright, the
# tolerance has outlived the limitation and should be deleted.
#
# This whole script is scaffolding with an end date. #27 merged CONFORMANCE_SKIP
# into the suite: the declaration is passed in, a declared check still runs, and
# the suite itself fails the run if a declared check starts passing — the
# accounting below, done once upstream instead of per adapter. It is not in a
# released base yet (not in 0.1.2, not in 0.1.3), so until ARG BASE moves to one
# that has it, this stays. When it does, delete this file and run the extracted
# suite directly with:
#
#       CONFORMANCE_SKIP="a keystroke reaches the program under tmux" \
#         ./conformance.sh claude-code-adapter:test adapter
set -euo pipefail

IMAGE="${1:?usage: hack/conformance.sh <image>}"
KNOWN="a keystroke reaches the program under tmux"

SUITE="$(mktemp -t conformance.XXXXXX.sh)"
trap 'rm -f "$SUITE"' EXIT
docker run --rm --entrypoint cat "$IMAGE" \
    /opt/coding-runtime/test/conformance.sh > "$SUITE"
chmod +x "$SUITE"

status=0
out="$("$SUITE" "$IMAGE" adapter 2>&1)" || status=$?
printf '%s\n' "$out"
echo

if [ "$status" -eq 0 ]; then
    echo "The suite passed outright — the upstream limitation is gone."
    echo "Delete the tolerance in $0 and call the extracted suite directly."
    exit 0
fi

failures="$(printf '%s\n' "$out" | sed -n 's/^  FAIL  //p' | sort)"
if [ "$failures" = "$KNOWN" ]; then
    echo "Tolerated one known-inapplicable check: $KNOWN"
    echo "Every other check passed."
    exit 0
fi

echo "Unexpected conformance failures:"
printf '%s\n' "$failures" | sed 's/^/  - /'
exit 1
