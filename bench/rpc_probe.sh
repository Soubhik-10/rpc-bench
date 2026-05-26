#!/usr/bin/env sh
set -eu

RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
TIMEOUT="${TIMEOUT:-15}"

python - "$RPC_URL" "$TIMEOUT" <<'PY'
import json
import sys
import time
import urllib.error
import urllib.request

rpc_url = sys.argv[1]
timeout = float(sys.argv[2])

def rpc(method, params=None):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or []}).encode()
    request = urllib.request.Request(rpc_url, data=body, headers={"Content-Type": "application/json"})
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

checks = [
    ("web3_clientVersion", []),
    ("eth_chainId", []),
    ("net_version", []),
    ("net_peerCount", []),
    ("eth_syncing", []),
    ("eth_blockNumber", []),
    ("txpool_status", []),
]

print(f"RPC probe: {rpc_url}\n")
print(f"{'method':<24} {'ok':<5} {'ms':>10} summary")
print("-" * 86)

block_number = None
for method, params in checks:
    ok, latency, result, error = rpc(method, params)
    if method == "eth_blockNumber" and ok:
        block_number = result
    summary = json.dumps(result, separators=(",", ":")) if ok else error
    if len(summary) > 120:
        summary = summary[:120] + "..."
    print(f"{method:<24} {str(ok):<5} {latency:>10.2f} {summary}")

if block_number:
    ok, latency, result, error = rpc("eth_getBlockByNumber", [block_number, False])
    print("\nLatest block header")
    if ok:
        print(json.dumps({
            "number": result.get("number"),
            "hash": result.get("hash"),
            "transactions": len(result.get("transactions", [])),
            "gasUsed": result.get("gasUsed"),
            "baseFeePerGas": result.get("baseFeePerGas"),
        }, indent=2))
    else:
        print(error)
PY
