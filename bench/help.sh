#!/usr/bin/env sh
set -eu

cat <<EOF
Targets:
  make version          - Show Kurtosis version
  make engine-start     - Start Kurtosis engine
  make engine-status    - Show Kurtosis engine status
  make mainnet-up       - Launch persistent Reth mainnet RPC enclave
  make fuzz-up          - Launch private Reth fuzz/stress enclave
  make compare-up       - Launch 3 local Reth images plus 1 standard Reth node
  make inspect-mainnet  - Show mainnet enclave services and mapped ports
  make inspect-fuzz     - Show fuzz enclave services and mapped ports
  make inspect-compare  - Show compare enclave services and mapped ports
  make probe            - Probe RPC readiness and enabled APIs; set RPC_URL=...
  make bench            - Run static RPC bench; set RPC_URL=...
  make bench-dynamic    - Run dynamic sampled RPC bench; set RPC_URL=...
  make compare          - Compare correctness and latency across endpoints
  make bench-smoke      - One-second local failure-path smoke test

Overrides: RPC_URL=${RPC_URL:-http://127.0.0.1:8545} DURATION=${DURATION:-120} CONCURRENCY=${CONCURRENCY:-32} DISCOVERY_BLOCKS=${DISCOVERY_BLOCKS:-32} ENDPOINTS=${ENDPOINTS:-bench/rpc-endpoints.json}
Reports:   CALLS=${CALLS:-duration-limited} REPORT_DIR=${REPORT_DIR:-reports}
EOF
