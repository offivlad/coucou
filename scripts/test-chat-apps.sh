#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-chat-apps.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/ChatAppWatcherLogic.swift \
    tests/ChatAppWatcherTests.swift -o "$TEST_DIR/chat-app-tests"
"$TEST_DIR/chat-app-tests"
