SHELL := /bin/sh
.SHELLFLAGS := -c

ENCLAVE_MAINNET ?= reth-mainnet-rpc
ENCLAVE_FUZZ ?= reth-fuzz-stress
ENCLAVE_COMPARE ?= reth-compare
ETH_PACKAGE ?= github.com/ethpandaops/ethereum-package
RPC_URL ?= http://127.0.0.1:8545
DURATION ?= 120
CONCURRENCY ?= 32
DISCOVERY_BLOCKS ?= 32
CONFIG ?= bench/rpc-mainnet-like.json
DYNAMIC_CONFIG ?= bench/rpc-dynamic-mainnet.json
COMPARE_CONFIG ?= bench/rpc-compare-devnet.json
ENDPOINTS ?= bench/rpc-endpoints.json

.DEFAULT_GOAL := help

.PHONY: help version engine-start engine-status mainnet-up fuzz-up compare-up inspect-mainnet inspect-fuzz inspect-compare probe bench bench-dynamic compare bench-smoke clean-mainnet clean-fuzz clean-compare

help:
	@RPC_URL='$(RPC_URL)' DURATION='$(DURATION)' CONCURRENCY='$(CONCURRENCY)' DISCOVERY_BLOCKS='$(DISCOVERY_BLOCKS)' ENDPOINTS='$(ENDPOINTS)' sh bench/help.sh

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

compare-up:
	@kurtosis run --enclave $(ENCLAVE_COMPARE) $(ETH_PACKAGE) --args-file kurtosis/reth-compare-local-vs-standard.yaml --image-download always

inspect-mainnet:
	@kurtosis enclave inspect $(ENCLAVE_MAINNET)

inspect-fuzz:
	@kurtosis enclave inspect $(ENCLAVE_FUZZ)

inspect-compare:
	@kurtosis enclave inspect $(ENCLAVE_COMPARE)

probe:
	@RPC_URL='$(RPC_URL)' sh bench/rpc_probe.sh

bench:
	@CONFIG='$(CONFIG)' RPC_URL='$(RPC_URL)' DURATION='$(DURATION)' CONCURRENCY='$(CONCURRENCY)' sh bench/rpc_bench.sh

bench-dynamic:
	@CONFIG='$(DYNAMIC_CONFIG)' RPC_URL='$(RPC_URL)' DURATION='$(DURATION)' CONCURRENCY='$(CONCURRENCY)' DISCOVERY_BLOCKS='$(DISCOVERY_BLOCKS)' sh bench/rpc_bench.sh

compare:
	@ENDPOINTS='$(ENDPOINTS)' CONFIG='$(COMPARE_CONFIG)' DURATION='$(DURATION)' DISCOVERY_BLOCKS='$(DISCOVERY_BLOCKS)' sh bench/rpc_compare.sh

bench-smoke:
	@RPC_URL='http://127.0.0.1:1' DURATION='1' CONCURRENCY='2' sh bench/rpc_bench.sh

clean-mainnet:
	@kurtosis enclave rm -f $(ENCLAVE_MAINNET)

clean-fuzz:
	@kurtosis enclave rm -f $(ENCLAVE_FUZZ)

clean-compare:
	@kurtosis enclave rm -f $(ENCLAVE_COMPARE)
