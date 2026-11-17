"""Worked example: a staged ensemble forecast, shaped like a real research plugin.

What it shows, in the order a real plugin does it:

  1. read parameters from /in/params.json
  2. stage intermediate data in /scratch (falls back to /tmp if not available)
  3. write a NetCDF forecast and a CSV summary as declared artefacts in /out
  4. report progress as it goes, and write result.json last

The numbers are synthetic placeholders.

Run using the conformance harness, from the repository root:

    docker build --platform linux/amd64 -t forecast-example forecast_example
    ./conformance/conform.sh forecast-example --definition plugin.json

The "demo" parameter intentionally violates one platform rule, so you can
see what each failure looks like before your own code encounters it. See the README.
"""

import csv
import json
import os
import shutil
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone

import numpy as np
from netCDF4 import Dataset

IN, OUT = "/in", "/out"
WORK = "/scratch" if os.path.isdir("/scratch") else "/tmp"


def progress(pct, note):
    # Overwrite, never append: the platform reports the latest state
    with open(f"{OUT}/progress.json", "w") as f:
        json.dump({"pct": pct, "note": note}, f)
    print(f"[{pct:3d}%] {note}")


def result(status, summary, **extra):
    with open(f"{OUT}/result.json", "w") as f:
        json.dump({"status": status, "summary": summary, **extra}, f)


def demo(name):
    """Intentionally break a platform rule."""
    if name == "write_root":
        # Read-only root filesystem: OSError, errno 30
        open("/app/cache.bin", "w").write("x")
    elif name == "exec_tmp":
        # /tmp, /out and /scratch are noexec: PermissionError, errno 13
        shutil.copy("/bin/true", "/tmp/helper")
        os.chmod("/tmp/helper", 0o755)
        subprocess.run(["/tmp/helper"], check=True)
    elif name == "network":
        # No network at all: name resolution fails
        import urllib.request
        urllib.request.urlopen("https://example.org", timeout=10)
    elif name == "undeclared":
        # Not in plugin.json "artifacts": a warning in the harness, INVALID_OUTPUT on the platform
        os.makedirs(f"{OUT}/diagnostics", exist_ok=True)
        open(f"{OUT}/diagnostics/debug.log", "w").write("an arguably useful file, but undeclared\n")
    elif name == "oversized":
        # Past output_mb: ENOSPC, in the harness exactly as on the platform
        with open(f"{OUT}/forecast/padding.csv", "w") as f:
            while True:
                f.write("0," * 4096 + "\n")
    elif name != "none":
        raise SystemExit(f"unknown demo: {name}")


def main():
    with open(f"{IN}/params.json") as f:
        params = json.load(f)
    members = int(params.get("ensemble_members", 10))
    days = int(params.get("lead_days", 7))
    issued = params.get("forecast_issue_date") or datetime.now(timezone.utc).strftime("%Y%m%d%H")
    issue_time = datetime.strptime(issued, "%Y%m%d%H").replace(tzinfo=timezone.utc)
    os.makedirs(f"{OUT}/forecast", exist_ok=True)

    progress(5, f"Warm-up state, {members} members, working in {WORK}")
    rng = np.random.default_rng(int(issued))
    state = rng.gamma(2.0, 15.0, size=(members, 24 * 30))  # 30 days of hourly warm-up
    np.save(f"{WORK}/warmup_state.npy", state)  # intermediate: /scratch, never /out

    demo(params.get("demo", "none"))

    progress(20, "Running ensemble")
    state = np.load(f"{WORK}/warmup_state.npy")
    hours = 24 * days
    flows = np.empty((hours, members), dtype="f4")
    level = state[:, -24:].mean(axis=1)
    for h in range(hours):
        level = 0.97 * level + rng.gamma(1.5, 0.5, size=members)
        flows[h] = level
        if h % 24 == 0:
            progress(40 + int(50 * h / hours), f"Lead day {h // 24 + 1} of {days}")
    time.sleep(0.2)

    progress(92, "Writing NetCDF and CSV")
    with Dataset(f"{OUT}/forecast/streamflow_ensemble.nc", "w", format="NETCDF4") as nc:
        nc.createDimension("time", hours)
        nc.createDimension("member", members)
        t = nc.createVariable("time", "i4", ("time",))
        t.units = f"hours since {issue_time:%Y-%m-%d %H:%M:%S} UTC"
        t[:] = np.arange(hours)
        q = nc.createVariable("streamflow", "f4", ("time", "member"), zlib=True)
        q.units = "ML/d"
        q[:] = flows
        nc.title = "Synthetic ensemble streamflow (Outlands worked example)"

    with open(f"{OUT}/forecast/daily_summary.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["date", "p10_ml_d", "median_ml_d", "p90_ml_d"])
        for d in range(days):
            day = flows[24 * d:24 * (d + 1)].mean(axis=0)
            w.writerow([(issue_time + timedelta(days=d)).date().isoformat(),
                        *(round(float(np.percentile(day, p)), 2) for p in (10, 50, 90))])

    median = float(np.median(flows[-24:]))
    # A declared diagnostics file: matched by "diagnostics/*.txt" in plugin.json
    os.makedirs(f"{OUT}/diagnostics", exist_ok=True)
    with open(f"{OUT}/diagnostics/run_notes.txt", "w") as f:
        f.write(f"issued {issued}, {members} members, {days} lead days, scratch at {WORK}\n")
    progress(100, "Done")
    # Last: a success result.json means everything above finished
    result("success", f"{members}-member {days}-day forecast issued {issued}; "
                      f"final-day median {median:.1f} ML/d",
           issued=issued, members=members, lead_days=days)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        # A crash is still worth a result.json: the platform shows your reason
        print(f"ERROR: {type(exc).__name__}: {exc}", file=sys.stderr)
        try:
            result("failure", f"{type(exc).__name__}: {exc}"[:500])
        except OSError:
            pass  # /out itself is the problem (full, say); the exit code still tells
        raise
