#!/bin/bash
# Run the TrailerReader tests. Pass real clip paths to also check them, and set
# PANO_OUT=<dir> to save their panoramas as PNGs.
set -euo pipefail
cd "$(dirname "$0")/.."

bin="$(mktemp -d)/trailer-tests"
xcrun -sdk macosx swiftc tests/trailer/main.swift src/TrailerReader.swift src/ProxyResolver.swift src/PanoramaView.swift -o "$bin"
"$bin" "$@"
