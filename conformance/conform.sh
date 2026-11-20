#!/bin/bash
#
# OUTLANDS conformance harness - contributor dev loop and self-test.
#
# Runs your plugin image locally under the same execution rules the
# SmartRainGrid research runtime applies in production, reads your limits
# from your plugin definition, and keeps the outputs so you can inspect them.
#
# Usage:
#   ./conform.sh IMAGE [options]
#
# IMAGE must already be in your local Docker image store: build it first
# (docker build -t IMAGE .). The harness never pulls it from a registry, so
# what runs is always your latest build, not a published copy.
#
# Options:
#   --definition FILE  your plugin definition (default: plugin.json in the
#                      current directory). Only "budgets" and "artifacts" are
#                      read; the rest is ours to set at onboarding.
#   --in DIR           directory staged read-only at /in (default: sample-in/
#                      next to this script)
#   --workdir DIR      where each run's out/ and scratch/ are kept
#                      (default: ./tmp/conform/runs)
#   --uid N[:M]        numeric uid[:gid] to run as (default 3001:3001). On the
#                      platform: a UID in 3000-3999, GID equal to UID, no
#                      passwd entry, no other groups.
#   --strict           the pre-handover check. Needs sudo and Linux. /out and
#                      /scratch become disk-backed ext4 volumes, built exactly
#                      as the platform builds them, and any output the
#                      platform would reject is a FAIL rather than a warning.
#   --clean            delete this run's kept outputs afterwards
#   --diagnose         also print your Docker setup, the image's own /out and
#                      how /out is mounted. Paste the whole output to us.
#
# Two modes, one set of execution rules:
#
#   default   no sudo. /out and /scratch are RAM-backed (tmpfs) Docker
#             volumes: noexec, nosuid, nodev, owned by your UID, hard
#             size-capped (ENOSPC), exactly like the platform. Because they
#             live in RAM, the container's memory limit here is raised by
#             their size, so your code gets at least the memory it gets on
#             the platform. Output the platform would reject is a loud
#             WARNING, and kept for you to look at.
#   --strict  sudo. Disk-backed ext4 loop volumes, memory limit exactly your
#             budget, output violations FAIL. If this passes, the platform
#             sees no difference.
#
# Identical in both modes, and identical to the platform: your UID/GID,
# read-only root filesystem, read-only /in, noexec+nosuid on every writable
# mount, no network, no capabilities, no-new-privileges, CPU, process and
# open-file limits, the wall-clock budget, HOME=/tmp.
#
# Requires docker and jq. The default mode also pulls a small helper image
# (busybox) once, which holds the output volumes open and copies them out.
#
# The docker run flags below mirror run_container() in the platform's
# executor (outlands/runner/shenzi.sh); if you change one, change both.
#
# Reference: the container contract in the README at
# https://github.com/ninthtide/outlands-plugin-examples

set -euo pipefail

ALLOWED_EXTENSIONS="json csv txt png svg nc"
CONTRACT_FILES="result.json progress.json errors.json"
BUDGET_KEYS="cpus memory_mb time_s output_mb pids nofile tmp_mb"
HELPER_IMAGE=busybox:1.37.0

usage() { sed -n '2,/^set -euo/{/^#/p}' "$0" | sed 's/^# \{0,1\}//'; exit 64; }

IMAGE="${1:-}"
[[ -n $IMAGE && $IMAGE != -* ]] || usage
shift

HERE="$(cd "$(dirname "$0")" && pwd)"
DEFINITION=plugin.json IN_DIR="$HERE/sample-in" WORKDIR=./tmp/conform/runs
CEILINGS="$HERE/platform-ceilings.json"
RUN_UID=3001 RUN_GID=3001 STRICT=0 CLEAN=0 DIAGNOSE=0

while (( $# )); do
    case "$1" in
        --definition) DEFINITION=$2; shift 2 ;;
        --in)         IN_DIR=$2; shift 2 ;;
        --workdir)    WORKDIR=$2; shift 2 ;;
        --uid)        RUN_UID=${2%%:*}; RUN_GID=${2#*:}; [[ $2 == *:* ]] || RUN_GID=$RUN_UID; shift 2 ;;
        --strict)     STRICT=1; shift ;;
        --clean)      CLEAN=1; shift ;;
        --diagnose)   DIAGNOSE=1; shift ;;
        *) echo "unknown option: $1" >&2; usage ;;
    esac
done

die() { echo "conform: $*" >&2; exit 65; }

command -v docker >/dev/null || die "docker not found"
command -v jq >/dev/null     || die "jq not found - install jq"
docker image inspect "$IMAGE" >/dev/null 2>&1 \
    || die "image not found locally: $IMAGE - build it first (docker build -t $IMAGE .); conform.sh never pulls"
[[ -d $IN_DIR ]]     || die "input directory not found: $IN_DIR"
[[ -f $DEFINITION ]] || die "plugin definition not found: $DEFINITION (see plugin.json in the examples repo)"
[[ -f $CEILINGS ]]   || die "platform-ceilings.json not found next to this script"
jq -e 'type == "object"' "$DEFINITION" >/dev/null 2>&1 || die "$DEFINITION is not a JSON object"

PASS=0 FAIL=0 WARN=0
report() {  # report NAME yes|no [DETAIL]
    local name=$1 ok=$2 detail=${3:-}
    if [[ $ok == yes ]]; then
        echo "PASS  $name${detail:+  ($detail)}"; (( ++PASS ))
    else
        echo "FAIL  $name${detail:+  ($detail)}"; (( ++FAIL ))
    fi
}
# Output the platform would reject: FAIL under --strict, a loud WARNING otherwise
judge_output() {  # judge_output NAME yes|no [DETAIL]
    local name=$1 ok=$2 detail=${3:-}
    if [[ $ok == yes ]] || (( STRICT )); then
        report "$@"; return
    fi
    (( ++WARN ))
    echo "WARN  $name"
    echo "      !!! The platform would record this run INVALID_OUTPUT: $detail"
    echo "      !!! Kept here for you to inspect. Declare it or stop writing it before handover."
}

# --- the definition ---------------------------------------------------------

echo "== Definition: $DEFINITION =="
ignored=$(jq -r 'keys - ["budgets","artifacts"] | join(", ")' "$DEFINITION")
[[ -n $ignored ]] && echo "note: not read here, set by the platform at onboarding: $ignored"

budget() { jq -r --arg k "$1" '.budgets[$k] // empty' "$DEFINITION"; }
ceiling() { jq -r --arg k "$1" '.[$k]' "$CEILINGS"; }

refused=""
for key in $BUDGET_KEYS scratch_mb; do
    val=$(budget "$key")
    if [[ -z $val ]]; then
        [[ $key == scratch_mb ]] || refused+="budgets.$key missing; "
        continue
    fi
    if [[ $key == cpus ]]; then
        [[ $val =~ ^[0-9]+(\.[0-9]+)?$ ]] || { refused+="budgets.cpus not a number; "; continue; }
        awk -v v="$val" -v c="$(ceiling cpus)" 'BEGIN { exit !(v > 0 && v <= c) }' \
            || refused+="budgets.cpus=$val outside 0-$(ceiling cpus); "
    else
        [[ $val =~ ^[0-9]+$ ]] || { refused+="budgets.$key not a whole number; "; continue; }
        (( val > 0 && val <= $(ceiling "$key") )) \
            || refused+="budgets.$key=$val outside 1-$(ceiling "$key"); "
    fi
done
mapfile -t ARTIFACTS < <(jq -r '.artifacts // [] | .[]' "$DEFINITION")
for p in "${ARTIFACTS[@]}"; do
    ext="${p##*.}"
    [[ " $ALLOWED_EXTENSIONS " == *" ${ext,,} "* ]] || refused+="artifact '$p' must end in one of: $ALLOWED_EXTENSIONS; "
done
report "definition acceptable to the platform" "$( [[ -z $refused ]] && echo yes || echo no )" "$refused"
[[ -z $refused ]] || { echo; echo "Fix the definition first; the platform would refuse it at onboarding."; exit 1; }

CPUS=$(budget cpus) MEM_MB=$(budget memory_mb) TIME_S=$(budget time_s)
OUT_MB=$(budget output_mb) PIDS=$(budget pids) NOFILE=$(budget nofile)
TMP_MB=$(budget tmp_mb) SCRATCH_MB=$(budget scratch_mb); SCRATCH_MB=${SCRATCH_MB:-0}

if (( STRICT )); then
    RUN_MEM_MB=$MEM_MB disk="hard, ENOSPC (ext4, as on the platform)"
else
    RUN_MEM_MB=$(( MEM_MB + OUT_MB + SCRATCH_MB )) disk="hard, ENOSPC (tmpfs, RAM-backed)"
fi

echo
echo "== Limits (platform enforcement in brackets) =="
printf '  %-11s %-10s %s\n' \
    cpus      "$CPUS"           "same  [hard: CPU quota]" \
    memory_mb "$MEM_MB"         "$( (( STRICT )) && echo same || echo "raised to $RUN_MEM_MB here to cover RAM-backed /out and /scratch") [hard: OOM kill]" \
    time_s    "$TIME_S"         "same  [hard: killed, TIMEOUT]" \
    output_mb "$OUT_MB"         "$disk  [hard: ENOSPC]" \
    scratch_mb "$SCRATCH_MB"    "$( (( SCRATCH_MB )) && echo "$disk" || echo "no /scratch")  [hard: ENOSPC]" \
    tmp_mb    "$TMP_MB"         "same  [hard: ENOSPC, counts against memory]" \
    pids      "$PIDS"           "same  [hard]" \
    nofile    "$NOFILE"         "same  [hard]"

# --- volumes ----------------------------------------------------------------

mkdir -p "$WORKDIR"
RUN_DIR=$(mktemp -d "$WORKDIR/run-$(date +%Y%m%d-%H%M%S)-XXXX")
mkdir -p "$RUN_DIR/out"
(( SCRATCH_MB )) && mkdir -p "$RUN_DIR/scratch"
RUN_DIR=$(cd "$RUN_DIR" && pwd)
NAME="conform-$$"
MOUNTS=()

cleanup() {
    if (( STRICT )); then
        for v in out scratch; do
            mountpoint -q "$RUN_DIR/.mnt-$v" 2>/dev/null && sudo umount "$RUN_DIR/.mnt-$v"
            rm -rf "$RUN_DIR/.mnt-$v" "$RUN_DIR/$v.img"
        done
    else
        docker rm -f "$NAME-hold" >/dev/null 2>&1 || true
        docker volume rm "$NAME-out" "$NAME-scratch" >/dev/null 2>&1 || true
    fi
    (( CLEAN )) && rm -rf "$RUN_DIR"
    return 0
}
trap cleanup EXIT

if (( STRICT )); then
    [[ $(uname -s) == Linux ]] || die "--strict needs Linux (loop mounts on the docker host)"
    echo
    echo "== --strict: sudo is needed to loop-mount the output volumes =="
    sudo -v || die "sudo refused"
    # make_volume in the platform's shenzi-volume.sh, step for step
    strict_volume() {  # strict_volume NAME MB MODE
        local img="$RUN_DIR/$1.img" mnt="$RUN_DIR/.mnt-$1"
        truncate -s "${2}M" "$img"
        sudo mkfs.ext4 -q -m 0 -O ^has_journal "$img"
        mkdir -p "$mnt"
        sudo mount -o loop,noexec,nosuid,nodev "$img" "$mnt"
        sudo rm -rf "$mnt/lost+found"
        sudo chown "$RUN_UID:$RUN_GID" "$mnt"
        sudo chmod "$3" "$mnt"
        MOUNTS+=(-v "$mnt:/$1")
    }
    strict_volume out "$OUT_MB" 2750
    (( SCRATCH_MB )) && strict_volume scratch "$SCRATCH_MB" 0700
else
    tmpfs_volume() {  # tmpfs_volume NAME MB MODE
        docker volume create --driver local --opt type=tmpfs --opt device=tmpfs \
            --opt "o=size=${2}m,uid=$RUN_UID,gid=$RUN_GID,mode=$3,noexec,nosuid,nodev" \
            "$NAME-$1" >/dev/null
        # nocopy: once the holder has it mounted, an image's own /out or
        # /scratch would copy its owner and mode onto the volume (root 0755).
        # The platform bind-mounts, which never copies.
        MOUNTS+=(-v "$NAME-$1:/$1:nocopy")
    }
    tmpfs_volume out "$OUT_MB" 2750
    (( SCRATCH_MB )) && tmpfs_volume scratch "$SCRATCH_MB" 0700
    # A tmpfs volume is unmounted, and its contents lost, when the last
    # container using it stops. The holder keeps it mounted until we copy out.
    docker run -d --name "$NAME-hold" --user "${RUN_UID}:${RUN_GID}" \
        --cap-drop ALL --security-opt no-new-privileges --read-only \
        --network none "${MOUNTS[@]}" "$HELPER_IMAGE" sleep 86400 >/dev/null \
        || die "could not start the helper container ($HELPER_IMAGE)"
fi

# /out's root as the container sees it: uid:gid and mode
out_owner() {
    if (( STRICT )); then
        sudo stat -c '%u:%g %a' "$RUN_DIR/.mnt-out"
    else
        docker exec "$NAME-hold" stat -c '%u:%g %a' /out
    fi 2>/dev/null || echo unknown
}
OUT_EXPECTED="$RUN_UID:$RUN_GID 2750"

if (( DIAGNOSE )); then
    echo
    echo "== Diagnostics =="
    echo "conform.sh   sha256 $(sha256sum "$0" | cut -c1-12)$( (( STRICT )) && echo ', --strict')"
    echo "host         $(uname -srm)"
    docker version --format '{{json .}}' 2>/dev/null | jq -r '"engine       \(.Server.Platform.Name // "" | if . == "" then "Docker" else . end) \(.Server.Version) (\(.Server.Os)/\(.Server.Arch)), client \(.Client.Version)"' || echo "engine       unknown"
    docker info --format 'daemon       {{.OperatingSystem}}; storage {{.Driver}}; cgroup {{.CgroupDriver}} v{{.CgroupVersion}}; security {{join .SecurityOptions ","}}' 2>&1 || true
    echo "context      $(docker context show 2>&1 || true)"
    # jq, not --format: the containerd image store omits unset .Config keys
    docker image inspect "$IMAGE" | jq -r '.[0] | .Config as $c | "image        \(.Id); user=\($c.User // ""); workdir=\($c.WorkingDir // ""); entrypoint=\($c.Entrypoint | tojson); cmd=\($c.Cmd | tojson); volumes=\($c.Volumes | tojson)"' || true
    img_out=""
    if cid=$(docker create --pull never "$IMAGE" 2>/dev/null); then
        img_out=$(docker cp "$cid:/out" - 2>/dev/null | tar -tvf - 2>/dev/null | head -5 | paste -sd ';' || true)
        docker rm "$cid" >/dev/null 2>&1 || true
    fi
    echo "image /out   ${img_out:-none in the image}"
    if (( STRICT )); then
        echo "/out mount   $(findmnt -no SOURCE,FSTYPE,OPTIONS "$RUN_DIR/.mnt-out" 2>&1 || true)"
    else
        echo "/out mount   $(docker exec "$NAME-hold" grep ' /out ' /proc/mounts 2>&1 || true)"
    fi
    echo "/out before  $(out_owner)  (expected $OUT_EXPECTED)"
fi

# --- run --------------------------------------------------------------------

echo
echo "== Running $IMAGE as ${RUN_UID}:${RUN_GID} =="
rc=0
timeout --kill-after=30 "$TIME_S" \
    docker run --rm --pull never --name "$NAME" \
        --user "${RUN_UID}:${RUN_GID}" \
        --cap-drop ALL \
        --security-opt no-new-privileges \
        --memory "${RUN_MEM_MB}m" --memory-swap "${RUN_MEM_MB}m" \
        --cpus "$CPUS" \
        --pids-limit "$PIDS" \
        --ulimit "nofile=$NOFILE" \
        --read-only \
        --tmpfs "/tmp:rw,noexec,nosuid,size=${TMP_MB}m" \
        --network none \
        --init \
        --env HOME=/tmp \
        --env PYTHONUNBUFFERED=1 \
        -v "$(cd "$IN_DIR" && pwd):/in:ro" \
        "${MOUNTS[@]}" \
        "$IMAGE" || rc=$?
if (( rc == 124 || rc == 137 )); then
    docker kill "$NAME" >/dev/null 2>&1 || true
fi

# --- collect ----------------------------------------------------------------

collect() {  # collect NAME - a file your UID cannot read is skipped, not fatal
    if (( STRICT )); then
        sudo tar -C "$RUN_DIR/.mnt-$1" -cf - . | tar -C "$RUN_DIR/$1" -xf -
    else
        docker exec "$NAME-hold" tar -C "/$1" -cf - . | tar -C "$RUN_DIR/$1" -xf -
    fi || echo "note: some of /$1 could not be copied out (unreadable by ${RUN_UID}?)" >&2
}
collect out
(( SCRATCH_MB )) && collect scratch
OUT_DIR="$RUN_DIR/out"

# --- checks -----------------------------------------------------------------

echo
echo "== Contract checks =="
if (( rc == 124 )); then
    report "finishes inside the time budget" no "killed at ${TIME_S}s"
else
    report "finishes inside the time budget" yes
fi
case $rc in
    0)   report "exit code 0" yes ;;
    137) report "exit code 0" no "exit=137: killed, usually out of memory (budget ${MEM_MB} MB)" ;;
    126) report "exit code 0" no "exit=126: could not execute - writable mounts are noexec" ;;
    127) report "exit code 0" no "exit=127: command not found - check ENTRYPOINT/CMD exist in the image" ;;
    *)   report "exit code 0" no "exit=$rc" ;;
esac

# The harness's own check: a FAIL here is ours or your Docker's, not your plugin's
got=$(out_owner)
report "/out still ${RUN_UID}:${RUN_GID} mode 2750 after the run" \
    "$( [[ $got == "$OUT_EXPECTED" ]] && echo yes || echo no )" "got $got, expected $OUT_EXPECTED"

RESULT="$OUT_DIR/result.json"
if [[ -f $RESULT && ! -L $RESULT ]]; then
    report "result.json present" yes
    status=$(jq -er '.status' "$RESULT" 2>/dev/null || echo INVALID)
    case "$status" in
        success|failure) report "result.json parses, status=$status" yes ;;
        INVALID)         report "result.json is valid JSON with .status" no ;;
        *)               report "result.json status is success|failure" no "got: $status" ;;
    esac
    # Optional on the platform, but it is the first thing anyone reads
    summary=$(jq -r '.summary // "" | .[0:160]' "$RESULT" 2>/dev/null || true)
    if [[ -n $summary ]]; then
        echo "      summary: $summary"
    else
        echo "note  result.json has no summary: allowed, but it is what people see first"
    fi
else
    report "result.json present" no "the control-plane handshake is mandatory"
fi

# Never tolerated, in either mode: these are refused on the platform outright
odd=$(find "$OUT_DIR" ! -type f ! -type d | head -5 | sed "s|$OUT_DIR/||")
report "only regular files in /out (no symlinks, pipes, devices)" \
    "$( [[ -z $odd ]] && echo yes || echo no )" "$odd"

is_contract() { [[ " $CONTRACT_FILES " == *" $1 "* ]]; }
has_signature() {  # binary formats must open with their signature
    local head
    head=$(head -c 8 "$1" | od -An -tx1 | tr -d ' \n')
    case "$head" in
        43444601*|43444602*|43444605*|894844460d0a1a0a) return 0 ;;
    esac
    return 1
}

bad_ext="" bad_sig="" undeclared=""
while IFS= read -r f; do
    rel="${f#"$OUT_DIR"/}"
    is_contract "$rel" && continue
    ext="${rel##*.}"; ext=${ext,,}
    if [[ " $ALLOWED_EXTENSIONS " != *" $ext "* ]]; then bad_ext+="$rel "; continue; fi
    if [[ $ext == nc ]] && ! has_signature "$f"; then bad_sig+="$rel "; continue; fi
    matched=no
    for p in "${ARTIFACTS[@]}"; do
        # shellcheck disable=SC2053
        [[ $rel == $p ]] && matched=yes && break
    done
    [[ $matched == yes ]] || undeclared+="$rel "
done < <(find "$OUT_DIR" -type f | sort)

# A file posing as a format it is not is suspicious, not cruft
report ".nc artefacts are real NetCDF" "$( [[ -z $bad_sig ]] && echo yes || echo no )" "$bad_sig"
judge_output "artefact extensions allowlisted ($ALLOWED_EXTENSIONS)" \
    "$( [[ -z $bad_ext ]] && echo yes || echo no )" "${bad_ext:+extension not allowed: $bad_ext}"
judge_output "no undeclared artefacts" \
    "$( [[ -z $undeclared ]] && echo yes || echo no )" "${undeclared:+not in your artifacts list: $undeclared}"

missing=""
for p in "${ARTIFACTS[@]}"; do
    compgen -G "$OUT_DIR/$p" >/dev/null || missing+="$p "
done
# Not a platform rule: a run may legitimately skip a declared output
[[ -z $missing ]] || echo "note  declared but not produced this run: $missing"

# Summed file sizes, as the platform's collection measures them
total_bytes=$(find "$OUT_DIR" -type f -printf '%s\n' | awk '{ s += $1 } END { print s + 0 }')
report "output within ${OUT_MB} MB budget" \
    "$( (( total_bytes <= OUT_MB * 1024 * 1024 )) && echo yes || echo no )" "${total_bytes} bytes"

echo
echo "== $PASS passed, $FAIL failed, $WARN warnings =="
if (( CLEAN )); then
    echo "Outputs deleted (--clean)."
else
    echo "Outputs kept: $OUT_DIR"
    (( SCRATCH_MB )) && echo "Scratch kept: $RUN_DIR/scratch  (production deletes any /scratch content)"
fi
(( FAIL == 0 )) || exit 1
if (( WARN )); then
    echo "Runs under the platform's execution rules, but the warnings above"
    echo "would fail it there. Run with --strict before handing over."
elif (( STRICT )); then
    echo "Your plugin conforms. The platform runs it under these same rules."
else
    echo "Clean. Run with --strict for the disk-backed pre-handover check."
fi
