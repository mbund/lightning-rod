#!/usr/bin/env bash
# The standard check for a change to the simulation: the working tree against a git ref, the
# same way every time.
#
#   bench/tick/check.sh [--ref REF] [--out DIR] [--rounds N] [--cases a,b,...] [all|digests|oracle|matrix|wire]
#
#   digests  Sleeping entities' state matches every tick: with sleep and without, and against REF.
#   oracle   Tracking holds to the brute-force rule every tick (--check-tracking) in mixed scenes.
#   matrix   Per tick, by alternating rounds: CPU and wall time, and instructions, loads, L1 and
#            L2 misses when perf can count them. No kind may get slower than REF.
#   all      The three, in that order (the default).
#   wire     What every client receives matches REF byte for byte, tick for tick: for a change that
#            must not alter replication. Not part of all, as many changes alter it on purpose.
#
# REF defaults to HEAD, so a run measures what is not committed yet. It is built in its own
# worktree under DIR and kept there for the next run. A REF older than the bench's own flags
# (--warm, --digest, --check-tracking, --perf-control) cannot be measured.
#
# Benches run one at a time, pinned to BENCH_CPUS; builds run niced on BUILD_CPUS with JOBS
# jobs, so the machine stays usable. Every knob is an environment variable:
#   BENCH_CPUS (8-15)  BUILD_CPUS (0-7)  JOBS (2)  RELEASES (1.21.8)  PERF (perf)
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(git -C "$here" rev-parse --show-toplevel)
ref=HEAD
out=${TMPDIR:-/tmp}/lightning-rod-check
rounds=2
only=""
mode=all
while [ $# -gt 0 ]; do
    case $1 in
        --ref) ref=$2; shift 2 ;;
        --out) out=$2; shift 2 ;;
        --rounds) rounds=$2; shift 2 ;;
        --cases) only=$2; shift 2 ;;
        all | digests | oracle | matrix | wire) mode=$1; shift ;;
        -h | --help) sed -n '2,23p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
bench_cpus=${BENCH_CPUS:-8-15}
build_cpus=${BUILD_CPUS:-0-7}
jobs=${JOBS:-2}
releases=${RELEASES:-1.21.8}
perf=${PERF:-perf}
mkdir -p "$out"
report="$out/report.txt"
: > "$report"
say() { echo "$*" | tee -a "$report"; }

build() { # source tree, prefix
    (cd "$1/bench/tick" && nice -n 10 taskset -c "$build_cpus" zig build -Doptimize=ReleaseSafe -Dreleases="$releases" -j"$jobs" -p "$2")
}

commit=$(git -C "$root" rev-parse "$ref")
say "check: working tree against $ref ($commit)"
build "$root" "$out/new"
if [ ! -x "$out/ref-$commit/bin/tick-bench" ]; then
    rm -rf "$out/ref-source"
    git -C "$root" worktree prune
    git -C "$root" worktree add --detach "$out/ref-source" "$commit" > /dev/null
    build "$out/ref-source" "$out/ref-$commit"
    git -C "$root" worktree remove --force "$out/ref-source"
fi
new="$out/new/bin/tick-bench"
old="$out/ref-$commit/bin/tick-bench"
bench() { taskset -c "$bench_cpus" "$@"; }
failed=0

# Every kind at once, sleeping and woken, with digests every tick.
digest_scene=(--players=8 --mode=moving --cows=256 --orbs=256 --drops=256 --arrows=200 --volley-interval=40 --boats=64 --stream --digest --ticks=400)
# Each kind's state, by name. Packet counts follow the stream's timing, which varies run to run.
digests() {
    bench "$1" "${digest_scene[@]}" "${@:2}" 2>&1 | grep '^digest' |
        awk '{ line = ""; for (i = 2; i <= NF; i++) { split($i, kv, "="); if (kv[1] ~ /^(tick|mobs|orbs|projectiles|items|boats)$/) line = line " " $i } print substr(line, 2) }'
}

if [ "$mode" = all ] || [ "$mode" = digests ]; then
    digests "$new" > "$out/digest-new.txt"
    digests "$new" --no-sleep > "$out/digest-awake.txt"
    digests "$old" > "$out/digest-ref.txt"
    lines=$(wc -l < "$out/digest-new.txt")
    awake=$(diff "$out/digest-new.txt" "$out/digest-awake.txt" | grep -c '^<' || true)
    against=$(diff "$out/digest-new.txt" "$out/digest-ref.txt" | grep -c '^<' || true)
    say "digests: $lines lines, $awake differ from sleep off, $against differ from $ref"
    if [ "$lines" -eq 0 ] || [ "$awake" -ne 0 ] || [ "$against" -ne 0 ]; then failed=1; fi
fi

# What clients receive, hashed player by player. Without arrows: their volleys fill output, and
# what backpressure lets through depends on how fast it drains.
wire_scene=(--players=8 --mode=moving --cows=256 --orbs=256 --drops=256 --stream --digest --ticks=400 --samples=1)
wires() {
    bench "$1" "${wire_scene[@]}" 2>&1 | grep '^digest' | grep -o 'tick=[0-9]* .*wire=[0-9a-f]*' | awk '{print $1, $NF}'
}

if [ "$mode" = wire ]; then
    wires "$new" > "$out/wire-new.txt"
    wires "$old" > "$out/wire-ref.txt"
    lines=$(wc -l < "$out/wire-new.txt")
    if ! grep -q wire= "$out/wire-ref.txt"; then
        say "wire: $ref has no wire digest, cannot compare"
        failed=1
    else
        differ=$(diff "$out/wire-new.txt" "$out/wire-ref.txt" | grep -c '^<' || true)
        first=$(diff "$out/wire-new.txt" "$out/wire-ref.txt" | grep -m1 '^<' | awk '{print $2}' || true)
        say "wire: $lines ticks, $differ differ from $ref${first:+, first at $first}"
        if [ "$lines" -eq 0 ] || [ "$differ" -ne 0 ]; then failed=1; fi
    fi
fi

oracle_scenes=(
    "--players=32 --mode=moving --cows=256 --drops=1024 --orbs=512 --ticks=300"
    "--players=32 --mode=moving --arrows=5000 --volley-interval=100 --ticks=300"
    "--players=1 --mode=idle --flying=20000 --ticks=100"
    "--players=64 --mode=moving --cows=128 --ticks=300"
)
if [ "$mode" = all ] || [ "$mode" = oracle ]; then
    for scene in "${oracle_scenes[@]}"; do
        # shellcheck disable=SC2086
        if output=$(bench "$new" $scene --stream --warm=800 --check-tracking 2>&1); then status=0; else status=$?; fi
        problems=$(echo "$output" | grep -ciE 'mismatch|panic|error' || true)
        say "oracle: exit $status, $problems problems :: $scene"
        if [ "$status" -ne 0 ] || [ "$problems" -ne 0 ]; then failed=1; fi
    done
fi

cases=(
    "herd-idle|--players=1 --mode=idle --cows=1024 --ticks=1000"
    "herd-moving|--players=32 --mode=moving --cows=1024 --ticks=600"
    "items-idle|--players=32 --mode=idle --drops=4096 --ticks=600"
    "items-moving|--players=32 --mode=moving --drops=4096 --ticks=600"
    "orbs-moving|--players=32 --mode=moving --orbs=2048 --ticks=600"
    "arrows-volley|--players=32 --mode=idle --arrows=1000 --volley-interval=40 --ticks=600"
    "arrows-big|--players=32 --mode=moving --arrows=5000 --volley-interval=100 --ticks=600"
    "arrows-flying|--players=1 --mode=idle --flying=20000 --ticks=100"
    "arrows-32x20k|--players=32 --mode=moving --arrows=20000 --volley-interval=300 --ticks=300"
    "players-moving|--players=128 --mode=moving --ticks=600"
)
# Hybrid machines count on the cores the benches run on.
events=instructions,mem_uops_retired.all_loads,mem_load_uops_retired.l1_miss,mem_load_uops_retired.l2_miss
if "$perf" list 2> /dev/null | grep -q cpu_atom; then
    events=cpu_atom/instructions/,cpu_atom/mem_uops_retired.all_loads/,cpu_atom/mem_load_uops_retired.l1_miss/,cpu_atom/mem_load_uops_retired.l2_miss/
fi
counts() { # binary, ticks, args...
    command -v "$perf" > /dev/null || return 0
    local fifo="$out/perf.fifo"
    rm -f "$fifo"
    mkfifo "$fifo"
    # shellcheck disable=SC2068
    "$perf" stat -x, -D -1 --control "fifo:$fifo" -e "$events" -- taskset -c "$bench_cpus" "$1" ${@:3} --samples=1 --perf-control="$fifo" 2>&1 > /dev/null |
        awk -F, -v ticks="$2" '$3 != "" && $1 ~ /^[0-9]/ { name = $3; sub(/^cpu_atom\//, "", name); sub(/\/$/, "", name); sub(/^mem_(load_)?uops_retired\./, "", name); printf "%s=%.0f ", name, $1 / ticks }'
    rm -f "$fifo"
}
if [ "$mode" = all ] || [ "$mode" = matrix ]; then
    if ! command -v "$perf" > /dev/null; then say "matrix: no perf at \`$perf\` (set PERF): CPU and wall only, which other work on the machine skews"; fi
    for entry in "${cases[@]}"; do
        name=${entry%%|*}
        args="${entry#*|} --stream --warm=800"
        if [ -n "$only" ] && ! echo ",$only," | grep -q ",$name,"; then continue; fi
        ticks=$(echo "$args" | grep -o -- '--ticks=[0-9]*' | cut -d= -f2)
        for round in $(seq 1 "$rounds"); do
            for side in ref new; do
                binary=$old
                if [ $side = new ]; then binary=$new; fi
                # shellcheck disable=SC2086
                timing=$(bench "$binary" $args 2>&1 | grep -E '^(idle|moving) ' | tail -1 | awk '{printf "cpu_us=%s wall_us=%s", $4, $5}')
                # shellcheck disable=SC2086
                say "$name r$round $side $timing $(counts "$binary" "$ticks" $args)"
            done
        done
    done
    say "matrix: per tick; compare rounds of one side with the other, not across machines or power modes"
fi

if [ $failed -ne 0 ]; then
    say "check: FAILED"
    exit 1
fi
say "check: passed (matrix numbers are for judging, not pass or fail)"
