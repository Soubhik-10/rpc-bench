# Reth Mainnet-Like RPC Bench

This workspace contains a Kurtosis config for a persistent Reth mainnet RPC node
and a small PowerShell JSON-RPC benchmark runner.

## Install / Verify Kurtosis

Kurtosis is installed on this machine at `C:\Users\soubh\Desktop\kurtosis.exe`.
It was upgraded from `1.11.0` to `1.18.3`; the old binary is backed up at
`C:\Users\soubh\Desktop\kurtosis.exe.1.11.0.bak`.

Official docs for Windows recommend WSL, but also document a native Windows
archive install. Docker Desktop must be running before Kurtosis can launch an
enclave.

## Start the Reth Mainnet RPC Node

```powershell
kurtosis run --enclave reth-mainnet-rpc github.com/ethpandaops/ethereum-package --args-file kurtosis/reth-mainnet-rpc.yaml --image-download always
```

Then inspect the enclave and copy the mapped `rpc` URL for `el-1-reth-lighthouse`:

```powershell
kurtosis enclave inspect reth-mainnet-rpc
```

The RPC URL will look like `http://127.0.0.1:<mapped-port>`.

## Start the Private Fuzz/Stress Network

Use this when you want transaction fuzzing, generated load, stability checks,
and noisy mempool/block production behavior without touching real mainnet:

```powershell
kurtosis run --enclave reth-fuzz-stress github.com/ethpandaops/ethereum-package --args-file kurtosis/reth-fuzz-stress-devnet.yaml --image-download always
```

This config enables `tx_fuzz`, `spamoor`, `assertoor`, `prometheus`, `grafana`,
and `dora` against a private Reth/Lighthouse network. It is less realistic for
historical mainnet state, but much better for fuzzing writes and stress traffic.

## Run the Benchmark

Update `bench/rpc-mainnet-like.json` or override the URL at runtime:

```powershell
powershell -ExecutionPolicy Bypass -File bench/Invoke-RpcBench.ps1 -RpcUrl http://127.0.0.1:<mapped-port>
```

Useful overrides:

```powershell
powershell -ExecutionPolicy Bypass -File bench/Invoke-RpcBench.ps1 -RpcUrl http://127.0.0.1:<mapped-port> -DurationSeconds 300 -Concurrency 64
```

There is also a dynamic workload that discovers the latest block, samples recent
blocks for real transaction hashes, and then mixes block, tx, receipt, log,
fee-history, call, txpool, and trace requests:

```powershell
powershell -ExecutionPolicy Bypass -File bench/Invoke-RpcBench.ps1 -Config bench/rpc-dynamic-mainnet.json -RpcUrl http://127.0.0.1:<mapped-port>
```

## Make Targets

The Makefile wraps the common flow:

```powershell
make engine-start
make mainnet-up
make inspect-mainnet
make probe RPC_URL=http://127.0.0.1:<mapped-port>
make bench-dynamic RPC_URL=http://127.0.0.1:<mapped-port> DURATION=300 CONCURRENCY=64
```

Useful targets:

`make probe`, `make bench`, `make bench-dynamic`, `make fuzz-up`, `make inspect-fuzz`,
`make engine-status`, `make clean-mainnet`, `make clean-fuzz`.

## Mainnet-Like Notes

This config targets real Ethereum mainnet instead of a tiny private devnet. That
makes RPC behavior much closer to production for state reads, block lookups,
fee history, log filters, txpool, and trace calls.

Transaction fuzzing is deliberately split into `reth-fuzz-stress-devnet.yaml`.
Fuzzers and spammers are for private funded networks; on a mainnet-synced node
they either cannot produce useful transactions or can become operationally risky.

Expect large disk usage, long sync time, and heavy CPU/RAM pressure. The Reth
cache is set to 8 GiB, so Docker Desktop should have substantially more memory
available than that. For archive-heavy RPC methods, use an archive-oriented
Reth configuration and budget much more disk.
