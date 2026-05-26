#!/usr/bin/env sh
set -eu

CONFIG="${CONFIG:-bench/rpc-mainnet-like.json}"
RPC_URL="${RPC_URL:-}"
DURATION="${DURATION:-}"
CONCURRENCY="${CONCURRENCY:-}"
DISCOVERY_BLOCKS="${DISCOVERY_BLOCKS:-}"
CALLS="${CALLS:-}"
REPORT_DIR="${REPORT_DIR:-reports}"

python bench/rpc_bench.py "$CONFIG" "$RPC_URL" "$DURATION" "$CONCURRENCY" "$DISCOVERY_BLOCKS" "$CALLS" "$REPORT_DIR"
