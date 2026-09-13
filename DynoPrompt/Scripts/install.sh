#!/bin/bash
#
# install.sh — build DynoPrompt and install it into /Applications.
#
# For using the app day to day instead of launching it from Xcode every time.
# Builds Release, signs it, and replaces any existing copy.
#
#   ./Scripts/install.sh                 # install to /Applications
#   ./Scripts/install.sh ~/Applications  # or somewhere else
#
# Signing
# -------
# Without a paid Apple Developer account the app is signed ad-hoc, which is
# fine for a Mac you build on yourself. The catch worth knowing: macOS ties
# microphone and speech-recognition permission to the code signature, and an
# ad-hoc signature changes every time the binary changes — so a reinstall can
# ask for those permissions again. Set DEVELOPER_ID to a real identity to avoid
# that:
#
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" ./Scripts/install.sh
#
# List available identities with:  security find-identity -v -p codesigning
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DESTINATION="${1:-/Applications}"
APP_NAME="DynoPrompt.app"
CONFIGURATION="Release"

# Non-sandboxed entitlements: this is the direct-install build, the same shape
# as the .dmg. It only asks for microphone access.
ENTITLEMENTS="${ROOT_DIR}/DynoPrompt/DynoPrompt-DeveloperID.entitlements"
SERVICE_ENTITLEMENTS="${ROOT_DIR}/WhisperService/WhisperService.entitlements"

say()  { printf '\033[1m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$1" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

cd "${ROOT_DIR}"

# --- Preflight ---------------------------------------------------------------
command -v xcodebuild >/dev/null 2>&1 || die "Xcode command line tools are required."
[[ -d "${DESTINATION}" ]] || die "${DESTINATION} does not exist."

if ! command -v cmake >/dev/null 2>&1; then
  die "cmake is required for a Release build (it compiles the bundled speech engine).
       Install it with:  brew install cmake"
fi

# --- Build -------------------------------------------------------------------
say "Building ${CONFIGURATION} (first run compiles whisper.cpp and downloads the model — several minutes)"
xcodebuild build \
  -project DynoPrompt.xcodeproj \
  -scheme DynoPrompt \
  -configuration "${CONFIGURATION}" \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  >/dev/null || die "Build failed. Run the same xcodebuild command without '>/dev/null' to see why."

PRODUCTS_DIR="$(xcodebuild -project DynoPrompt.xcodeproj -scheme DynoPrompt \
  -configuration "${CONFIGURATION}" -destination 'platform=macOS' \
  -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $2}' | head -1)"

BUILT_APP="${PRODUCTS_DIR}/${APP_NAME}"
[[ -d "${BUILT_APP}" ]] || die "Built app not found at ${BUILT_APP}"

# Refuse to install a build whose speech engine is only a placeholder.
if [[ -f "${BUILT_APP}/Contents/XPCServices/WhisperService.xpc/Contents/Resources/.whisper-stub" ]]; then
  die "This build contains a placeholder instead of whisper.cpp.
       Run ./Scripts/vendor-whisper.sh and try again."
fi

# --- Sign --------------------------------------------------------------------
IDENTITY="${DEVELOPER_ID:--}"
if [[ "${IDENTITY}" == "-" ]]; then
  warn "signing ad-hoc; macOS may ask for microphone permission again after each reinstall."
  warn "set DEVELOPER_ID to a real identity to keep permissions across updates."
fi

say "Signing"
# Inside out: the nested helper must be signed before the app that contains it.
codesign --force --options runtime --timestamp=none \
  --entitlements "${SERVICE_ENTITLEMENTS}" \
  --sign "${IDENTITY}" \
  "${BUILT_APP}/Contents/XPCServices/WhisperService.xpc" >/dev/null 2>&1 \
  || die "Failed to sign the speech helper."

codesign --force --options runtime --timestamp=none \
  --entitlements "${ENTITLEMENTS}" \
  --sign "${IDENTITY}" \
  "${BUILT_APP}" >/dev/null 2>&1 \
  || die "Failed to sign the app."

codesign --verify --deep --strict "${BUILT_APP}" 2>/dev/null \
  || die "The signature did not verify."

# --- Install -----------------------------------------------------------------
TARGET="${DESTINATION%/}/${APP_NAME}"

if pgrep -f "${APP_NAME}/Contents/MacOS/DynoPrompt" >/dev/null 2>&1; then
  say "Quitting the running copy"
  pkill -f "${APP_NAME}/Contents/MacOS/DynoPrompt" || true
  sleep 1
fi

if [[ -d "${TARGET}" ]]; then
  say "Replacing the existing install"
  rm -rf "${TARGET}"
fi

say "Installing to ${TARGET}"
cp -R "${BUILT_APP}" "${TARGET}"

# A locally built app was never quarantined, but strip the attribute anyway in
# case the tree came from a download.
xattr -dr com.apple.quarantine "${TARGET}" 2>/dev/null || true

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "${TARGET}/Contents/Info.plist" 2>/dev/null || echo '?')"
SIZE="$(du -sh "${TARGET}" | cut -f1)"

echo
say "Installed DynoPrompt ${VERSION} (${SIZE})"
echo "    ${TARGET}"
echo
echo "Open it with:   open -a DynoPrompt"
echo "Verify speech:  \"${TARGET}/Contents/MacOS/DynoPrompt\" --whisper-selftest"
echo
echo "On first launch macOS will ask for microphone access, and for speech"
echo "recognition if you use the Apple engine. Both are required for word"
echo "tracking; everything is processed on this Mac."
