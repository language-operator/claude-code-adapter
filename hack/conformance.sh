#!/usr/bin/env bash
# Run the coding-runtime conformance suite against an adapter image.
#
# The suite lives upstream and is fetched at the tag the Dockerfile pins. The
# whole test/ directory comes down, not just conformance.sh: the terminal
# round-trip check bind-mounts a probe out of test/fixture-adapter/, and against
# a missing path Docker helpfully creates an empty directory, so the check fails
# for a reason that has nothing to do with the image.
#
# One check in adapter mode cannot pass for a TUI adapter. "a keystroke
# round-trips through tmux" types `echo CONFORMANCE_TERMINAL""_OK` and waits for
# a *shell* to reconstitute the marker — the quotes are deliberate, so that an
# echo of the keystrokes alone cannot satisfy it. Our terminal runs the Claude
# Code TUI, which puts typed text in its prompt rather than executing it, so the
# marker never appears. The probe sits in test/fixture-adapter/ beside a bash
# launcher, and the upstream authoring guide describes adapter mode as "uid,
# read-only rootfs, probes, and the cross-origin guard" without mentioning it:
# the check belongs to the fixture, not to every adapter built on the base.
#
# Tracked upstream: https://github.com/language-operator/coding-runtime/issues/4
#
# So it is tolerated — by name, and nothing else is. Any other failure fails the
# run, as does this one disappearing: if the suite starts passing outright, the
# tolerance below has outlived the upstream limitation and should be deleted.
set -euo pipefail

IMAGE="${1:?usage: hack/conformance.sh <image>}"
VERSION="${CODING_RUNTIME_VERSION:-v0.1.0}"
KNOWN="a keystroke round-trips through tmux"

SUITE="$(mktemp -d)"
trap 'rm -rf "$SUITE"' EXIT
curl -fsSL "https://github.com/language-operator/coding-runtime/archive/refs/tags/${VERSION}.tar.gz" \
    | tar -xz --wildcards --strip-components=2 -C "$SUITE" '*/test'
chmod +x "$SUITE/conformance.sh"

status=0
out="$("$SUITE/conformance.sh" "$IMAGE" adapter 2>&1)" || status=$?
printf '%s\n' "$out"
echo

if [ "$status" -eq 0 ]; then
    echo "The suite passed outright — the upstream limitation is gone."
    echo "Delete the tolerance in $0 and call it directly."
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
