"""Example plugin that behaves according to stipulated Outlands requirements;
demonstrates platform behaviour and reactions.

While trivial in core operation, this plugin demonstrates some key behaviours:

  1. read its parameters from /in/params.json
  2. report progress while it works, by overwriting /out/progress.json
  3. write its answer to /out/result.json
  4. write any other outputs that are expected, and nothing unexpected

Limitations for the plugin author
---------------------------------
Your container runs without any network access of any kind.

This includes retrieving external data, connecting to databases or APIs, sending
telemetry data to your main servers, or installing a package at runtime.

Everything you require to run must already be in your image (or declared as a build-
time requirement in your source code, e.g. requirements.txt), and any data you need
is staged into /in for you before your plugin starts.

Your plugin interacts through the following directories:
  /in     read-only. Your parameters and any datasets you subscribed to.
  /out    writable. Everything you produce goes here.
  /tmp    writable, small, and thrown away.

Everything your plugin prints goes into the job log, which you may review and download later.
"""

import csv
import json
import os
import sys
import time
from datetime import datetime, timezone
# For formatted local date/time in result.json
from zoneinfo import ZoneInfo

IN = "/in"
OUT = "/out"


def write_progress(pct=None, note=None):
    """Indicate self-declared progress

    OVERWRITE this file - do not append.

    The platform reads this file's contents every few seconds and only reports it when it
    changes.

    You may declare either a percentage progress ('pct') or a general note on progress, or both:
      pct   an integer 0-100. Self-declared.  Use your own determination on progress.
      note  a short line of text, e.g. "Stage 4 of 17".  Limited to 120 chars.

    IMPORTANT:  Other researchers waiting in the queue can see this text, so keep it
    informative and do not declare anything secret.  It is primarily intended as a vehicle to inform other
    plugin authors that your job is progressing, so that their own job will eventually be able
    to run.
    """
    payload = {}
    if pct is not None:
        payload["pct"] = int(pct)
    if note is not None:
        payload["note"] = note[:120]

    # Write to a temporary file and rename it into place. rename() is atomic,
    # so the reader never catches a half-written file. Not strictly required -
    # the platform ignores a file it cannot parse and tries again - but it is
    # recommended practice.
    tmp = os.path.join(OUT, ".progress.json.tmp")
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(payload, handle)
    os.replace(tmp, os.path.join(OUT, "progress.json"))


def report_error(message):
    """Declare a problem WITHOUT crashing.

    Use this when your run cannot produce a usable answer but your code is
    working exactly as written - such as when input data is received that
    may be malformed or empty. You are not crashing, nor should you pretend
    to succeed; you are self-declaring an issue not relating to your own code.

    Append to the list as necessary if subsequent issues are detected.  The platform
    tracks what it has already seen and only logs new entries.

    The 'datetime' field is optional. Include it if the exact moment matters;
    leave it out and the platform timestamps it when it is committed to logs.
    """
    path = os.path.join(OUT, "errors.json")
    try:
        with open(path, encoding="utf-8") as handle:
            doc = json.load(handle)
    except (OSError, ValueError):
        doc = {"errors": []}

    doc["errors"].append({
        "error": message,
        # The platform will automatically timestamp your output with current time,
        # but you may declare your own datetime if required
        "datetime": datetime.now(timezone.utc).isoformat(),
    })

    # Write-then-rename, as above
    tmp = os.path.join(OUT, ".errors.json.tmp")
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(doc, handle, indent=2)
    os.replace(tmp, path)


def main():
    # --- 1. read your parameters --------------------------------------------
    # /in/params.json is always present and is always valid JSON: the platform
    # validated it against your declared parameter list before your container
    # started, so a missing or malformed value should never reach you.
    with open(os.path.join(IN, "params.json"), encoding="utf-8") as handle:
        params = json.load(handle)

    # Parse out keys from your own input parameters
    steps = int(params.get("steps", 10))
    delay_s = float(params.get("delay_s", 1.0))

    print(f"Starting: {steps} steps, {delay_s}s apart")
    write_progress(pct=0, note="Initialising")

    # --- 2. do the work, reporting as you go --------------------------------
    # Accumulate results as you go rather than recomputing them later. Trivial
    # here, but it follows the shape of a real job: results are captured into a
    # structure, and everything afterwards reads from that structure.
    rows = []
    total = 0
    for step in range(1, steps + 1):
        square = step * step
        total += square
        rows.append({"step": step, "square": square, "running_total": total})
        time.sleep(delay_s)

        # Report on progress.  Either a percentage, or a note, or both
        # This sample code reports both.  The percentage drives a progress bar;
        # the note is visible to all researchers in the Research Centre.
        write_progress(
            pct=int(step / steps * 100),
            note=f"Summing squares, step {step} of {steps}",
        )
        # General plugin output is created by printing to the terminal.  This is
        # captured automatically into job logs and can be downloaded later.
        print(f"  step {step}/{steps}: running total {total}")

    # --- 3. write any artefacts you declared --------------------------------
    # Anything you write to /out must match the artefact patterns declared when
    # your plugin was onboarded. An undeclared file fails the entire job.

    # Plugin was onboarded with *.csv declared as expected output
    with open(os.path.join(OUT, "squares.csv"), "w", encoding="utf-8",
              newline="") as handle:
        writer = csv.DictWriter(
            handle, fieldnames=["step", "square", "running_total"])
        writer.writeheader()
        writer.writerows(rows)

    # --- 4. write your result -----------------------------------------------
    # result.json is REQUIRED and its absence fails the job. Two fields are required:
    #   status   "success" or "failure" - your own verdict on your own run
    #   summary  a one line summary (capped to 500 chars)
    # Status is case-sensitive and must match exactly "success" or "failure".
    # You may write other keys to result.json as you wish; these are captured by
    # the platform and archived as part of your job results.  Plugin authors may
    # download job results from the Research Centre.
    result = {
        "status": "success",
        # Limit output to 500 chars, if necessary
        "summary": f"Summed {steps} squares; total {total}"[:500],
        "steps": steps,
        "total": total,
        "final_row": rows[-1] if rows else None,
        # 01 JAN 2026, 1:23 PM AEDT. Day-first with a named month so it cannot
        # be misinterpreted as a US date by any audience, and %Z names the local
        # timezone (AEST/AEDT).  The container clock is UTC.
        #
        # Change the actual timezone to suit your own audience.
        #
        # NOTE using ZoneInfo requires the timezone database, which minimal images
        # such as python:3-slim do not include - see requirements.txt.
        "finished_at": datetime.now(ZoneInfo("Australia/Melbourne"))
                       .strftime("%d %b %Y, %-I:%M %p %Z").upper()
    }
    with open(os.path.join(OUT, "result.json"), "w", encoding="utf-8") as handle:
        json.dump(result, handle, indent=2)

    # You are not obligated to write a 100% completion message but it is good practice.
    write_progress(pct=100, note="Complete")
    print(f"Done. Total {total}")

    # Exit 0 indicates the plugin ran to completion.  However the authoritative source
    # on whether your job was successful is declared in result.json
    # (e.g. "status": "success")
    return 0


if __name__ == "__main__":
    sys.exit(main())
