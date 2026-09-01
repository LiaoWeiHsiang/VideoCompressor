#!/usr/bin/env bash
#
# Catches the one Swift mistake this project keeps making: `try await` inside an
# XCTUnwrap/XCTAssert autoclosure, which those APIs cannot support. It costs a full device
# test run to discover from the compiler, and the fix is always the same — hoist the await
# into a local first.
#
set -euo pipefail
cd "$(dirname "$0")/.."

if grep -rn "XCTUnwrap(\s*try await\|XCTUnwrap(try await\|XCTAssert[A-Za-z]*(try await" Tests/ 2>/dev/null; then
  echo
  echo "error: 'try await' inside an autoclosure. Assign it to a local first:"
  echo "    let value = try await something()"
  echo "    let unwrapped = try XCTUnwrap(value)"
  exit 1
fi
echo "test lint: clean"
