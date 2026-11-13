#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

protoc \
  --proto_path="$SCRIPT_DIR" \
  --dart_out=grpc:"$SCRIPT_DIR" \
  "$SCRIPT_DIR/fusion.proto"

cd "$PROJECT_ROOT"
dart run tool/patch_generated_proto.dart
