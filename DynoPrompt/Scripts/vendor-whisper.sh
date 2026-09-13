#!/bin/bash
#
# vendor-whisper.sh — fetch and build whisper.cpp as static libraries.
#
# DynoPrompt links whisper.cpp directly into a sandboxed XPC service, so
# speech recognition works with nothing installed on the user's machine. The
# sources are not committed to this repository: they are fetched at a pinned
# tag and built here, which keeps the repo small while keeping the build
# reproducible.
#
# Output (git-ignored):
#   ThirdParty/whisper/include/*.h
#   ThirdParty/whisper/lib/*.a
#
# Idempotent: if the libraries already exist and the pin has not changed, it
# exits immediately. Xcode invokes it from a build phase, so it must stay fast
# on the common path.
#
set -euo pipefail

# --- Pin -------------------------------------------------------------------
# Update both together. The commit is what is actually verified; the tag is
# only there to make the intent readable.
WHISPER_TAG="v1.7.6"
WHISPER_REPO="https://github.com/ggml-org/whisper.cpp.git"

# Architectures to produce. ggml selects SIMD paths at configure time, so each
# slice is built separately and merged with lipo rather than built fat in one
# pass.
ARCHS="${WHISPER_ARCHS:-arm64 x86_64}"
DEPLOYMENT_TARGET="15.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
VENDOR_DIR="${ROOT_DIR}/ThirdParty/whisper"
WORK_DIR="${ROOT_DIR}/ThirdParty/.build/whisper"
STAMP_FILE="${VENDOR_DIR}/.pin"

LIBS=(
  "src/libwhisper.a"
  "ggml/src/libggml.a"
  "ggml/src/libggml-base.a"
  "ggml/src/libggml-cpu.a"
  "ggml/src/ggml-metal/libggml-metal.a"
  "ggml/src/ggml-blas/libggml-blas.a"
)

log() { printf '[vendor-whisper] %s\n' "$1" >&2; }

# Whether being unable to build whisper.cpp should fail the whole build.
#
# For a developer it should not: the bundled Whisper engine is an enhancement,
# and the app is fully functional without it because Apple's on-device
# recognizer is the default engine. Killing the build over a missing cmake
# would make an optional feature a hard dependency.
#
# For a shipping build it must, so a release can never silently go out without
# the engine it advertises. Xcode sets CONFIGURATION; CI sets the env var.
REQUIRE_WHISPER="${DYNOPROMPT_REQUIRE_WHISPER:-}"
if [[ -z "${REQUIRE_WHISPER}" ]]; then
  case "${CONFIGURATION:-}" in
    Release|AppStore) REQUIRE_WHISPER=1 ;;
    *)                REQUIRE_WHISPER=0 ;;
  esac
fi

# --- Stub fallback ---------------------------------------------------------
#
# Writes a header and archive that satisfy the compiler and linker but do
# nothing at runtime, so `git clone && build` always works.
#
# Without this, a machine with no cmake (or no network) cannot build the app at
# all: WhisperService imports whisper.h unconditionally, and a missing header
# is a hard compile error. That turns an optional enhancement into a hard
# prerequisite, which is backwards — Apple's on-device recognizer is the
# default engine and needs none of this.
#
# The stub's `whisper_init_from_file_with_params` returns NULL, so the helper
# reports that no model could be loaded and the app falls back cleanly. A
# `.stub` marker records the state for the UI and the self-test.
install_stub() {
  local include_dir="${VENDOR_DIR}/include"
  local lib_dir="${VENDOR_DIR}/lib"
  rm -rf "${VENDOR_DIR}"
  mkdir -p "${include_dir}" "${lib_dir}"

  cat > "${include_dir}/ggml.h" <<'STUB_GGML'
// Placeholder: whisper.cpp was not vendored for this build.
#pragma once
STUB_GGML

  # Only the API WhisperEngine.swift actually uses. Field names and order must
  # match upstream for the real build; here they only need to compile.
  cat > "${include_dir}/whisper.h" <<'STUB_WHISPER'
// Placeholder whisper.h — whisper.cpp was not vendored for this build.
//
// Declares exactly the surface DynoPrompt's helper uses so the target still
// compiles. Every entry point fails at runtime, and the app falls back to
// Apple's on-device recognizer.
#pragma once
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct whisper_context;

struct whisper_context_params {
    bool use_gpu;
};

enum whisper_sampling_strategy {
    WHISPER_SAMPLING_GREEDY = 0,
    WHISPER_SAMPLING_BEAM_SEARCH = 1,
};

struct whisper_full_params {
    enum whisper_sampling_strategy strategy;
    int   n_threads;
    bool  translate;
    bool  no_timestamps;
    bool  single_segment;
    bool  print_special;
    bool  print_progress;
    bool  print_realtime;
    bool  print_timestamps;
    bool  suppress_nst;
    float temperature_inc;
    const char * language;
    const char * initial_prompt;
};

struct whisper_context_params whisper_context_default_params(void);
struct whisper_full_params    whisper_full_default_params(enum whisper_sampling_strategy strategy);
struct whisper_context *      whisper_init_from_file_with_params(const char * path, struct whisper_context_params params);
void                          whisper_free(struct whisper_context * ctx);
int                           whisper_full(struct whisper_context * ctx, struct whisper_full_params params, const float * samples, int n_samples);
int                           whisper_full_n_segments(struct whisper_context * ctx);
const char *                  whisper_full_get_segment_text(struct whisper_context * ctx, int i_segment);

#ifdef __cplusplus
}
#endif
STUB_WHISPER

  local stub_source="${WORK_DIR}/whisper_stub.c"
  mkdir -p "${WORK_DIR}"
  cat > "${stub_source}" <<'STUB_SOURCE'
#include "whisper.h"
#include <stddef.h>

struct whisper_context_params whisper_context_default_params(void) {
    struct whisper_context_params p = {0};
    return p;
}

struct whisper_full_params whisper_full_default_params(enum whisper_sampling_strategy strategy) {
    struct whisper_full_params p = {0};
    p.strategy = strategy;
    return p;
}

// NULL makes the helper report that the model could not be loaded, which the
// app surfaces as "the Whisper engine isn't available in this build".
struct whisper_context * whisper_init_from_file_with_params(const char * path, struct whisper_context_params params) {
    (void)path; (void)params;
    return NULL;
}

void whisper_free(struct whisper_context * ctx) { (void)ctx; }

int whisper_full(struct whisper_context * ctx, struct whisper_full_params params, const float * samples, int n_samples) {
    (void)ctx; (void)params; (void)samples; (void)n_samples;
    return -1;
}

int whisper_full_n_segments(struct whisper_context * ctx) { (void)ctx; return 0; }

const char * whisper_full_get_segment_text(struct whisper_context * ctx, int i_segment) {
    (void)ctx; (void)i_segment;
    return NULL;
}
STUB_SOURCE

  # clang ships with Xcode, so unlike cmake it is always available here.
  local object="${WORK_DIR}/whisper_stub.o"
  if ! clang -c -O0 -I "${include_dir}" -o "${object}" "${stub_source}" 2>/dev/null; then
    log "ERROR: could not compile the placeholder; the build cannot continue."
    return 1
  fi

  # Every archive the linker is told about must exist; the stub satisfies all
  # of them and duplicate empty archives are harmless.
  ar rcs "${lib_dir}/libwhisper.a" "${object}" 2>/dev/null
  local empty_object="${WORK_DIR}/whisper_stub_empty.o"
  printf 'static int dynoprompt_placeholder;\nint dynoprompt_placeholder_use(void){return dynoprompt_placeholder;}\n' \
    > "${WORK_DIR}/empty.c"
  clang -c -O0 -o "${empty_object}" "${WORK_DIR}/empty.c" 2>/dev/null
  for name in libggml.a libggml-base.a libggml-cpu.a libggml-metal.a libggml-blas.a; do
    ar rcs "${lib_dir}/${name}" "${empty_object}" 2>/dev/null
  done

  printf 'stub' > "${VENDOR_DIR}/.stub"
  printf '%s' "stub:${WHISPER_TAG}" > "${STAMP_FILE}"
  return 0
}

# Stops with an error on a shipping build, or a visible warning otherwise.
# The literal "warning:" prefix is what makes Xcode surface it in the Issue
# navigator rather than burying it in the log.
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
      echo "warning: DYNOPROMPT_SKIP_WHISPER=1 — whisper.cpp was not bundled; the Whisper engine will be unavailable and Apple's on-device engine will be used instead." >&2
      install_stub || exit 1
      exit 0
      ;;
  esac
fi

fail_or_warn() {
  if [[ "${REQUIRE_WHISPER}" == "1" ]]; then
    log "ERROR: $1"
    exit 1
  fi
  echo "warning: whisper.cpp was not bundled — $1" >&2
  echo "warning: DynoPrompt will still build and run; the Whisper engine will be unavailable and Apple's on-device engine will be used instead." >&2
  install_stub || exit 1
  exit 0
}

# --- Skip when already current ---------------------------------------------
PIN="${WHISPER_TAG}:${ARCHS}"
# A previous run may have left a placeholder. Never treat that as current —
# once cmake or the network is available, build the real thing.
if [[ -f "${VENDOR_DIR}/.stub" ]]; then
  log "replacing a previous placeholder with a real build"
  rm -rf "${VENDOR_DIR}"
fi
if [[ -f "${STAMP_FILE}" ]] && [[ "$(cat "${STAMP_FILE}")" == "${PIN}" ]]; then
  # Confirm the artefacts are actually there — a half-deleted vendor dir
  # should rebuild rather than silently produce a broken link.
  all_present=true
  for lib in "${LIBS[@]}"; do
    [[ -f "${VENDOR_DIR}/lib/$(basename "${lib}")" ]] || all_present=false
  done
  if [[ "${all_present}" == true ]]; then
    log "up to date (${PIN})"
    exit 0
  fi
fi

command -v cmake >/dev/null 2>&1 || {
  fail_or_warn "cmake is not installed. Install it with: brew install cmake"
}

# --- Fetch -----------------------------------------------------------------
mkdir -p "${WORK_DIR}"
SRC_DIR="${WORK_DIR}/whisper.cpp"

if [[ ! -d "${SRC_DIR}/.git" ]]; then
  log "cloning whisper.cpp ${WHISPER_TAG}"
  rm -rf "${SRC_DIR}"
  if ! git clone --depth 1 --branch "${WHISPER_TAG}" "${WHISPER_REPO}" "${SRC_DIR}" >/dev/null 2>&1; then
    fail_or_warn "could not fetch whisper.cpp ${WHISPER_TAG} (no network?)"
  fi
else
  CURRENT="$(git -C "${SRC_DIR}" describe --tags 2>/dev/null || echo "")"
  if [[ "${CURRENT}" != "${WHISPER_TAG}" ]]; then
    log "re-cloning at ${WHISPER_TAG} (was ${CURRENT:-unknown})"
    rm -rf "${SRC_DIR}"
    git clone --depth 1 --branch "${WHISPER_TAG}" "${WHISPER_REPO}" "${SRC_DIR}" >/dev/null 2>&1
  fi
fi

# --- Build one slice per architecture --------------------------------------
BUILT_ARCHS=()
for arch in ${ARCHS}; do
  BUILD_DIR="${WORK_DIR}/build-${arch}"
  log "building ${arch}"

  # Two non-obvious flags:
  #
  # GGML_NATIVE=OFF — ggml defaults to `-march=native`, which bakes the build
  # machine's exact CPU into the binary. That breaks cross-compiling outright
  # (an M4 host cannot name its CPU for an x86_64 slice) and, worse, would
  # silently produce an arm64 slice that crashes on an older Apple silicon
  # Mac. A shipping build must target the baseline.
  #
  # -fno-objc-msgsend-selector-stubs — ggml-metal.m is compiled through the C
  # driver, and the selector-stub optimisation it emits leaves
  # _objc_msgSend$<selector> symbols that the static linker will not
  # synthesise for a non-ObjC consumer. Disabling it costs nothing measurable
  # and makes the archive link cleanly from Swift.
  if ! cmake -B "${BUILD_DIR}" -S "${SRC_DIR}" \
      -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_SHARED_LIBS=OFF \
      -DWHISPER_BUILD_TESTS=OFF \
      -DWHISPER_BUILD_EXAMPLES=OFF \
      -DWHISPER_BUILD_SERVER=OFF \
      -DGGML_METAL=ON \
      -DGGML_METAL_EMBED_LIBRARY=ON \
      -DGGML_ACCELERATE=ON \
      -DGGML_NATIVE=OFF \
      -DCMAKE_OSX_ARCHITECTURES="${arch}" \
      -DCMAKE_OSX_DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET}" \
      -DCMAKE_C_FLAGS="-fno-objc-msgsend-selector-stubs" \
      >"${BUILD_DIR}.configure.log" 2>&1; then
    log "WARNING: could not configure for ${arch}; skipping (see ${BUILD_DIR}.configure.log)"
    continue
  fi

  if ! cmake --build "${BUILD_DIR}" >"${BUILD_DIR}.build.log" 2>&1; then
    log "WARNING: could not build ${arch}; skipping (see ${BUILD_DIR}.build.log)"
    continue
  fi
  BUILT_ARCHS+=("${arch}")
done

if [[ ${#BUILT_ARCHS[@]} -eq 0 ]]; then
  fail_or_warn "no architecture built successfully (see the logs in ${WORK_DIR})"
fi
log "built: ${BUILT_ARCHS[*]}"

# --- Install ---------------------------------------------------------------
rm -rf "${VENDOR_DIR}"
mkdir -p "${VENDOR_DIR}/include" "${VENDOR_DIR}/lib"

cp "${SRC_DIR}/include/whisper.h" "${VENDOR_DIR}/include/"
cp "${SRC_DIR}/ggml/include/"*.h "${VENDOR_DIR}/include/"

for lib in "${LIBS[@]}"; do
  name="$(basename "${lib}")"
  slices=()
  for arch in "${BUILT_ARCHS[@]}"; do
    candidate="${WORK_DIR}/build-${arch}/${lib}"
    [[ -f "${candidate}" ]] && slices+=("${candidate}")
  done
  if [[ ${#slices[@]} -eq 0 ]]; then
    fail_or_warn "${name} was not produced by any architecture"
  fi
  if [[ ${#slices[@]} -eq 1 ]]; then
    cp "${slices[0]}" "${VENDOR_DIR}/lib/${name}"
  else
    lipo -create "${slices[@]}" -output "${VENDOR_DIR}/lib/${name}"
  fi
done

printf '%s' "${WHISPER_TAG}:${BUILT_ARCHS[*]}" > "${STAMP_FILE}"
log "installed into ThirdParty/whisper ($(cd "${VENDOR_DIR}/lib" && ls | tr '\n' ' '))"
