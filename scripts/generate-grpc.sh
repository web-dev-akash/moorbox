#!/bin/bash
# Regenerates Sources/EmulatorControl/Generated from Proto/emulator_controller.proto.
# Needs `protoc` (on PATH, or set PROTOC; official release zips work) and the two plugins, built from the same
# versions as the package dependencies:
#   swift-protobuf      (product protoc-gen-swift)
#   grpc-swift-protobuf (product protoc-gen-grpc-swift-2)
# Set PROTOC_GEN_SWIFT and PROTOC_GEN_GRPC_SWIFT to their paths.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${PROTOC_GEN_SWIFT:?path to protoc-gen-swift}"
: "${PROTOC_GEN_GRPC_SWIFT:?path to protoc-gen-grpc-swift-2}"
OUT=Sources/EmulatorControl/Generated
rm -f "$OUT"/*.swift
"${PROTOC:-protoc}" --proto_path=Proto \
  --plugin=protoc-gen-swift="$PROTOC_GEN_SWIFT" \
  --plugin=protoc-gen-grpc-swift="$PROTOC_GEN_GRPC_SWIFT" \
  --swift_opt=Visibility=Public --swift_out="$OUT" \
  --grpc-swift_opt=Visibility=Public,Server=false,Client=true --grpc-swift_out="$OUT" \
  emulator_controller.proto
echo "Generated: $(ls "$OUT")"
