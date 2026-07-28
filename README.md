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
| `/out` | writable | location for all plugin output |
| `/tmp` | writable | scratch space, small, discarded |

**There is no network.** Your container cannot reach the internet, the main
database, or anything else. You cannot fetch a file, call an API, or install a
package while running. Everything you need must already be in your source code
repository (e.g. libraries declared in requirements.txt), or already included in
your container image, and any data you need is staged automatically on your
behalf by the platform, into `/in`, before your plugin starts.

This is the single most important thing to design around, and is a hard requirement
to permit the execution of contributor code at all. If your analysis needs a dataset,
you declare that when your plugin is onboarded and the data feed is refreshed prior
to executing your job, every time.

You also run within a fixed budget: CPU, memory, wall-clock time, output size,
process count. These are agreed when your plugin is onboarded. Exceeding them
causes the job to stop and fail — the platform will tell you which limit was
exceeded.

---

## The four files

Everything your plugin communicates, it does so by writing a file.

**Note the plurals in filenames: they indicate whether a file accepts multiple entries.**

### `/in/params.json` — read

Your parameters. Always present, validated prior to your plugin running.

The platform validates params.json against the parameter list you declared before
your container starts, so a missing or malformed value should never reach your code.

```python
with open("/in/params.json") as f:
    params = json.load(f)
```

### `/out/result.json` — write, exactly one

**Required.** A job that completes (even successfully) without writing a `result.json`
is considered a failure.

Two fields matter to the platform:

```json
{
  "status": "success",
  "summary": "Summed 10 squares; total 385"
}
```

- `status` — `"success"` or `"failure"`. Your self-declared verdict on your own run.
- `summary` — a one line summary (max length: 500 chars)

Status is case-sensitive and must match exactly "success" or "failure".

If summary exceeds 500 chars, the text will be trimmed.  Any malicious or
unusual characters are removed.  Accented characters and diacritics are retained.

Everything else written into `result.json` is considered output that belongs to the
plugin, and is stored by the platform, subject to retention rules agreed when the
plugin was onboarded.  Results may be downloaded later from the Research Centre.

`result.json` must be under 64KB in total.  It is a summary of your run, not a
place to store the run's output — write bulk data to a declared artefact instead.

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

Permitted types are `json`, `csv`, `txt`, `png`, `svg`.

All output is retained by the platform subject to agreed retention rules (date-based or
last # of job runs), and may be downloaded from the Research Centre.

If your plugin requires authoring files of different extensions or types, or changes to
the retention rules, please discuss with the SmartRainGrid development team.

### Print freely to terminal/stdout

Anything your program prints to the terminal standard output (stdout) is captured into the
job log, for later download and review.

---

## The examples

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

## Testing locally

You may verify that your codebase will work once onboarded by simulating the same conditions
within your own development environment.

**If you are writing a source-code plugin** (the platform builds your image for you from your
repository), you do not need to build anything to test. Create the two directories, point your
script at them instead of `/in` and `/out`, and run it directly. That is the fastest feedback
loop available to you and it catches most mistakes — a missing `result.json`, an undeclared
output file, a parameter you assumed would be present.

**If you supply your own container image**, run it the way the platform will:

```bash
mkdir -p /tmp/t/in /tmp/t/out
echo '{"steps": 5, "delay_s": 0.2}' > /tmp/t/in/params.json

docker run --rm \
    --network none \
    -v /tmp/t/in:/in:ro \
    -v /tmp/t/out:/out \
    your-image:tag

ls -la /tmp/t/out
cat /tmp/t/out/result.json
```

`--network none` is important to retain in your local command even though it is
inconvenient. This reproduces the conditions your plugin will actually run under, and
will surface any hidden network dependencies in your codebase prior to onboarding to the
SmartRainGrid platform.

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
