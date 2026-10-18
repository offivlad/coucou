#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-day-plan.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/DayPlanLogic.swift tests/DayPlanTests.swift -o "$TEST_DIR/day-plan-tests"
"$TEST_DIR/day-plan-tests"
