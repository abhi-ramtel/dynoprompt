#!/bin/bash
#
# verify-whisper.sh — prove the bundled speech stack works end to end.
#
# Builds the app and runs its self-test, which connects to the embedded XPC
# service, loads the bundled model, transcribes real audio, and feeds the
# result through the synchroniser.
#
# The self-test lives inside the app because an Application-type XPC service
# can only be launched by its containing bundle — the same property that keeps
# it out of reach of anything else on the system.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIGURATION="${1:-Debug}"
# Consume the configuration so it is not forwarded to the app, which would
# read it as the path to an audio fixture.
[[ $# -gt 0 ]] && shift

cd "${ROOT_DIR}"

echo "Building DynoPrompt (${CONFIGURATION})…"
xcodebuild build \
  -project DynoPrompt.xcodeproj \
  -scheme DynoPrompt \
  -configuration "${CONFIGURATION}" \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  >/dev/null

PRODUCTS_DIR="$(xcodebuild -project DynoPrompt.xcodeproj -scheme DynoPrompt \
  -configuration "${CONFIGURATION}" -destination 'platform=macOS' \
  -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $2}' | head -1)"

APP="${PRODUCTS_DIR}/DynoPrompt.app"
if [[ ! -d "${APP}" ]]; then
  echo "ERROR: built app not found at ${APP}"
  exit 1
fi

# Prefer the committed speech fixture over synthesizing one.
#
# `say` needs a text-to-speech voice, and a headless CI runner has none — it
# emits a fraction of a second of near-silence, which whisper hallucinates into
# a stray word and the synchroniser rightly refuses to match. The fixture makes
# the check deterministic and identical everywhere.
FIXTURE="${ROOT_DIR}/Scripts/fixtures/selftest-speech.wav"
if [[ $# -eq 0 && -f "${FIXTURE}" ]]; then
  set -- "${FIXTURE}"
fi

echo
exec "${APP}/Contents/MacOS/DynoPrompt" --whisper-selftest "$@"
