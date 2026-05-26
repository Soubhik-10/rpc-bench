import copy
import json
import random
import sys
import time
import urllib.error
import urllib.request
from collections import defaultdict

from reporting import ensure_report_paths, machine_info, percentile, write_html_report, write_json


endpoints_path, config_path, duration_override, discovery_override, calls_override, report_dir = sys.argv[1:7]

with open(endpoints_path, "r", encoding="utf-8") as f:
    endpoints = json.load(f)["endpoints"]
with open(config_path, "r", encoding="utf-8") as f:
    bench = json.load(f)

if duration_override:
    bench["durationSeconds"] = int(duration_override)
if discovery_override:
    bench["blockSampleSize"] = int(discovery_override)
if calls_override:
    bench["roundLimit"] = int(calls_override)

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
tx_samples = []

for block_number in range(sample_from, common_block + 1):
    ok, _, block, _ = rpc(endpoints[0]["url"], "eth_getBlockByNumber", [to_hex_quantity(block_number), True])
    if ok and block:
        for tx in block.get("transactions", []):
            tx_hash = tx.get("hash") if isinstance(tx, dict) else tx
            if tx_hash:
                tx_hashes.append(tx_hash)
            if isinstance(tx, dict) and tx_hash:
                call = None
                if tx.get("to"):
                    call = {
                        "from": tx.get("from"),
                        "to": tx.get("to"),
                        "gas": tx.get("gas"),
                        "gasPrice": tx.get("gasPrice"),
                        "value": tx.get("value", "0x0"),
                        "data": tx.get("input", "0x"),
                    }
                    call = {key: value for key, value in call.items() if value is not None}
                tx_samples.append({
                    "hash": tx_hash,
                    "from": tx.get("from"),
                    "to": tx.get("to") or tx.get("from"),
                    "blockNumber": tx.get("blockNumber") or to_hex_quantity(block_number),
                    "blockHash": tx.get("blockHash") or block.get("hash"),
                    "transactionIndex": tx.get("transactionIndex", "0x0"),
                    "call": call,
                })

if not tx_samples:
    raise SystemExit("No transactions were sampled from the devnet via RPC. Wait for the Kurtosis devnet to produce transactions, then rerun the compare bench.")

context = {
    "commonBlock": common_block,
    "commonBlockHex": to_hex_quantity(common_block),
    "sampleFromBlock": sample_from,
    "sampleFromBlockHex": to_hex_quantity(sample_from),
    "txHashes": tx_hashes,
    "txSamples": tx_samples,
}

print("Endpoint heights:")
for item in heights:
    print(f"  {item['name']:<12} {item['blockHex']}")
print(f"Common compare block: {context['commonBlockHex']}")
print(f"Sample range:         {context['sampleFromBlockHex']}..{context['commonBlockHex']}")
print(f"Sampled txs:          {len(tx_samples)}\n")


def resolve(value, sample):
    if isinstance(value, str):
        if value == "{{commonBlock}}":
            return context["commonBlockHex"]
        if value == "{{sampleFromBlock}}":
            return context["sampleFromBlockHex"]
        if value == "{{sampledBlock}}":
            return sample["blockNumber"]
        if value == "{{sampledBlockHash}}":
            return sample["blockHash"]
        if value == "{{sampledTxHash}}":
            return sample["hash"]
        if value == "{{sampledTxIndex}}":
            return sample["transactionIndex"]
        if value == "{{sampledTxSender}}":
            return sample["from"]
        if value == "{{sampledTxTo}}":
            return sample["to"]
        if value == "{{sampledTxCall}}":
            if not sample["call"]:
                return {
                    "from": sample["from"],
                    "to": sample["to"],
                    "data": "0x",
                    "value": "0x0",
                }
            return sample["call"]
        return value
    if isinstance(value, list):
        return [resolve(item, sample) for item in value]
    if isinstance(value, dict):
        return {key: resolve(item, sample) for key, item in value.items()}
    return value


weighted = []
for request in bench["requests"]:
    weighted.extend([request] * int(request.get("weight", 1)))

deadline = time.time() + int(bench["durationSeconds"])
round_limit = int(bench.get("roundLimit", 0) or 0)
results = []
mismatches = []
rounds = 0

while time.time() < deadline:
    if round_limit and rounds >= round_limit:
        break
    rounds += 1
    request = random.choice(weighted)
    sample = random.choice(context["txSamples"])
    params = resolve(copy.deepcopy(request.get("params", [])), sample)
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

successes = [row for row in results if row["ok"]]
summary = {
    "rounds": rounds,
    "calls": len(results),
    "successes": len(successes),
    "failures": len(results) - len(successes),
    "success_rate": len(successes) / max(1, len(results)),
    "mismatches": len(mismatches),
}

print(f"Rounds:     {rounds}")
print(f"RPC calls:   {len(results)}")
print(f"Mismatches: {len(mismatches)}\n")

endpoint_rows = []
print("Latency by endpoint")
print(f"{'endpoint':<16} {'calls':>7} {'ok':>7} {'fail':>7} {'p50':>9} {'p95':>9} {'p99':>9}")
by_endpoint = defaultdict(list)
for row in results:
    by_endpoint[row["endpoint"]].append(row)
for name in sorted(by_endpoint):
    rows = by_endpoint[name]
    oks = [row for row in rows if row["ok"]]
    lats = [row["latency"] for row in oks]
    item = {
        "endpoint": name,
        "calls": len(rows),
        "ok": len(oks),
        "fail": len(rows) - len(oks),
        "p50_ms": percentile(lats, 50),
        "p95_ms": percentile(lats, 95),
        "p99_ms": percentile(lats, 99),
    }
    endpoint_rows.append(item)
    print(f"{name:<16} {item['calls']:>7} {item['ok']:>7} {item['fail']:>7} {item['p50_ms']:>9} {item['p95_ms']:>9} {item['p99_ms']:>9}")

pair_rows = []
print("\nLatency by request and endpoint")
print(f"{'request / endpoint':<66} {'calls':>7} {'p50':>9} {'p95':>9} {'p99':>9}")
by_pair = defaultdict(list)
for row in results:
    by_pair[(row["request"], row["endpoint"])].append(row)
for key in sorted(by_pair):
    rows = by_pair[key]
    lats = [row["latency"] for row in rows if row["ok"]]
    item = {
        "request_endpoint": key[0] + " / " + key[1],
        "request": key[0],
        "endpoint": key[1],
        "calls": len(rows),
        "p50_ms": percentile(lats, 50),
        "p95_ms": percentile(lats, 95),
        "p99_ms": percentile(lats, 99),
    }
    pair_rows.append(item)
    print(f"{item['request_endpoint']:<66} {item['calls']:>7} {item['p50_ms']:>9} {item['p95_ms']:>9} {item['p99_ms']:>9}")

if mismatches:
    print("\nFirst mismatches")
    for mismatch in mismatches[:10]:
        print(json.dumps(mismatch, indent=2))

report = {
    "generated_at": time.strftime("%Y-%m-%d %H:%M:%S %z"),
    "kind": "compare",
    "machine": machine_info(),
    "config": {
        "name": bench["name"],
        "durationSeconds": bench["durationSeconds"],
        "roundLimit": round_limit,
        "blockSampleSize": sample_size,
        "endpoints": endpoints,
    },
    "endpoint_heights": heights,
    "dynamic_context": context,
    "summary": summary,
    "endpoints": endpoint_rows,
    "request_endpoints": pair_rows,
    "mismatches": mismatches[:100],
}
json_path, html_path = ensure_report_paths(report_dir, "rpc-compare")
write_json(json_path, report)
write_html_report(
    html_path,
    report,
    f"RPC Compare Report: {bench['name']}",
    [(endpoint_rows, "p95_ms", "endpoint", "p95 Latency by Endpoint"), (endpoint_rows, "calls", "endpoint", "Calls by Endpoint")],
    [
        ("Endpoints", endpoint_rows, [("Endpoint", "endpoint"), ("Calls", "calls"), ("OK", "ok"), ("Fail", "fail"), ("p50 ms", "p50_ms"), ("p95 ms", "p95_ms"), ("p99 ms", "p99_ms")]),
        ("Request / Endpoint", pair_rows, [("Request / Endpoint", "request_endpoint"), ("Calls", "calls"), ("p50 ms", "p50_ms"), ("p95 ms", "p95_ms"), ("p99 ms", "p99_ms")]),
        ("Mismatches", mismatches[:25], [("Request", "request"), ("Compared", "compared"), ("Params", "params"), ("Baseline", "baselineSample"), ("Compared Sample", "comparedSample")]),
    ],
)
print(f"\nReport JSON: {json_path}")
print(f"Report HTML: {html_path}")

if mismatches:
    raise SystemExit(2)
