#!/bin/bash
set -euo pipefail

SCHEME="ClaudeIsland"
CONFIGURATION="Release"
APP_NAME="Claude Island.app"
APP_PROCESS_NAME="Claude Island"
APP_BUNDLE_ID="com.celestial.ClaudeIsland"
INSTALL_PATH="/Applications/$APP_NAME"
DERIVED_DATA_ROOT="$HOME/Library/Developer/Xcode/DerivedData"

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

echo "Building $SCHEME ($CONFIGURATION)..."
xcodebuild -scheme "$SCHEME" -configuration "$CONFIGURATION" build

APP_PATH="$(find "$DERIVED_DATA_ROOT" -path "*/Build/Products/$CONFIGURATION/$APP_NAME" -print | head -1)"

if [[ -z "$APP_PATH" ]]; then
  echo "Error: $APP_NAME not found in build products" >&2
  exit 1
fi

echo "Using build artifact: $APP_PATH"

shopt -s nullglob
FRAMEWORKS_DIR="$APP_PATH/Contents/Frameworks"
if [[ -d "$FRAMEWORKS_DIR" ]]; then
  for framework in "$FRAMEWORKS_DIR"/*.framework; do
    echo "Re-signing $(basename "$framework")..."
    codesign --force --sign - "$framework"
  done
fi
shopt -u nullglob

echo "Re-signing $APP_NAME..."
codesign --force --sign - --deep "$APP_PATH"

shutdown_existing_app

echo "Deploying to $INSTALL_PATH..."
rm -rf "$INSTALL_PATH"
ditto "$APP_PATH" "$INSTALL_PATH"

echo "Launching $APP_NAME..."
open "$INSTALL_PATH"

echo "Build and deploy completed."
