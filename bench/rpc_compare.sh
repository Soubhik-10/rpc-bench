#!/usr/bin/env sh
set -eu

ENDPOINTS="${ENDPOINTS:-bench/rpc-endpoints.json}"
CONFIG="${CONFIG:-bench/rpc-compare-devnet.json}"
DURATION="${DURATION:-}"
DISCOVERY_BLOCKS="${DISCOVERY_BLOCKS:-}"
CALLS="${CALLS:-}"
REPORT_DIR="${REPORT_DIR:-reports}"

python bench/rpc_compare.py "$ENDPOINTS" "$CONFIG" "$DURATION" "$DISCOVERY_BLOCKS" "$CALLS" "$REPORT_DIR"
