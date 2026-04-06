#!/bin/bash
set -euo pipefail

SCHEME="ClaudeIsland"
CONFIGURATION="Release"
APP_NAME="Claude Island.app"
APP_PROCESS_NAME="Claude Island"
APP_BUNDLE_ID="com.celestial.ClaudeIsland"
INSTALL_PATH="/Applications/$APP_NAME"
DERIVED_DATA_ROOT="$HOME/Library/Developer/Xcode/DerivedData"
FORCE_BUILD=0

usage() {
  cat <<'EOF'
Usage: ./build_and_deploy.sh [--force-build] [--help]

Build and deploy Claude Island to /Applications.

Options:
  --force-build  Always run a fresh Release build even if the existing artifact is newer than source files.
  --help         Show this help text.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force-build)
      FORCE_BUILD=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Error: unknown argument '$1'" >&2
      usage >&2
      exit 1
      ;;
  esac
done

find_build_artifact() {
  find "$DERIVED_DATA_ROOT" -path "*/Build/Products/$CONFIGURATION/$APP_NAME" -print | head -1
}

latest_source_mtime() {
  find \
    "$PWD/ClaudeIsland" \
    "$PWD/ClaudeIsland.xcodeproj" \
    -type f \
    ! -path '*/xcuserdata/*' \
    ! -path '*/project.xcworkspace/xcuserdata/*' \
    -print0 \
    | xargs -0 stat -f '%m' \
    | sort -nr \
    | head -1
}

artifact_binary_mtime() {
  local app_path="$1"
  stat -f '%m' "$app_path/Contents/MacOS/$APP_PROCESS_NAME"
}

build_if_needed() {
  APP_PATH="$(find_build_artifact)"

  if [[ "$FORCE_BUILD" -eq 0 && -n "$APP_PATH" ]]; then
    local newest_source newest_artifact
    newest_source="$(latest_source_mtime)"
    newest_artifact="$(artifact_binary_mtime "$APP_PATH")"

    if [[ "$newest_artifact" -ge "$newest_source" ]]; then
      echo "Skipping build: existing $CONFIGURATION artifact is up to date."
      return
    fi
  fi

  echo "Building $SCHEME ($CONFIGURATION)..."
  xcodebuild -scheme "$SCHEME" -configuration "$CONFIGURATION" -parallelizeTargets -jobs "$(sysctl -n hw.ncpu)" build
  APP_PATH="$(find_build_artifact)"
}

verify_installed_app_signature() {
  local app_path="$1"
  codesign --verify --deep --strict "$app_path" >/dev/null 2>&1
}

shutdown_existing_app() {
  if ! pgrep -x "$APP_PROCESS_NAME" >/dev/null 2>&1; then
    echo "No running $APP_PROCESS_NAME process found."
    return
  fi

  echo "Shutting down existing $APP_PROCESS_NAME process..."
  osascript -e "tell application id \"$APP_BUNDLE_ID\" to quit" >/dev/null 2>&1 || true

  for _ in {1..15}; do
    if ! pgrep -x "$APP_PROCESS_NAME" >/dev/null 2>&1; then
      echo "Existing process stopped cleanly."
      return
    fi
    sleep 1
  done

  echo "Existing process did not exit cleanly, sending SIGTERM..."
  pkill -TERM -x "$APP_PROCESS_NAME" >/dev/null 2>&1 || true

  for _ in {1..10}; do
    if ! pgrep -x "$APP_PROCESS_NAME" >/dev/null 2>&1; then
      echo "Existing process stopped after SIGTERM."
      return
    fi
    sleep 1
  done

  echo "Existing process still running, sending SIGKILL..."
  pkill -KILL -x "$APP_PROCESS_NAME" >/dev/null 2>&1 || true

  for _ in {1..5}; do
    if ! pgrep -x "$APP_PROCESS_NAME" >/dev/null 2>&1; then
      echo "Existing process stopped after SIGKILL."
      return
    fi
    sleep 1
  done

  echo "Error: failed to stop existing $APP_PROCESS_NAME process" >&2
  exit 1
}

APP_PATH=""
build_if_needed

if [[ -z "$APP_PATH" ]]; then
  echo "Error: $APP_NAME not found in build products" >&2
  exit 1
fi

echo "Using build artifact: $APP_PATH"

shutdown_existing_app

echo "Deploying to $INSTALL_PATH..."
rm -rf "$INSTALL_PATH"
ditto "$APP_PATH" "$INSTALL_PATH"

if verify_installed_app_signature "$INSTALL_PATH"; then
  echo "Installed app signature verified."
else
  echo "Error: installed app signature verification failed." >&2
  exit 1
fi

echo "Launching $APP_NAME..."
open "$INSTALL_PATH"

echo "Build and deploy completed."
