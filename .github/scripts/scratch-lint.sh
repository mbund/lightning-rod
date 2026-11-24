#!/usr/bin/env bash
# Scratch memory in engine code, as release builds pay for it: ReleaseSafe fills `undefined`
# memory on every call, and std.mem.sort fills a 512-entry buffer however few it sorts.
#
#   1. No std.mem.sort or std.sort.block, but under a comment that says why a stable sort with
#      its buffer is right there: `// lint: stable sort, <reason>` on the line before. A total
#      order sorts the same unstable (std.sort.pdq); a handful sorts stably without a buffer
#      (std.sort.insertion).
#   2. No new `undefined` stack array of 128 or more: scratch a plugin uses lives on the plugin,
#      and library code declares it in a wrapper that turns safety off for it alone (see
#      Service.fanout). Those there before are listed in scratch-lint.baseline; one a profile
#      finds hot is moved and leaves the list. A listed line that is gone must leave it too.
#
#   .github/scripts/scratch-lint.sh            check
#   .github/scripts/scratch-lint.sh --update   write the baseline as the code stands
set -euo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root"
baseline=.github/scripts/scratch-lint.baseline

# Engine code: not tests, benches, examples, end-to-end tests, tools, or build-time generators.
files() {
    git ls-files '*.zig' | grep -vE '(_test|_bench|test_fixture)\.zig$|(^|/)tests?\.zig$|^(bench|e2e|examples|tools|protocol_codegen)/|/tests?/'
}

arrays() {
    files | xargs grep -nE 'var [A-Za-z_0-9]+: \[[0-9_]+\][^=]*= undefined;' |
        awk -F: '{ line = $0; sub(/^[^:]*:[^:]*:/, "", line); gsub(/^[ \t]+/, "", line); size = line; sub(/^var [A-Za-z_0-9]+: \[/, "", size); sub(/\].*/, "", size); gsub(/_/, "", size); if (size + 0 >= 128) print $1 "\t" line }' |
        sort -u
}

if [ "${1:-}" = --update ]; then
    arrays > "$baseline"
    echo "scratch-lint: baseline has $(wc -l < "$baseline") arrays"
    exit 0
fi

failed=0
while IFS=: read -r file number _; do
    previous=$(sed -n "$((number - 1))p" "$file")
    if ! echo "$previous" | grep -q '// lint: stable sort, '; then
        echo "$file:$number: std.mem.sort fills a 512-entry buffer every call; use std.sort.pdq with a total order or std.sort.insertion, or say why with \`// lint: stable sort, <reason>\` above"
        failed=1
    fi
done < <(files | xargs grep -nE 'std\.(mem\.sort|sort\.block)\(' || true)

current=$(mktemp)
trap 'rm -f "$current"' EXIT
arrays > "$current"
while IFS=$'\t' read -r file line; do
    echo "$file: new undefined stack array of 128 or more, filled every call in release: \`$line\`; keep scratch on its owner or in a safety-off wrapper"
    failed=1
done < <(comm -23 "$current" <(sort -u "$baseline"))
while IFS=$'\t' read -r file line; do
    echo "$file: listed in $baseline but gone: \`$line\`; run with --update"
    failed=1
done < <(comm -13 "$current" <(sort -u "$baseline"))

if [ $failed -ne 0 ]; then exit 1; fi
echo "scratch-lint: passed"
