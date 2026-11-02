#!/bin/zsh
set -eu
cd "${0:A:h}"
mkdir -p build
xcrun swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 \
    tvcec.swift -o build/tvcec -framework IOKit -framework AppKit
codesign --force --sign - build/tvcec
print build/tvcec
