#!/usr/bin/env sh
set -eu

CONFIG="${CONFIG:-bench/rpc-mainnet-like.json}"
RPC_URL="${RPC_URL:-}"
DURATION="${DURATION:-}"
CONCURRENCY="${CONCURRENCY:-}"
DISCOVERY_BLOCKS="${DISCOVERY_BLOCKS:-}"

python - "$CONFIG" "$RPC_URL" "$DURATION" "$CONCURRENCY" "$DISCOVERY_BLOCKS" <<'PY'
import concurrent.futures
import copy
import json
import math
import random
import statistics
import sys
import time
import urllib.error
import urllib.request
from collections import Counter, defaultdict

config_path, rpc_override, duration_override, concurrency_override, discovery_override = sys.argv[1:6]

with open(config_path, "r", encoding="utf-8") as f:
    bench = json.load(f)

if rpc_override:
    bench["rpcUrl"] = rpc_override
if duration_override:
    bench["durationSeconds"] = int(duration_override)
if concurrency_override:
    bench["concurrency"] = int(concurrency_override)
if discovery_override:
    bench.setdefault("dynamic", {})["enabled"] = True
    bench["dynamic"]["blockSampleSize"] = int(discovery_override)

timeout = bench.get("timeoutMs", 15000) / 1000

def rpc(method, params, request_id=1):
    body = json.dumps({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}, separators=(",", ":")).encode()
    request = urllib.request.Request(bench["rpcUrl"], data=body, headers={"Content-Type": "application/json"})
    start = time.perf_counter()
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = json.loads(response.read().decode())
        latency = (time.perf_counter() - start) * 1000
        if "error" in payload:
            return False, latency, None, payload["error"].get("message", str(payload["error"]))
        return True, latency, payload.get("result"), None
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        latency = (time.perf_counter() - start) * 1000
        return False, latency, None, str(exc)

def from_hex_quantity(value):
    return int(value, 16) if value else 0

def to_hex_quantity(value):
    return hex(int(value))

context = {"enabled": False}
dynamic = bench.get("dynamic", {})
if dynamic.get("enabled"):
    sample_size = int(dynamic.get("blockSampleSize", 32))
    print(f"Discovering dynamic RPC sample from {sample_size} recent blocks...")
    ok, _, latest_hex, error = rpc("eth_blockNumber", [])
    if not ok:
        raise SystemExit(f"eth_blockNumber failed during discovery: {error}")
    latest = from_hex_quantity(latest_hex)
    safe_latest = max(0, latest - 2)
    sample_from = max(0, safe_latest - sample_size + 1)
    tx_hashes = []
    for block_number in range(sample_from, safe_latest + 1):
        ok, _, block, _ = rpc("eth_getBlockByNumber", [to_hex_quantity(block_number), True])
        if ok and block:
            for tx in block.get("transactions", []):
                tx_hash = tx.get("hash") if isinstance(tx, dict) else tx
                if tx_hash:
                    tx_hashes.append(tx_hash)
    context = {
        "enabled": True,
        "latestBlock": latest,
        "latestBlockHex": to_hex_quantity(latest),
        "safeLatestBlock": safe_latest,
        "safeLatestBlockHex": to_hex_quantity(safe_latest),
        "fromBlock": sample_from,
        "fromBlockHex": to_hex_quantity(sample_from),
        "txHashes": tx_hashes,
    }
    print(f"Latest block: {context['latestBlockHex']}")
    print(f"Sample range: {context['fromBlockHex']}..{context['safeLatestBlockHex']}")
    print(f"Sampled txs:  {len(tx_hashes)}\n")

def resolve(value):
    if isinstance(value, str):
        if value == "{{latestBlock}}":
            return context["latestBlockHex"]
        if value == "{{safeLatestBlock}}":
            return context["safeLatestBlockHex"]
        if value == "{{sampleFromBlock}}":
            return context["fromBlockHex"]
        if value == "{{randomRecentBlock}}":
            return to_hex_quantity(random.randint(context["fromBlock"], context["safeLatestBlock"]))
        if value == "{{randomTxHash}}":
            return random.choice(context["txHashes"]) if context["txHashes"] else "0x" + "0" * 64
        return value
    if isinstance(value, list):
        return [resolve(item) for item in value]
    if isinstance(value, dict):
        return {key: resolve(item) for key, item in value.items()}
    return value

weighted = []
for request in bench["requests"]:
    weighted.extend([request] * int(request.get("weight", 1)))

deadline = time.time() + int(bench["durationSeconds"])
results = []

def worker(worker_id):
    local_results = []
    request_id = worker_id * 1_000_000
    while time.time() < deadline:
        request = random.choice(weighted)
        request_id += 1
        params = resolve(copy.deepcopy(request.get("params", []))) if context["enabled"] else request.get("params", [])
        ok, latency, _, error = rpc(request["method"], params, request_id)
        local_results.append({"name": request["name"], "ok": ok, "latency": latency, "error": error})
    return local_results

print(f"Benchmark: {bench['name']}")
print(f"RPC URL:   {bench['rpcUrl']}")
print(f"Duration:  {bench['durationSeconds']}s")
print(f"Workers:   {bench['concurrency']}")
print(f"Dynamic:   {context['enabled']}\n")

with concurrent.futures.ThreadPoolExecutor(max_workers=int(bench["concurrency"])) as executor:
    for batch in executor.map(worker, range(int(bench["concurrency"]))):
        results.extend(batch)

def percentile(values, pct):
    if not values:
        return 0
    values = sorted(values)
    index = max(0, min(len(values) - 1, math.ceil((pct / 100) * len(values)) - 1))
    return round(values[index], 2)

successes = [row for row in results if row["ok"]]
print(f"Total requests: {len(results)}")
print(f"Throughput:     {len(results) / max(1, int(bench['durationSeconds'])):.2f} req/s")
print(f"Success rate:   {len(successes) / max(1, len(results)):.2%}\n")

latencies = [row["latency"] for row in successes]
print("Overall latency, successful requests only")
print(f"p50={percentile(latencies, 50)}ms p90={percentile(latencies, 90)}ms p95={percentile(latencies, 95)}ms p99={percentile(latencies, 99)}ms\n")

print("Per-method summary")
by_name = defaultdict(list)
for row in results:
    by_name[row["name"]].append(row)
print(f"{'method':<52} {'count':>7} {'ok':>7} {'fail':>7} {'p50':>9} {'p95':>9} {'p99':>9}")
for name in sorted(by_name):
    rows = by_name[name]
    oks = [row for row in rows if row["ok"]]
    lats = [row["latency"] for row in oks]
    print(f"{name:<52} {len(rows):>7} {len(oks):>7} {len(rows)-len(oks):>7} {percentile(lats,50):>9} {percentile(lats,95):>9} {percentile(lats,99):>9}")

errors = Counter(row["error"] for row in results if not row["ok"])
if errors:
    print("\nTop errors")
    for error, count in errors.most_common(10):
        print(f"{count:>7} {error}")
PY
