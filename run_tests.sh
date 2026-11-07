#!/usr/bin/env bash
# Build and run the Clipster test runner (no Xcode / XCTest required).
# Compiles the non-UI core sources together with Tests/main.swift into a plain
# executable whose assertions exit non-zero on failure.
set -euo pipefail
cd "$(dirname "$0")"

ARCH="$(uname -m)"
OUT="buildtmp/clipster-tests"
mkdir -p buildtmp

swiftc -O \
  Clipster/ClipboardManager.swift \
  Clipster/OCRService.swift \
  Clipster/AIActions.swift \
  Clipster/OllamaClient.swift \
  Tests/main.swift \
  -o "${OUT}" \
  -target "${ARCH}-apple-macos13.0" \
  -framework AppKit -framework Vision

exec "./${OUT}"
