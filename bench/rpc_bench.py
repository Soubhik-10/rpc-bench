import concurrent.futures
import copy
import json
import random
import sys
import time
import urllib.error
import urllib.request
from collections import Counter, defaultdict

from reporting import ensure_report_paths, machine_info, percentile, write_html_report, write_json


config_path, rpc_override, duration_override, concurrency_override, discovery_override, calls_override, report_dir = sys.argv[1:8]

with open(config_path, "r", encoding="utf-8") as f:
    bench = json.load(f)

if rpc_override:
    bench["rpcUrl"] = rpc_override
if duration_override:
    bench["durationSeconds"] = int(duration_override)
if concurrency_override:
    bench["concurrency"] = int(concurrency_override)
if calls_override:
    bench["callLimit"] = int(calls_override)
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
call_limit = int(bench.get("callLimit", 0) or 0)
results = []


def worker(worker_id, worker_call_limit):
    local_results = []
    request_id = worker_id * 1_000_000
    while time.time() < deadline:
        if worker_call_limit and len(local_results) >= worker_call_limit:
            break
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
print(f"Calls:     {call_limit or 'duration-limited'}")
print(f"Dynamic:   {context['enabled']}\n")

workers = int(bench["concurrency"])
per_worker_limit = 0
if call_limit:
    per_worker_limit = max(1, (call_limit + workers - 1) // workers)

with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as executor:
    for batch in executor.map(lambda wid: worker(wid, per_worker_limit), range(workers)):
        results.extend(batch)
        if call_limit and len(results) >= call_limit:
            results = results[:call_limit]
            break

successes = [row for row in results if row["ok"]]
latencies = [row["latency"] for row in successes]
summary = {
    "calls": len(results),
    "rounds": len(results),
    "successes": len(successes),
    "failures": len(results) - len(successes),
    "success_rate": len(successes) / max(1, len(results)),
    "mismatches": 0,
    "throughput": len(results) / max(1, int(bench["durationSeconds"])),
    "p50_ms": percentile(latencies, 50),
    "p95_ms": percentile(latencies, 95),
    "p99_ms": percentile(latencies, 99),
}

print(f"Total requests: {summary['calls']}")
print(f"Throughput:     {summary['throughput']:.2f} req/s")
print(f"Success rate:   {summary['success_rate']:.2%}\n")
print("Overall latency, successful requests only")
print(f"p50={summary['p50_ms']}ms p95={summary['p95_ms']}ms p99={summary['p99_ms']}ms\n")

method_rows = []
by_name = defaultdict(list)
for row in results:
    by_name[row["name"]].append(row)
print("Per-method summary")
print(f"{'method':<52} {'count':>7} {'ok':>7} {'fail':>7} {'p50':>9} {'p95':>9} {'p99':>9}")
for name in sorted(by_name):
    rows = by_name[name]
    oks = [row for row in rows if row["ok"]]
    lats = [row["latency"] for row in oks]
    item = {
        "method": name,
        "count": len(rows),
        "ok": len(oks),
        "fail": len(rows) - len(oks),
        "p50_ms": percentile(lats, 50),
        "p95_ms": percentile(lats, 95),
        "p99_ms": percentile(lats, 99),
    }
    method_rows.append(item)
    print(f"{name:<52} {item['count']:>7} {item['ok']:>7} {item['fail']:>7} {item['p50_ms']:>9} {item['p95_ms']:>9} {item['p99_ms']:>9}")

errors = Counter(row["error"] for row in results if not row["ok"])
if errors:
    print("\nTop errors")
    for error, count in errors.most_common(10):
        print(f"{count:>7} {error}")

report = {
    "generated_at": time.strftime("%Y-%m-%d %H:%M:%S %z"),
    "kind": "bench",
    "machine": machine_info(),
    "config": {
        "name": bench["name"],
        "rpcUrl": bench["rpcUrl"],
        "durationSeconds": bench["durationSeconds"],
        "concurrency": bench["concurrency"],
        "callLimit": call_limit,
        "discoveryBlocks": dynamic.get("blockSampleSize"),
    },
    "dynamic_context": context,
    "summary": summary,
    "methods": method_rows,
    "errors": [{"error": error, "count": count} for error, count in errors.most_common()],
}
json_path, html_path = ensure_report_paths(report_dir, "rpc-bench")
write_json(json_path, report)
write_html_report(
    html_path,
    report,
    f"RPC Bench Report: {bench['name']}",
    [(method_rows, "p95_ms", "method", "p95 Latency by Method"), (method_rows, "count", "method", "Calls by Method")],
    [("Methods", method_rows, [("Method", "method"), ("Count", "count"), ("OK", "ok"), ("Fail", "fail"), ("p50 ms", "p50_ms"), ("p95 ms", "p95_ms"), ("p99 ms", "p99_ms")])],
)
print(f"\nReport JSON: {json_path}")
print(f"Report HTML: {html_path}")
