#!/usr/bin/env bash
# Build and run the Clipster test runner (no Xcode / XCTest required).
# Compiles the non-UI core sources together with Tests/main.swift into a plain
# executable whose assertions exit non-zero on failure.
set -euo pipefail
cd "$(dirname "$0")"

ARCH="$(uname -m)"
OUT="buildtmp/clipster-tests"
mkdir -p buildtmp

# Weak-link FoundationModels when the SDK has it (matches build_noxcode.sh);
# the Apple Intelligence test skips itself where the model is unavailable.
FM_FLAGS=""
if [ -d "$(xcrun --show-sdk-path)/System/Library/Frameworks/FoundationModels.framework" ]; then
  FM_FLAGS="-Xfrontend -disable-autolink-framework -Xfrontend FoundationModels -Xlinker -weak_framework -Xlinker FoundationModels"
fi

swiftc -O \
  Clipster/ClipboardManager.swift \
  Clipster/OCRService.swift \
  Clipster/AIActions.swift \
  Clipster/AppleFMProvider.swift \
  Tests/main.swift \
  -o "${OUT}" \
  -target "${ARCH}-apple-macos13.0" \
  -framework AppKit -framework Vision \
  ${FM_FLAGS}

exec "./${OUT}"
