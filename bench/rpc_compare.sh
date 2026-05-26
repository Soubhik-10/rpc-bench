#!/usr/bin/env sh
set -eu

ENDPOINTS="${ENDPOINTS:-bench/rpc-endpoints.json}"
CONFIG="${CONFIG:-bench/rpc-compare-devnet.json}"
DURATION="${DURATION:-}"
DISCOVERY_BLOCKS="${DISCOVERY_BLOCKS:-}"

python - "$ENDPOINTS" "$CONFIG" "$DURATION" "$DISCOVERY_BLOCKS" <<'PY'
import copy
import json
import math
import random
import sys
import time
import urllib.error
import urllib.request
from collections import defaultdict

endpoints_path, config_path, duration_override, discovery_override = sys.argv[1:5]

with open(endpoints_path, "r", encoding="utf-8") as f:
    endpoints = json.load(f)["endpoints"]
with open(config_path, "r", encoding="utf-8") as f:
    bench = json.load(f)

if duration_override:
    bench["durationSeconds"] = int(duration_override)
if discovery_override:
    bench["blockSampleSize"] = int(discovery_override)

timeout = bench.get("timeoutMs", 15000) / 1000

def rpc(url, method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}, separators=(",", ":")).encode()
    request = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"})
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

def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"))

def percentile(values, pct):
    if not values:
        return 0
    values = sorted(values)
    index = max(0, min(len(values) - 1, math.ceil((pct / 100) * len(values)) - 1))
    return round(values[index], 2)

print(f"Comparison: {bench['name']}")
print("Endpoints:")
for endpoint in endpoints:
    print(f"  {endpoint['name']}: {endpoint['url']}")
print()

heights = []
for endpoint in endpoints:
    ok, _, result, error = rpc(endpoint["url"], "eth_blockNumber", [])
    if not ok:
        raise SystemExit(f"Could not read block number from {endpoint['name']}: {error}")
    heights.append({"name": endpoint["name"], "block": from_hex_quantity(result), "blockHex": result})

common_block = max(0, min(item["block"] for item in heights) - 2)
sample_size = max(1, int(bench.get("blockSampleSize", 24)))
sample_from = max(0, common_block - sample_size + 1)
tx_hashes = []

for block_number in range(sample_from, common_block + 1):
    ok, _, block, _ = rpc(endpoints[0]["url"], "eth_getBlockByNumber", [to_hex_quantity(block_number), True])
    if ok and block:
        for tx in block.get("transactions", []):
            tx_hash = tx.get("hash") if isinstance(tx, dict) else tx
            if tx_hash:
                tx_hashes.append(tx_hash)

context = {
    "commonBlock": common_block,
    "commonBlockHex": to_hex_quantity(common_block),
    "sampleFromBlock": sample_from,
    "sampleFromBlockHex": to_hex_quantity(sample_from),
    "txHashes": tx_hashes,
}

print("Endpoint heights:")
for item in heights:
    print(f"  {item['name']:<12} {item['blockHex']}")
print(f"Common compare block: {context['commonBlockHex']}")
print(f"Sample range:         {context['sampleFromBlockHex']}..{context['commonBlockHex']}")
print(f"Sampled txs:          {len(tx_hashes)}\n")

def resolve(value):
    if isinstance(value, str):
        if value == "{{commonBlock}}":
            return context["commonBlockHex"]
        if value == "{{sampleFromBlock}}":
            return context["sampleFromBlockHex"]
        if value == "{{randomCommonBlock}}":
            return to_hex_quantity(random.randint(context["sampleFromBlock"], context["commonBlock"]))
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
mismatches = []
rounds = 0

while time.time() < deadline:
    rounds += 1
    request = random.choice(weighted)
    params = resolve(copy.deepcopy(request.get("params", [])))
    responses = []
    for endpoint in endpoints:
        ok, latency, result, error = rpc(endpoint["url"], request["method"], params)
        row = {
            "request": request["name"],
            "endpoint": endpoint["name"],
            "ok": ok,
            "latency": latency,
            "canonical": canonical(result) if ok else "ERROR:" + str(error),
            "error": error,
        }
        responses.append(row)
        results.append(row)

    if request.get("compare", True):
        baseline = responses[0]
        for response in responses[1:]:
            if baseline["canonical"] != response["canonical"]:
                mismatches.append({
                    "request": request["name"],
                    "params": json.dumps(params, separators=(",", ":")),
                    "baseline": baseline["endpoint"],
                    "compared": response["endpoint"],
                    "baselineSample": baseline["canonical"][:180],
                    "comparedSample": response["canonical"][:180],
                })

print(f"Rounds:     {rounds}")
print(f"RPC calls:   {len(results)}")
print(f"Mismatches: {len(mismatches)}\n")

print("Latency by endpoint")
print(f"{'endpoint':<16} {'calls':>7} {'ok':>7} {'fail':>7} {'p50':>9} {'p95':>9} {'p99':>9}")
by_endpoint = defaultdict(list)
for row in results:
    by_endpoint[row["endpoint"]].append(row)
for name in sorted(by_endpoint):
    rows = by_endpoint[name]
    oks = [row for row in rows if row["ok"]]
    lats = [row["latency"] for row in oks]
    print(f"{name:<16} {len(rows):>7} {len(oks):>7} {len(rows)-len(oks):>7} {percentile(lats,50):>9} {percentile(lats,95):>9} {percentile(lats,99):>9}")

print("\nLatency by request and endpoint")
print(f"{'request / endpoint':<66} {'calls':>7} {'p50':>9} {'p95':>9} {'p99':>9}")
by_pair = defaultdict(list)
for row in results:
    by_pair[(row["request"], row["endpoint"])].append(row)
for key in sorted(by_pair):
    rows = by_pair[key]
    lats = [row["latency"] for row in rows if row["ok"]]
    print(f"{key[0] + ' / ' + key[1]:<66} {len(rows):>7} {percentile(lats,50):>9} {percentile(lats,95):>9} {percentile(lats,99):>9}")

if mismatches:
    print("\nFirst mismatches")
    for mismatch in mismatches[:10]:
        print(json.dumps(mismatch, indent=2))
    raise SystemExit(2)
PY
