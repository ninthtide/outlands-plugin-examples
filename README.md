# Outlands plugin examples

Worked examples for researchers writing analysis code to run on the Outlands
research runtime (SmartRainGrid).

Two plugins are shown: one that does everything correctly, and one that does
everything wrongly intentionally, to illustrate and verify platform response to
incorrect plugin behaviour.

---

## What a plugin is

A plugin is a program that reads inputs from `/in`, performs some work, and
writes outputs to `/out`.

It runs inside a secured container, on a dedicated machine, isolated from the main
SmartRainGrid application.  The plugin is provided with required information
prior to execution (from external sources, and/or directly from the production
database), but has no network access of its own.

### The environment your code runs in

| Path | Access | What it holds |
|---|---|---|
| `/in` | read-only | `params.json`, plus any datasets you subscribed to |
| `/out` | writable, size-capped | location for all plugin output; collected after the run |
| `/scratch` | writable, size-capped, private | optional: intermediate files between the stages of one run; discarded after the run, never collected |
| `/tmp` | writable, small | temporary files; held in RAM, so it counts against your memory budget; discarded |

Nothing else is writable: the rest of the filesystem is read-only. `HOME` is set to `/tmp`.
`/out`, `/scratch` and `/tmp` won't execute anything.

`/scratch` is opt-in: please advise at onboarding if you require it and what size. Any output left
in `/out` at the end that isn't a declared output results in job failure.  Use /scratch for any temporary files during your job execution (if you requested this feature at onboarding; otherwise use /tmp, but this consumes your memory budget).

### Who your code runs as

- A numeric user id in the range 3000-3999, with the group id the same number. There is no
  username, no `/etc/passwd` entry and no other groups. Any `USER` in your image is
  overridden.
- `/in`, `/out` and `/scratch` are handed to (chowned) that user before your container starts, so
  you can always read `/in` and write to the others, whatever the number is.
- Your own files inside the image must be world-readable (and world-executable for
  programs and directories), e.g. `RUN chmod -R a+rX /app`. Group permissions will not assist with file access,
  because you won't be in your image's group. Make your `WORKDIR` world-readable too, or
  anything using relative paths will fail.
- If you'd rather build against one fixed UID number, ask at onboarding and an id will be assigned and pinned for your use.

**There is no network.** Your container cannot reach the internet, the main
database, or anything else. You cannot fetch a file, call an API, or install a
package while running. Everything you need must already be in your source code
repository (e.g. libraries declared in requirements.txt), or already included in
your container image, and any data you need is staged automatically on your
behalf by the platform, into `/in`, before your plugin starts.

This is the single most important thing to design around, and is a hard requirement
to permit the execution of contributor code at all. If your analysis needs a dataset,
you declare that when your plugin is onboarded and the data feed is refreshed on your behalf by the Outlands platform prior
to executing your job, every time.

You also run within a fixed budget: CPU, memory, wall-clock time, output size,
process count. These are agreed when your plugin is onboarded. Exceeding them
causes the job to stop and fail — the platform will tell you which limit was
exceeded.

---

## Plugin communication via files

Communication with plugins is performed by reading and writing files.

**Note the plurals in filenames: they indicate whether a file accepts multiple entries.**

### `/in/params.json` — read

Your parameters. Always present, validated by the Outlands platform prior to your plugin running.

The params.json file is validated against the parameter list you declared before
your container starts, so a missing or malformed value should never reach your code.

```python
with open("/in/params.json") as f:
    params = json.load(f)
```

### `/out/result.json` — write, exactly one

**Required.** A job that completes (even successfully) without writing a `result.json`
is considered a failure.

Two fields are significant to the platform:

```json
{
  "status": "success",
  "summary": "Summed 10 squares; total 385"
}
```

- `status` — `"success"` or `"failure"`. Your self-declared verdict on how your run performed.
- `summary` — a one line summary (max length: 500 chars)

Status is case-sensitive and must match exactly "success" or "failure".

If summary exceeds 500 chars, the text will be trimmed.  Any malicious or
unusual characters are removed.  Accented characters and diacritics are retained.

Everything else (i.e. other JSON keys) written into `result.json` is considered output that belongs to the
plugin, and is stored by the platform, subject to retention rules agreed when the
plugin was onboarded.  Results may be downloaded later from the Research Centre.

`result.json` must be under 64KB in total.  It is intended to represent a summary of your run, not a
place to store the run's output.  Bulk data output should be written as a separate file or files, and needs to be a declared artefact instead.

### `/out/progress.json` — write, overwrite freely

Optional but strongly encouraged. Indicates ongoing progress of the job as
it executes.

```json
{"pct": 76, "note": "Simulating dipole moment models"}
```

`progress.json` has to contain either a `pct` or `note` field, or both.

`pct` is a self-declared percentage completion, as determined by the plugin author.

A `note` is any free-form text indicating progress, up to 120 characters.  Longer
notes are trimmed.

**Important**: the note field is visible to all researchers using the platform (not all
users; just privileged researchers).  The intent is to signal progression through your
job, as other researchers may be watching the job queue waiting for your job to finish,
before their own job is allowed to begin, and inferring progress of your job through
the note field.

**Overwrite this file, do not append.** This file is meant to indicate current progress
or activity/position, and so should be overwritten as your plugin code carries out its
work.  The platform reads the file every few seconds and relays updates to the Research
Centre when it detects changes.

### `/out/errors.json` — write, append

Optional. For self-declaring errors that are separate from any issues with your code,
e.g. malformed input data.  **Does not halt plugin**:

```json
{
  "errors": [
    {"error": "Input dataset has 0 rows after filtering",
     "datetime": "2026-07-28T02:09:30+10:00"},
    {"error": "Cached parameters are 94 days old; cannot generate trustworthy results"}
  ]
}
```

This allows a plugin to report on situations that are neither successful runs, nor code
crashes or errors: your plugin code executed exactly as written, but your own code detected
that the run is not usable — for example, if the input data arrived malformed or empty.

While your plugin can terminate normally and write a `result.json` with `"status": "failure"`,
writing a separate `errors.json` allows you to provide more details about what you encountered
during plugin execution.

Further, your plugin might be able to recover or continue, or detect a non-fatal error, so
might eventually complete with `"status": "success"`, but still wish to declare detected
errors as part of your overall job results.

**Append to the list as required.**

`datetime` is optional; if omitted, the platform timestamps error messages with the
current platform time, once the message is committed to logs.

### Any other output you write

Any other file in `/out` must match the artefact patterns you declared when your plugin was
onboarded — for example `*.csv`. An undeclared file is unexpected and results in plugin job
failure.

Permitted types are `json`, `csv`, `txt`, `png`, `svg`, `nc`. A `.nc` file must be real
NetCDF (classic or NetCDF-4): a file that merely carries the extension is refused.

Patterns may include directories, e.g. `forecast/*.nc` or `diagnostics/*.txt`, so a tree of
diagnostic outputs can be declared once rather than file by file.

All output is retained by the platform subject to agreed retention rules (date-based or
last # of job runs), and may be downloaded from the Research Centre.

If your plugin requires authoring files of different extensions or types, or changes to
the retention rules, please discuss with the SmartRainGrid development team.

### Print freely to terminal/stdout

Anything your program prints to the terminal standard output (stdout) is captured into the
job log, for later download and review.  Output is streamed while your job runs, so the log
can be viewed live, or may be reviewed once the job has finished, as you wish.

**If you are writing in Python this works automatically** — the platform runs your container
with `PYTHONUNBUFFERED=1`.

**In any other language, you will need to flush your output.** Most runtimes buffer stdout
when it is not attached to a terminal, which includes how your plugin is deployed to Outlands.
If you do not flush your output, your messages will remain in your own process's buffer for
a long time before being sent to SmartRainGrid and being visible in the Research Centre.

---

## Example plugins

### `well_behaved.py`

Sample plugin that conforms to platform requirements.  It reads parameters, reports
progress as it executes, writes an output artefact, and writes its result.

Accepts parameters: `steps` (default 10), `delay_s` (default 1.0).

### `misbehaving.py`

**Not intended to be used as template code.** It exists so the platform can be tested
against various plugin failures, on demand, as part of automated test software.  It may also
serve as an illustration of what not to do, when writing plugin code.

One script that accepts a `mode` parameter, selecting one of twelve behaviours:

| mode | What it does |
|---|---|
| `ok` | control case - behaves correctly |
| `no_result` | omits `result.json` entirely |
| `bad_result_json` | writes `result.json` as unparseable text |
| `wrong_filetype` | writes a file with a prohibited extension |
| `undeclared_file` | writes a legitimate file type but which was not declared |
| `oversized` | writes more than the output filesize budget permits |
| `overtime` | runs past its time budget |
| `ignore_sigterm` | refuses to stop upon receiving SIGTERM |
| `declare_error` | self-declares an error via `errors.json` and exits cleanly |
| `crash` | raises an unhandled exception |
| `silent` | exits normally without having produced anything |
| `forge_control_line` | attempts to forge a platform message |

---

## Developing and testing locally

Some utilities are provided to assist you with developing your plugin and ensuring it complies with platform requirements, prior to onboarding.

`conformance/conform.sh` runs your image on your own machine using the platform's execution
rules, reads your limits from your plugin definition, and retains all plugin output so
you can inspect it.

### Application of platform controls and limits

If you launch your plugin using `conform.sh`, the rules your code runs under are identical to the platform:

- your numeric UID/GID, with no passwd entry
- read-only root filesystem and read-only `/in`
- `/out`, `/scratch` and `/tmp` are writable but **will not execute anything** (noexec, nosuid)
- no network, no capabilities, no privilege escalation
- CPU, process count, open files and wall-clock time are your budgets, enforced
- `HOME=/tmp`

Simulating some runtime limits requires root access. Running your plugin with `conform.sh` does not require root access (sudo).  It is possible to simulate runtime limits exactly with the `--strict` option, which requires sudo:

| | Platform (production) | `conform.sh` | `conform.sh --strict` |
|---|---|---|---|
| `/out`, `/scratch` | disk-backed, hard size cap | RAM-backed, hard size cap | disk-backed, hard size cap |
| memory limit | your `memory_mb` | `memory_mb` + `output_mb` + `scratch_mb` | your `memory_mb` |
| undeclared files or unexpected types | run fails, plugin suspended | WARNING, output kept | FAIL |
| symlinks, special files, fake file types | run fails, plugin suspended | FAIL | FAIL |
| requirements | | `docker`, `jq` | `docker`, `jq`, `sudo`, Linux |

The default mode is intentionally more generous than the production platform.  `--strict` attempts to as closely as possible simulate all production runtime limitations, but requires sudo access.

### Your plugin definition

`plugin.json` at the root of this repository is an example copy of a plugin definition.  It is both read and used by `conform.sh`, but additionally, helps define your preferred budgets when onboarding on to SmartRainGrid.  The following fields are read:

- `budgets`: the limits applied to your plugin execution. They must not exceed the platform ceilings defined in
  `conformance/platform-ceilings.json`, or the harness refuses before running, exactly as
  onboarding would.
- `artifacts`: the output patterns you expect to write. Anything else in `/out` is logged as a WARNING as it represents undeclared output.  In production, this would result in your plugin being flagged as failed and would be automatically suspended.

Everything else in the file is set by us at onboarding. When you are happy with your copy,
send it to us: we review it, may amend it, and load it. The platform's copy is the version used during production runs.

### Worked example 1: a clean run

`forecast_example/` is a small staged ensemble forecast: warm-up state in `/scratch`, a
NetCDF ensemble and a CSV summary in `/out`, progress as it goes, `result.json` last.

```bash
docker build --platform linux/amd64 -t forecast-example forecast_example
./conformance/conform.sh forecast-example --definition plugin.json
```

The harness prints the limits it applies and how the platform enforces each one, runs the
image, checks the output, and tells you where it kept it:

```
== Definition: plugin.json ==
note: not read here, set by the platform at onboarding: _comment, description, display_name, image_ref, name, plugin_class
PASS  definition acceptable to the platform

== Limits (platform enforcement in brackets) ==
  cpus        2          same  [hard: CPU quota]
  memory_mb   4096       raised to 8256 here to cover RAM-backed /out and /scratch [hard: OOM kill]
  time_s      1800       same  [hard: killed, TIMEOUT]
  output_mb   64         hard, ENOSPC (tmpfs, RAM-backed)  [hard: ENOSPC]
  scratch_mb  4096       hard, ENOSPC (tmpfs, RAM-backed)  [hard: ENOSPC]
  tmp_mb      256        same  [hard: ENOSPC, counts against memory]
  pids        128        same  [hard]
  nofile      256        same  [hard]

== Running forecast-example as 3001:3001 ==
[  5%] Warm-up state, 10 members, working in /scratch
[ 20%] Running ensemble
[ 40%] Lead day 1 of 7
[ 47%] Lead day 2 of 7
[ 54%] Lead day 3 of 7
[ 61%] Lead day 4 of 7
[ 68%] Lead day 5 of 7
[ 75%] Lead day 6 of 7
[ 82%] Lead day 7 of 7
[ 92%] Writing NetCDF and CSV
[100%] Done

== Contract checks ==
PASS  finishes inside the time budget
PASS  exit code 0
PASS  result.json present
PASS  result.json parses, status=success
      summary: 10-member 7-day forecast issued 2026111100; final-day median 24.8 ML/d
PASS  only regular files in /out (no symlinks, pipes, devices)
PASS  .nc artefacts are real NetCDF
PASS  artefact extensions allowlisted (json csv txt png svg nc)
PASS  no undeclared artefacts
note  declared but not produced this run: diagnostics/*.png 
PASS  output within 64 MB budget  (17450 bytes)

== 10 passed, 0 failed, 0 warnings ==
Outputs kept: tmp/conform/runs/run-20261117-174006-8RxC/out
Scratch kept: tmp/conform/runs/run-20261117-174006-8RxC/scratch  (production deletes any /scratch content)
Clean. Run with --strict for the disk-backed pre-handover check.
```

The first run also pulls `busybox`, the small helper that holds the RAM-backed volumes
open and copies your output out of them.

Review the produced output:

```bash
ls -R tmp/conform/runs/run-*/out
ncdump -h tmp/conform/runs/run-*/out/forecast/streamflow_ensemble.nc
```

`/scratch` is kept too, so you can check your intermediates. On the production platform, this output would be deleted after
every run and never collected.

### Worked example 2: breaking the rules intentionally

Set `demo` in a copy of the sample parameters to see each failure condition:

```bash
cp -r conformance/sample-in /tmp/demo-in
jq '.demo = "exec_tmp"' conformance/sample-in/params.json > /tmp/demo-in/params.json
./conformance/conform.sh forecast-example --definition plugin.json --in /tmp/demo-in
```

| `demo` | What it does | What you see |
|---|---|---|
| `write_root` | writes into its own image directory | `OSError: [Errno 30] Read-only file system`, exit 1 |
| `exec_tmp` | copies a program to `/tmp` and runs it | `PermissionError: [Errno 13]`, exit 1 |
| `network` | fetches a web page | name resolution fails, exit 1 |
| `undeclared` | writes `diagnostics/debug.log` | WARNING: `.log` is not an allowed type; `--strict` FAILs |
| `oversized` | writes past `output_mb` | `OSError: [Errno 28] No space left on device`, exit 1 |

Real output, trimmed. `exec_tmp`:

```
== Running forecast-example as 3001:3001 ==
[  5%] Warm-up state, 10 members, working in /scratch
ERROR: PermissionError: [Errno 13] Permission denied: '/tmp/helper'
...
FAIL  exit code 0  (exit=1)
PASS  result.json parses, status=failure
      summary: PermissionError: [Errno 13] Permission denied: '/tmp/helper'
```

The plugin still wrote a `result.json` with `"status": "failure"` and its reason, because
`forecast.py` catches its own crash on the way out. Plugin authors should do the same: on the platform that
reason is what you and we see first.

`undeclared` runs to completion, and is kept, but tells you plainly what would go wrong:

```
WARN  artefact extensions allowlisted (json csv txt png svg nc)
      !!! The platform would record this run INVALID_OUTPUT: extension not allowed: diagnostics/debug.log
      !!! Kept here for you to inspect. Declare it or stop writing it before handover.
```

`oversized` hits the cap as a real `No space left on device`, mid-write, exactly as it
would on the platform. Its `result.json` is left empty, because `/out` was already full when the plugin tried
to report its failure: keep large intermediates in `/scratch`.

### Worked example 3: pre-handover check

```bash
./conformance/conform.sh forecast-example --definition plugin.json --strict
```

`--strict` asks for sudo once, to loop-mount ext4 volumes for `/out` and `/scratch` the
same way the platform does. On Debian/Ubuntu it needs `e2fsprogs` (for `mkfs.ext4`), which
is almost always installed already. It does not work with Docker Desktop (on any OS) or a remote Docker daemon, because
the volumes must be mounted on the same machine the Docker daemon runs on.

### Options

| Option | Default | |
|---|---|---|
| `--definition FILE` | `./plugin.json` | your plugin definition |
| `--in DIR` | `conformance/sample-in` | staged read-only at `/in` |
| `--workdir DIR` | `./tmp/conform/runs` | each run keeps its `out/` and `scratch/` here |
| `--uid N[:M]` | `3001` | try a couple of values: nothing should depend on the number |
| `--strict` | off | disk-backed volumes, exact memory, output violations FAIL |
| `--clean` | off | delete the run's outputs afterwards |

Files in your `--in` directory must be world-readable: the container runs as a UID that is
not you.

**If you are writing a source-code plugin** (the platform builds your image for you from
your repository), you can skip the image entirely for quick iteration: point your script at
local `in/` and `out/` directories and run it. Build the image and run the harness before
you push.

---

## Practical notes

**Build for the right architecture.** If you develop on an Apple Silicon Mac and
push without specifying a platform, your image will pull perfectly and then
fail with `exec format error`, which is a genuinely confusing message for what
is really a mismatch. Use `docker build --platform linux/amd64`.

**Pin library versions that you depend on.** Your image is rebuilt from time to time. An
unpinned dependency means a rebuild can change your results without anyone
touching your code.

**Write `result.json` last.** If your program fails halfway, the absence of this file is an
additional signal that the plugin did not execute correctly.

**These examples need almost nothing beyond the Python standard library** — see
`requirements.txt`, which also explains the one exception and why it is there.

**Minimal base images omit more than you expect.** `python:3-slim` and similar do not ship
the system timezone database, so code that converts to a local timezone works on your
development machine and then fails on the runner. Test in the image you will actually
ship, not only in your own environment.

**Other container templates** - these examples were written for Python 3.x.  If your
container technology requires a different base image, please discuss with the
SmartRainGrid development team.
