#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-ask-claude.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/AskClaudeLogic.swift \
    tests/AskClaudeTests.swift -o "$TEST_DIR/ask-claude-tests"
"$TEST_DIR/ask-claude-tests"
