#!/bin/bash
#
# fetch-model.sh — download the GGML speech model bundled with the app.
#
# ggml-base.en is ~141 MB, which does not belong in git history. It is fetched
# once at build time, verified against a pinned SHA-256, cached under
# ThirdParty/models, and copied into the app bundle. The shipped app therefore
# needs no download and no external install; the repository stays small.
#
# Idempotent, and it re-verifies a cached file rather than trusting its
# presence.
#
set -euo pipefail

# --- Pin -------------------------------------------------------------------
# base.en is the deliberate default: the synchroniser only needs to recognise
# roughly what was said, so latency matters far more than transcription
# polish. Larger models can be selected at runtime in Settings.
MODEL_NAME="${DYNOPROMPT_MODEL_NAME:-ggml-base.en.bin}"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${MODEL_NAME}"
MODEL_SHA256="a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
MODEL_DIR="${ROOT_DIR}/ThirdParty/models"
MODEL_PATH="${MODEL_DIR}/${MODEL_NAME}"

log() { printf '[fetch-model] %s\n' "$1" >&2; }

# Same policy as vendor-whisper.sh: a developer without a network gets a
# warning and a working app; a shipping build must not go out without the
# model it advertises. See that script for the reasoning.
REQUIRE_MODEL="${DYNOPROMPT_REQUIRE_WHISPER:-}"
if [[ -z "${REQUIRE_MODEL}" ]]; then
  case "${CONFIGURATION:-}" in
    Release|AppStore) REQUIRE_MODEL=1 ;;
    *)                REQUIRE_MODEL=0 ;;
  esac
fi

# Opt out entirely: skips the work and builds an app without the bundled
# engine. Useful for a fast iteration loop, for building offline, and for CI
# jobs that only exercise the synchroniser. Ignored for Release/AppStore,
# which must always ship complete.
if [[ "${DYNOPROMPT_SKIP_WHISPER:-0}" == "1" ]]; then
  case "${CONFIGURATION:-}" in
    Release|AppStore)
      echo "[skip] DYNOPROMPT_SKIP_WHISPER is ignored for ${CONFIGURATION} builds." >&2
      ;;
    *)
      echo "warning: DYNOPROMPT_SKIP_WHISPER=1 — the speech model was not bundled; download a model from Settings > Manage Models, or use Apple's on-device engine." >&2
      exit 0
      ;;
  esac
fi

fail_or_warn() {
  if [[ "${REQUIRE_MODEL}" == "1" ]]; then
    log "ERROR: $1"
    exit 1
  fi
  echo "warning: the speech model was not bundled — $1" >&2
  echo "warning: DynoPrompt will still build and run; download a model from Settings > Manage Models, or use Apple's on-device engine." >&2
  exit 0
}

verify() {
  [[ -f "${MODEL_PATH}" ]] || return 1
  # An empty pin means "no expected hash" (a custom model via the env var);
  # presence is then the only check that can be made.
  [[ -z "${MODEL_SHA256}" ]] && return 0
  local actual
  actual="$(shasum -a 256 "${MODEL_PATH}" | cut -d' ' -f1)"
  [[ "${actual}" == "${MODEL_SHA256}" ]]
}

if verify; then
  log "${MODEL_NAME} already present and verified"
  exit 0
fi

if [[ -f "${MODEL_PATH}" ]]; then
  log "cached copy failed verification; re-downloading"
  rm -f "${MODEL_PATH}"
fi

mkdir -p "${MODEL_DIR}"
log "downloading ${MODEL_NAME} (~141 MB, one time)"

# Download to a temporary name so an interrupted transfer never leaves a
# truncated file that looks like a valid cache entry.
TMP_PATH="${MODEL_PATH}.partial"
if ! curl -L --fail --progress-bar -o "${TMP_PATH}" "${MODEL_URL}"; then
  rm -f "${TMP_PATH}"
  fail_or_warn "could not download ${MODEL_NAME} (no network?). You can also place it into ${MODEL_DIR} by hand."
fi
mv "${TMP_PATH}" "${MODEL_PATH}"

if ! verify; then
  actual="$(shasum -a 256 "${MODEL_PATH}" | cut -d' ' -f1)"
  rm -f "${MODEL_PATH}"
  log "expected ${MODEL_SHA256}"
  log "actual   ${actual}"
  # A checksum mismatch is never tolerated silently, even for a dev build:
  # it means the bytes are not what was intended.
  log "ERROR: checksum mismatch; the download was discarded."
  exit 1
fi

log "verified ${MODEL_NAME}"
