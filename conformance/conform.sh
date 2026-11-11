#!/bin/bash
#
# OUTLANDS conformance harness - contributor self-test.
#
# Runs your plugin image locally under the exact restrictions the SmartRainGrid
# research runtime applies in production, then checks that your output honours
# the container contract. If this script passes on your machine, "works on my
# machine" means "works on our platform".
#
# Usage:
#   ./conform.sh IMAGE [options]
#
# Options:
#   --in DIR          directory staged read-only at /in (default: sample-in/
#                     next to this script)
#   --uid N[:M]       numeric uid[:gid] to run as (default 3001:3001). On the
#                     platform you run as a UID in 3000-3999, GID equal to UID,
#                     NO passwd entry and no other groups - so assume no
#                     username and no home directory. Try a few values.
#   --time S          wall-clock budget in seconds (default 600)
#   --mem MB          memory budget in MB (default 2048)
#   --out-cap MB      output budget in MB (default 100; the platform enforces
#                     this as a hard filesystem cap - writes past it fail with
#                     ENOSPC. This harness checks the total afterwards instead,
#                     so it needs no root)
#   --artefacts LIST  comma-separated expected output files/globs, e.g.
#                     'advice.csv,charts/*.png' - must match what you declare
#                     at onboarding
#   --scratch MB      also mount a writable /scratch of this size (only if
#                     your plugin is onboarded with a scratch budget)
#
# What the platform provides your container, and nothing else:
#   /in      read-only: your staged data, /in/fetched/ externals,
#            /in/params.json. Owned by your UID.
#   /out     writable, size-capped, starts empty: result.json + your
#            declared artefacts. Owned by your UID. Collected after the run.
#   /scratch optional, writable, size-capped, starts empty, private to your
#            UID. For intermediate files. Deleted after the run, never
#            collected.
#   /tmp     writable, small (256 MB by default), RAM-backed: what you
#            write there counts against your memory budget.
# /out, /scratch and /tmp are mounted noexec,nosuid. No network. No
# capabilities. Read-only root filesystem. HOME=/tmp.
#
# Differences from the platform, because this harness needs no root:
#   - /out and /scratch are world-writable host directories here, owned by
#     you, not by the container UID; the platform makes them owned by it
#   - the size caps are checked afterwards, not enforced as ENOSPC
#   - host directories here are not noexec
# A plugin that only reads /in and writes /out, /scratch and /tmp sees no
# difference.
#
# The flag set below mirrors run_container() in the platform's executor
# (outlands/runner/shenzi.sh); if you change one, change both.
#
# Reference: the container contract in the README at
# https://github.com/ninthtide/outlands-plugin-examples

set -euo pipefail

ALLOWED_EXTENSIONS="json csv txt png svg"

usage() { sed -n '2,/^set -euo/{/^#/p}' "$0" | sed 's/^# \{0,1\}//'; exit 64; }

IMAGE="${1:-}"
[[ -n $IMAGE && $IMAGE != -* ]] || usage
shift

IN_DIR="$(cd "$(dirname "$0")" && pwd)/sample-in"
RUN_UID=3001 RUN_GID=3001 TIME_S=600 MEM_MB=2048 OUT_CAP_MB=100 ARTEFACTS=""
SCRATCH_MB=0

while (( $# )); do
    case "$1" in
        --in)        IN_DIR=$2; shift 2 ;;
        --uid)       RUN_UID=${2%%:*}; RUN_GID=${2#*:}; [[ $2 == *:* ]] || RUN_GID=$RUN_UID; shift 2 ;;
        --time)      TIME_S=$2; shift 2 ;;
        --mem)       MEM_MB=$2; shift 2 ;;
        --out-cap)   OUT_CAP_MB=$2; shift 2 ;;
        --artefacts) ARTEFACTS=$2; shift 2 ;;
        --scratch)   SCRATCH_MB=$2; shift 2 ;;
        *) echo "unknown option: $1" >&2; usage ;;
    esac
done

[[ -d $IN_DIR ]] || { echo "input directory not found: $IN_DIR" >&2; exit 65; }

OUT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/conform-out.XXXXXX")
SCRATCH_DIR="" SCRATCH_MOUNT=()
if (( SCRATCH_MB > 0 )); then
    SCRATCH_DIR=$(mktemp -d "${TMPDIR:-/tmp}/conform-scratch.XXXXXX")
    chmod 777 "$SCRATCH_DIR"
    SCRATCH_MOUNT=(-v "$SCRATCH_DIR:/scratch")
fi
# Files the container UID creates may not be removable by you; report, don't die
trap 'rm -rf "$OUT_DIR" ${SCRATCH_DIR:+"$SCRATCH_DIR"} 2>/dev/null || echo "note: could not remove $OUT_DIR ${SCRATCH_DIR}" >&2' EXIT
chmod 777 "$OUT_DIR"   # the arbitrary UID must be able to write here

PASS=0 FAIL=0
report() {  # report NAME OK [DETAIL]
    local name=$1 ok=$2 detail=${3:-}
    if [[ $ok == yes ]]; then
        echo "PASS  $name${detail:+  ($detail)}"; (( ++PASS ))
    else
        echo "FAIL  $name${detail:+  ($detail)}"; (( ++FAIL ))
    fi
}

echo "== Running $IMAGE under platform restrictions =="
rc=0
timeout --kill-after=30 "$TIME_S" \
    docker run --rm --name "conform-$$" \
        --user "${RUN_UID}:${RUN_GID}" \
        --cap-drop ALL \
        --security-opt no-new-privileges \
        --memory "${MEM_MB}m" --memory-swap "${MEM_MB}m" \
        --cpus 2 \
        --pids-limit 128 \
        --ulimit nofile=256 \
        --read-only \
        --tmpfs /tmp:rw,noexec,nosuid,size=256m \
        --network none \
        --init \
        --env HOME=/tmp \
        --env PYTHONUNBUFFERED=1 \
        -v "$(cd "$IN_DIR" && pwd):/in:ro" \
        -v "$OUT_DIR:/out" \
        "${SCRATCH_MOUNT[@]}" \
        "$IMAGE" || rc=$?

echo
echo "== Contract checks =="
if (( rc == 124 )); then
    report "finishes inside the time budget" no "killed at ${TIME_S}s"
else
    report "finishes inside the time budget" yes
fi
report "exit code 0" "$( (( rc == 0 )) && echo yes || echo no )" "exit=$rc"

RESULT="$OUT_DIR/result.json"
if [[ -f $RESULT && ! -L $RESULT ]]; then
    report "result.json present" yes
    if command -v jq >/dev/null; then
        status=$(jq -er '.status' "$RESULT" 2>/dev/null || echo INVALID)
        case "$status" in
            success|failure) report "result.json parses, status=$status" yes ;;
            INVALID)         report "result.json is valid JSON with .status" no ;;
            *)               report "result.json status is success|failure" no "got: $status" ;;
        esac
        summary_len=$(jq -r '.summary // "" | length' "$RESULT" 2>/dev/null || echo 0)
        report "result.json has a summary" "$( (( summary_len > 0 )) && echo yes || echo no )" \
            "$(jq -r '.summary // "" | .[0:160]' "$RESULT" 2>/dev/null)"
    else
        report "result.json validated" no "jq not installed - install jq to validate"
    fi
else
    report "result.json present" no "the control-plane handshake is mandatory"
fi

# Symlinks in /out are rejected at collection (and never followed)
symlinks=$(find "$OUT_DIR" -type l | head -5)
report "no symlinks in /out" "$( [[ -z $symlinks ]] && echo yes || echo no )" "$symlinks"

# Every artefact must use an allowlisted extension; undeclared arrivals are an
# INVALID_OUTPUT on the platform and suspend the plugin
bad_ext=""
while IFS= read -r f; do
    ext="${f##*.}"
    [[ " $ALLOWED_EXTENSIONS " == *" ${ext,,} "* ]] || bad_ext+="${f#"$OUT_DIR"/} "
done < <(find "$OUT_DIR" -type f ! -path "$RESULT")
report "artefact extensions allowlisted ($ALLOWED_EXTENSIONS)" \
    "$( [[ -z $bad_ext ]] && echo yes || echo no )" "$bad_ext"

if [[ -n $ARTEFACTS ]]; then
    missing="" undeclared=""
    IFS=',' read -r -a patterns <<< "$ARTEFACTS"
    for p in "${patterns[@]}"; do
        compgen -G "$OUT_DIR/$p" >/dev/null || missing+="$p "
    done
    while IFS= read -r f; do
        rel="${f#"$OUT_DIR"/}"
        matched=no
        for p in "${patterns[@]}"; do
            # shellcheck disable=SC2053
            [[ $rel == $p ]] && matched=yes && break
        done
        [[ $matched == yes ]] || undeclared+="$rel "
    done < <(find "$OUT_DIR" -type f ! -path "$RESULT")
    report "declared artefacts all produced" "$( [[ -z $missing ]] && echo yes || echo no )" "$missing"
    report "no undeclared artefacts" "$( [[ -z $undeclared ]] && echo yes || echo no )" "$undeclared"
fi

total_bytes=$(du -sb "$OUT_DIR" | cut -f1)
cap_bytes=$(( OUT_CAP_MB * 1024 * 1024 ))
report "output within ${OUT_CAP_MB}MB budget" \
    "$( (( total_bytes <= cap_bytes )) && echo yes || echo no )" "${total_bytes} bytes"

if [[ -n $SCRATCH_DIR ]]; then
    scratch_bytes=$(du -sb "$SCRATCH_DIR" | cut -f1)
    report "scratch within ${SCRATCH_MB}MB budget" \
        "$( (( scratch_bytes <= SCRATCH_MB * 1024 * 1024 )) && echo yes || echo no )" \
        "${scratch_bytes} bytes (discarded, as on the platform)"
fi

echo
echo "== $PASS passed, $FAIL failed =="
(( FAIL == 0 )) || exit 1
echo "Your plugin conforms. On the platform it runs under these same flags,"
echo "with the size caps enforced by the filesystem and no network."
