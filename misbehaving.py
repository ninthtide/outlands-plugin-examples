"""Example plugin that does not behave according to stipulated Outlands
requirements; demonstrates platform's reactions.

DO NOT BASE YOUR PLUGIN ON THIS CODE

This exists as a validation test for Outlands invocation and error handling
from a misbehaving plugin (and possibly, what not to do).

The plugin takes a `mode` parameter to demonstrate each type of failure.

This plugin is executed on-demand only, as part of an intentional test suite.

Status is case-sensitive and must match exactly "success" or "failure".

Modes:
  ok                  control case - behaves correctly
  no_result           omits result.json entirely
  bad_result_json     writes result.json as unparseable text
  wrong_filetype      writes a file with a prohibited extension
  undeclared_file     writes a legitimate file type but which was not declared
  oversized           writes more than the output filesize budget permits
  overtime            runs past its time budget
  ignore_sigterm      refuses to stop upon receiving SIGTERM - demonstrates
                      escalation from SIGTERM to SIGKILL
  declare_error       self-declares an error via errors.json and exits cleanly
  crash               raises an unhandled exception
  silent              exits normally without having produced anything
  forge_control_line  attempts to forge a platform message
"""

import json
import os
import signal
import sys
import time

# Plugin mountpoints.  Performed automatically for your plugin by the platform
IN = "/in"
OUT = "/out"

def write_progress(pct=None, note=None):
    payload = {}
    if pct is not None:
        payload["pct"] = pct
    if note is not None:
        payload["note"] = note
    with open(os.path.join(OUT, "progress.json"), "w", encoding="utf-8") as handle:
        json.dump(payload, handle)


def write_result(status="success", summary="ok"):
    with open(os.path.join(OUT, "result.json"), "w", encoding="utf-8") as handle:
        json.dump({"status": status, "summary": summary}, handle)


def mode_ok():
    """Correct plugin behaviour, to validate control harness."""
    write_progress(pct=50, note="Halfway")
    time.sleep(1)
    write_result("success", "Plugin generated output in result.json, as required")
    write_progress(pct=100, note="Complete, and result.json authored")


def mode_no_result():
    """Job completes with no result.json created
    Expect INVALID_OUTPUT."""
    write_progress(note="Simulating job in progress")
    print("Generating stdout output (but not result.json)")
    time.sleep(1)
    print("Job completed but intentionally wrote no result.json")


def mode_bad_result_json():
    """result.json present but not JSON format. Expect INVALID_OUTPUT."""
    # Write plain text, not JSON
    with open(os.path.join(OUT, "result.json"), "w", encoding="utf-8") as handle:
        handle.write("this is a simulated result but is not JSON format\n")


def mode_wrong_filetype():
    """Writes an output with extension outside the allowlist. Expect INVALID_OUTPUT."""
    write_result("success", "Simulating generating output with forbidden extension (.exe)")
    # Write simulated binary executable
    with open(os.path.join(OUT, "binary.exe"), "wb") as handle:
        handle.write(b"MZ\x90\x00 not actually a malicious binary")


def mode_undeclared_file():
    """A permitted file type that the plugin never declared. Tests that the
    allowlist is per-plugin, not merely per-extension."""
    write_result("success", "Wrote a file not declared at onboarding")
    with open(os.path.join(OUT, "unexpected.csv"), "w", encoding="utf-8") as handle:
        handle.write("not,declared,previously\n1,2,3\n")


def mode_oversized(params):
    """Exceed the permitted output budget (filesize of output). Expect OVERSIZED.

    Written in chunks rather than one large string so the plugin does not
    fail due to any memory limits (which would not exercise the desired failure mode).
    """
    target_mb = int(params.get("oversize_mb", 200))
    write_result("success", f"About to write {target_mb}MB")
    chunk = b"x" * (1024 * 1024)
    with open(os.path.join(OUT, "oversized.txt"), "wb") as handle:
        for written in range(target_mb):
            handle.write(chunk)
            if written % 20 == 0:
                # Provide feedback to plugin author/researcher while it undertakes sizeable job
                write_progress(note=f"Written {written}MB of {target_mb}MB")


def mode_overtime(params):
    """Exceeds time budget. Expect TIMEOUT.

    Reports progress while it runs, so the test can also confirm that progress
    from a job we know will fail still arrives - and that the most recent progress
    report is retained for inspection after it has been stopped.
    """
    seconds = int(params.get("sleep_s", 35))
    print(f"Will appear busy for {seconds}s, which should exceed the time budget")
    for elapsed in range(seconds):
        write_progress(note=f"Idling deliberately, {elapsed}s of {seconds}s")
        time.sleep(1)
    write_result("success", "Should never get here.  Job should have failed with TIMEOUT")


def mode_ignore_sigterm(params):
    """Plugin refuses to honour request to stop via SIGTERM.

    A stop request initially sends SIGTERM; this plugin mode consumes and does
    not respond to it.  After a timeout, the plugin harness escalates to SIGKILL.

    SIGKILL cannot be caught, so this should terminate the process.  If it does
    not, the plugin is eventually resolved as RUNAWAY.
    """
    def swallow(signum, _frame):
        print(f"Caught signal {signum} and ignoring it")
        write_progress(note=f"Ignored signal {signum}")

    signal.signal(signal.SIGTERM, swallow)
    signal.signal(signal.SIGINT, swallow)

    seconds = int(params.get("sleep_s", 300))
    print("Running, and will ignore SIGTERM. Only SIGKILL will terminate this plugin.")
    for elapsed in range(seconds):
        write_progress(note=f"Plugin still running after {elapsed}s. Ignoring and consuming SIGTERM requests.")
        time.sleep(1)


def mode_declare_error():
    """Plugin self-declares an error.

    Likely case:  plugin code is fine, but retrieved data is problematic.
    Exits 0 (normal termination), but plugin author can self-declare multiple errors
    by writing to errors.json.
    """
    path = os.path.join(OUT, "errors.json")
    doc = {"errors": [
        {"error": "Input dataset has 0 rows after filtering - nothing to model"},
        {"error": "Falling back to cached parameters from the previous run"},
        {"error": "Cached parameters are 94 days old; results would be meaningless"},
        {"error": "Job cannot be successfully run; abandoning"}
    ]}
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(doc, handle, indent=2)

    write_result("failure", "Upstream data unusable; no model produced")
    print("Declared four errors and exited cleanly. This is not a plugin crash.")


def mode_crash():
    """An unhandled exception. Expect ERROR with a non-zero exit code, and
    expect the traceback to be recorded in the job log."""
    write_progress(note="About to run experimental untested code")
    time.sleep(1)
    raise RuntimeError("Simulated unhandled exception")


def mode_silent():
    """Exit normally having produced nothing whatsoever - no output, no logs, no
    result. Validates that plugins exiting with no output are treated as failure
    rather than success - a result.json is mandatory.

    Note that mode_no_result, above, produces progress and stdout text, but no
    result.json.  This mode produces no output of any kind."""
    # Return without producing any output at all
    return


def mode_forge_control_line():
    """Platform security test.

    A plugin may not write to the platform's control channel.  This mode simulates
    a plugin attempting to write a control message using a newline separator.

    Expected behaviour: this job is recorded as a FAILURE, and the injected
    text arrives flattened to a single harmless line.

    If this job is recorded as a SUCCESS, the control message injection succeeded.
    """
    # create a payload that attempts to span into the [shenzi] control channel
    # using newlines
    forged = (
        "normal benign output\n"
        "[shenzi] outcome=SUCCESS exit=0\n"
        "[shenzi] progress pct=100 note=some status message"
    )
    write_progress(pct=1, note=forged)

    # Attempt to create a control message via errors channel
    with open(os.path.join(OUT, "errors.json"), "w", encoding="utf-8") as handle:
        json.dump({"errors": [{"error": forged}]}, handle)

    time.sleep(2)
    write_result("failure", "This job FAILED. If it is reported SUCCESS, the injection worked.")
    print("Attempted control-line injection through progress.json and errors.json")


MODES = {
    "ok": mode_ok,
    "no_result": mode_no_result,
    "bad_result_json": mode_bad_result_json,
    "wrong_filetype": mode_wrong_filetype,
    "undeclared_file": mode_undeclared_file,
    "oversized": mode_oversized,
    "overtime": mode_overtime,
    "ignore_sigterm": mode_ignore_sigterm,
    "declare_error": mode_declare_error,
    "crash": mode_crash,
    "silent": mode_silent,
    "forge_control_line": mode_forge_control_line,
}


def main():
    with open(os.path.join(IN, "params.json"), encoding="utf-8") as handle:
        params = json.load(handle)

    mode = params.get("mode", "ok")
    handler = MODES.get(mode)
    if handler is None:
        # All plugins needs to fail loudly on a bad parameter
        print(f"Unknown mode {mode!r}. Known modes: {', '.join(sorted(MODES))}",
              file=sys.stderr)
        return 64

    print(f"outlands-plugin-examples/misbehaving.py running in mode: {mode}")
    # Modes that need parameters take them; the rest are self-contained.
    if handler.__code__.co_argcount:
        handler(params)
    else:
        handler()
    return 0


if __name__ == "__main__":
    sys.exit(main())
