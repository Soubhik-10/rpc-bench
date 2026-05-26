SHELL := powershell.exe
.SHELLFLAGS := -NoProfile -ExecutionPolicy Bypass -Command

ENCLAVE_MAINNET ?= reth-mainnet-rpc
ENCLAVE_FUZZ ?= reth-fuzz-stress
ETH_PACKAGE ?= github.com/ethpandaops/ethereum-package
RPC_URL ?= http://127.0.0.1:8545
DURATION ?= 120
CONCURRENCY ?= 32
DISCOVERY_BLOCKS ?= 32
CONFIG ?= bench/rpc-mainnet-like.json
DYNAMIC_CONFIG ?= bench/rpc-dynamic-mainnet.json

.DEFAULT_GOAL := help

.PHONY: help version engine-start engine-status mainnet-up fuzz-up inspect-mainnet inspect-fuzz probe bench bench-dynamic bench-smoke clean-mainnet clean-fuzz

help:
	@Write-Output @('Targets:', '  make version          - Show Kurtosis version', '  make engine-start     - Start Kurtosis engine', '  make engine-status    - Show Kurtosis engine status', '  make mainnet-up       - Launch persistent Reth mainnet RPC enclave', '  make fuzz-up          - Launch private Reth fuzz/stress enclave', '  make inspect-mainnet  - Show mainnet enclave services and mapped ports', '  make inspect-fuzz     - Show fuzz enclave services and mapped ports', '  make probe            - Probe RPC readiness and enabled APIs; set RPC_URL=...', '  make bench            - Run static RPC bench; set RPC_URL=...', '  make bench-dynamic    - Run dynamic sampled RPC bench; set RPC_URL=...', '  make bench-smoke      - One-second local failure-path smoke test', '', 'Overrides: RPC_URL=$(RPC_URL) DURATION=$(DURATION) CONCURRENCY=$(CONCURRENCY) DISCOVERY_BLOCKS=$(DISCOVERY_BLOCKS)')

version:
	@kurtosis version

engine-start:
	@kurtosis engine start

engine-status:
	@kurtosis engine status

mainnet-up:
	@kurtosis run --enclave $(ENCLAVE_MAINNET) $(ETH_PACKAGE) --args-file kurtosis/reth-mainnet-rpc.yaml --image-download always

fuzz-up:
	@kurtosis run --enclave $(ENCLAVE_FUZZ) $(ETH_PACKAGE) --args-file kurtosis/reth-fuzz-stress-devnet.yaml --image-download always

inspect-mainnet:
	@kurtosis enclave inspect $(ENCLAVE_MAINNET)

inspect-fuzz:
	@kurtosis enclave inspect $(ENCLAVE_FUZZ)

probe:
	@powershell -ExecutionPolicy Bypass -File bench/Invoke-RpcProbe.ps1 -RpcUrl $(RPC_URL)

bench:
	@powershell -ExecutionPolicy Bypass -File bench/Invoke-RpcBench.ps1 -Config $(CONFIG) -RpcUrl $(RPC_URL) -DurationSeconds $(DURATION) -Concurrency $(CONCURRENCY)

bench-dynamic:
	@powershell -ExecutionPolicy Bypass -File bench/Invoke-RpcBench.ps1 -Config $(DYNAMIC_CONFIG) -RpcUrl $(RPC_URL) -DurationSeconds $(DURATION) -Concurrency $(CONCURRENCY) -DiscoveryBlocks $(DISCOVERY_BLOCKS)

bench-smoke:
	@powershell -ExecutionPolicy Bypass -File bench/Invoke-RpcBench.ps1 -RpcUrl http://127.0.0.1:1 -DurationSeconds 1 -Concurrency 2

clean-mainnet:
	@kurtosis enclave rm -f $(ENCLAVE_MAINNET)

clean-fuzz:
	@kurtosis enclave rm -f $(ENCLAVE_FUZZ)
