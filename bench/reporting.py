import html
import json
import os
import platform
import socket
import subprocess
import time
from pathlib import Path


def machine_info():
    info = {
        "hostname": socket.gethostname(),
        "platform": platform.platform(),
        "system": platform.system(),
        "release": platform.release(),
        "machine": platform.machine(),
        "processor": platform.processor(),
        "python": platform.python_version(),
        "cpu_count": os.cpu_count(),
        "memory_total_bytes": None,
        "docker": None,
    }

    if platform.system().lower() == "windows":
        try:
            import ctypes

            class MemoryStatus(ctypes.Structure):
                _fields_ = [
                    ("dwLength", ctypes.c_ulong),
                    ("dwMemoryLoad", ctypes.c_ulong),
                    ("ullTotalPhys", ctypes.c_ulonglong),
                    ("ullAvailPhys", ctypes.c_ulonglong),
                    ("ullTotalPageFile", ctypes.c_ulonglong),
                    ("ullAvailPageFile", ctypes.c_ulonglong),
                    ("ullTotalVirtual", ctypes.c_ulonglong),
                    ("ullAvailVirtual", ctypes.c_ulonglong),
                    ("ullAvailExtendedVirtual", ctypes.c_ulonglong),
                ]

            status = MemoryStatus()
            status.dwLength = ctypes.sizeof(MemoryStatus)
            ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(status))
            info["memory_total_bytes"] = int(status.ullTotalPhys)
        except Exception:
            pass
    else:
        try:
            with open("/proc/meminfo", "r", encoding="utf-8") as f:
                for line in f:
                    if line.startswith("MemTotal:"):
                        info["memory_total_bytes"] = int(line.split()[1]) * 1024
                        break
        except OSError:
            pass

    try:
        proc = subprocess.run(
            ["docker", "info", "--format", "{{json .}}"],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        if proc.returncode == 0 and proc.stdout.strip():
            docker = json.loads(proc.stdout)
            info["docker"] = {
                "server_version": docker.get("ServerVersion"),
                "operating_system": docker.get("OperatingSystem"),
                "architecture": docker.get("Architecture"),
                "cpus": docker.get("NCPU"),
                "memory_total_bytes": docker.get("MemTotal"),
            }
    except Exception:
        pass

    return info


def percentile(values, pct):
    if not values:
        return 0
    values = sorted(values)
    index = max(0, min(len(values) - 1, int((pct / 100) * len(values) + 0.999999) - 1))
    return round(values[index], 2)


def ensure_report_paths(report_dir, prefix):
    Path(report_dir).mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    base = Path(report_dir) / f"{prefix}-{stamp}"
    return base.with_suffix(".json"), base.with_suffix(".html")


def write_json(path, payload):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2, sort_keys=True)


def _bar_svg(items, value_key, label_key, title):
    width = 860
    row_h = 28
    left = 190
    height = max(90, 52 + row_h * len(items))
    max_value = max([item.get(value_key, 0) or 0 for item in items] + [1])
    rows = []
    for idx, item in enumerate(items):
        y = 42 + idx * row_h
        value = item.get(value_key, 0) or 0
        bar_w = int((width - left - 80) * value / max_value)
        label = html.escape(str(item.get(label_key, ""))[:32])
        rows.append(f'<text x="10" y="{y + 16}" class="axis">{label}</text>')
        rows.append(f'<rect x="{left}" y="{y}" width="{bar_w}" height="18" rx="2"></rect>')
        rows.append(f'<text x="{left + bar_w + 8}" y="{y + 15}" class="value">{value}</text>')
    return f"""
    <section>
      <h2>{html.escape(title)}</h2>
      <svg viewBox="0 0 {width} {height}" role="img">
        {''.join(rows)}
      </svg>
    </section>
    """


def _table(rows, columns):
    head = "".join(f"<th>{html.escape(label)}</th>" for label, _ in columns)
    body = []
    for row in rows:
        cells = "".join(f"<td>{html.escape(str(row.get(key, '')))}</td>" for _, key in columns)
        body.append(f"<tr>{cells}</tr>")
    return f"<table><thead><tr>{head}</tr></thead><tbody>{''.join(body)}</tbody></table>"


def write_html_report(path, payload, title, charts, tables):
    machine = payload.get("machine", {})
    docker = machine.get("docker") or {}
    config = payload.get("config", {})
    summary = payload.get("summary", {})
    mismatch_count = summary.get("mismatches", 0)
    status_class = "bad" if mismatch_count else "good"
    status_text = "MISMATCHES" if mismatch_count else "OK"

    chart_html = "\n".join(_bar_svg(*chart) for chart in charts)
    table_html = "\n".join(f"<section><h2>{html.escape(name)}</h2>{_table(rows, cols)}</section>" for name, rows, cols in tables)

    doc = f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{html.escape(title)}</title>
  <style>
    body {{ margin: 0; font: 14px/1.45 system-ui, -apple-system, Segoe UI, sans-serif; color: #17202a; background: #f5f7f8; }}
    header {{ padding: 28px 32px; background: #17202a; color: white; }}
    main {{ padding: 24px 32px 48px; max-width: 1200px; margin: 0 auto; }}
    h1 {{ margin: 0 0 8px; font-size: 30px; }}
    h2 {{ margin: 0 0 14px; font-size: 18px; }}
    section {{ background: white; border: 1px solid #d8dee4; border-radius: 6px; padding: 18px; margin: 0 0 18px; }}
    .grid {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(210px, 1fr)); gap: 12px; }}
    .metric {{ background: white; border: 1px solid #d8dee4; border-radius: 6px; padding: 14px; }}
    .metric b {{ display: block; font-size: 24px; margin-top: 4px; }}
    .status {{ display: inline-block; padding: 4px 10px; border-radius: 999px; font-weight: 700; }}
    .good {{ background: #d8f3dc; color: #1b5e20; }}
    .bad {{ background: #ffe0e0; color: #9f1d20; }}
    table {{ width: 100%; border-collapse: collapse; }}
    th, td {{ text-align: left; border-bottom: 1px solid #edf0f2; padding: 8px 10px; vertical-align: top; }}
    th {{ background: #f8fafb; font-weight: 700; }}
    svg rect {{ fill: #2f80ed; }}
    svg .axis {{ fill: #344054; font-size: 13px; }}
    svg .value {{ fill: #17202a; font-size: 13px; }}
    code {{ background: #eef2f5; padding: 2px 5px; border-radius: 4px; }}
  </style>
</head>
<body>
  <header>
    <h1>{html.escape(title)}</h1>
    <div><span class="status {status_class}">{status_text}</span> generated {html.escape(payload.get("generated_at", ""))}</div>
  </header>
  <main>
    <div class="grid">
      <div class="metric">RPC calls<b>{summary.get("calls", 0)}</b></div>
      <div class="metric">Rounds<b>{summary.get("rounds", 0)}</b></div>
      <div class="metric">Success rate<b>{summary.get("success_rate", 0):.2%}</b></div>
      <div class="metric">Mismatches<b>{mismatch_count}</b></div>
    </div>
    <section>
      <h2>Run Config</h2>
      <p><code>{html.escape(json.dumps(config, sort_keys=True))}</code></p>
    </section>
    <section>
      <h2>Machine</h2>
      {_table([
        {"key": "Host", "value": machine.get("hostname")},
        {"key": "Platform", "value": machine.get("platform")},
        {"key": "CPU count", "value": machine.get("cpu_count")},
        {"key": "Memory bytes", "value": machine.get("memory_total_bytes")},
        {"key": "Docker server", "value": docker.get("server_version")},
        {"key": "Docker CPUs", "value": docker.get("cpus")},
        {"key": "Docker memory bytes", "value": docker.get("memory_total_bytes")},
      ], [("Key", "key"), ("Value", "value")])}
    </section>
    {chart_html}
    {table_html}
  </main>
</body>
</html>
"""
    with open(path, "w", encoding="utf-8") as f:
        f.write(doc)
