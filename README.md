# Reth Mainnet-Like RPC Bench

This workspace contains Kurtosis configs for Reth RPC benchmarking and Bash
runners for latency, correctness, and HTML report generation.

## Install / Verify Kurtosis

Kurtosis is installed on this machine at `C:\Users\soubh\Desktop\kurtosis.exe`.
It was upgraded from `1.11.0` to `1.18.3`; the old binary is backed up at
`C:\Users\soubh\Desktop\kurtosis.exe.1.11.0.bak`.

Official docs for Windows recommend WSL, but also document a native Windows
archive install. Docker Desktop must be running before Kurtosis can launch an
enclave.

## Start the Reth Mainnet RPC Node

```sh
kurtosis run --enclave reth-mainnet-rpc github.com/ethpandaops/ethereum-package --args-file kurtosis/reth-mainnet-rpc.yaml --image-download always
```

Then inspect the enclave and copy the mapped `rpc` URL for `el-1-reth-lighthouse`:

```sh
kurtosis enclave inspect reth-mainnet-rpc
```

The RPC URL will look like `http://127.0.0.1:<mapped-port>`.

## Start the Private Fuzz/Stress Network

Use this when you want transaction fuzzing, generated load, stability checks,
and noisy mempool/block production behavior without touching real mainnet:

```sh
kurtosis run --enclave reth-fuzz-stress github.com/ethpandaops/ethereum-package --args-file kurtosis/reth-fuzz-stress-devnet.yaml --image-download always
```

This config enables `tx_fuzz`, `spamoor`, `assertoor`, `prometheus`, `grafana`,
and `dora` against a private Reth/Lighthouse network. It is less realistic for
historical mainnet state, but much better for fuzzing writes and stress traffic.

## Run the Benchmark

Update `bench/rpc-mainnet-like.json` or override the URL at runtime:

```sh
RPC_URL=http://127.0.0.1:<mapped-port> sh bench/rpc_bench.sh
```

Useful overrides:

```sh
RPC_URL=http://127.0.0.1:<mapped-port> DURATION=300 CONCURRENCY=64 sh bench/rpc_bench.sh
```

You can cap by total calls instead of only time:

```sh
RPC_URL=http://127.0.0.1:<mapped-port> DURATION=300 CONCURRENCY=64 CALLS=10000 sh bench/rpc_bench.sh
```

There is also a dynamic workload that discovers the latest block, samples recent
blocks for real transaction hashes, and then mixes block, tx, receipt, log,
fee-history, call, txpool, and trace requests:

```sh
CONFIG=bench/rpc-dynamic-mainnet.json RPC_URL=http://127.0.0.1:<mapped-port> sh bench/rpc_bench.sh
```

## Make Targets

The Makefile wraps the common flow:

```sh
make engine-start
make mainnet-up
make inspect-mainnet
make probe RPC_URL=http://127.0.0.1:<mapped-port>
make bench-dynamic RPC_URL=http://127.0.0.1:<mapped-port> DURATION=300 CONCURRENCY=64 DISCOVERY_BLOCKS=64 CALLS=10000
```

Useful targets:

`make probe`, `make bench`, `make bench-dynamic`, `make fuzz-up`, `make inspect-fuzz`,
`make engine-status`, `make clean-mainnet`, `make clean-fuzz`.

Every benchmark run writes a JSON report and an HTML report with simple charts
under `reports/` by default. Override with `REPORT_DIR=/path/to/reports`.

## Compare Local Reth Images Against Standard Reth

Build or tag three local Reth Docker images:

```sh
docker build -t reth-local-a:latest <path-to-reth>
docker tag reth-local-a:latest reth-local-b:latest
docker tag reth-local-a:latest reth-local-c:latest
```

Launch the four-node private comparison network:

```sh
make compare-up
make inspect-compare
```

The first three EL nodes use `reth-local-a:latest`, `reth-local-b:latest`, and
`reth-local-c:latest`. The fourth node leaves `el_image` blank, so
ethereum-package uses its standard/default Reth image.

Copy `bench/rpc-endpoints.example.json` to `bench/rpc-endpoints.json`, then fill
in the mapped `rpc` ports from `make inspect-compare`:

```json
{
  "endpoints": [
    { "name": "local-a", "url": "http://127.0.0.1:<el-1-rpc-port>" },
    { "name": "local-b", "url": "http://127.0.0.1:<el-2-rpc-port>" },
    { "name": "local-c", "url": "http://127.0.0.1:<el-3-rpc-port>" },
    { "name": "standard", "url": "http://127.0.0.1:<el-4-rpc-port>" }
  ]
}
```

Run the correctness and latency comparison:

```sh
make compare DURATION=300 DISCOVERY_BLOCKS=32 CALLS=5000
```

The comparator finds the common safe block across all endpoints, samples recent
transactions from the baseline endpoint, sends identical RPC calls to every
endpoint, measures latency, and exits non-zero if comparable responses differ.
The HTML report includes detected CPU/memory/Docker metadata, endpoint latency
charts, per-request latency tables, and the first mismatch samples.

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
