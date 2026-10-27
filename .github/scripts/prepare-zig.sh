#!/usr/bin/env bash
set -euo pipefail

bundle="$RUNNER_TEMP/ci-dependencies"
export ZIG_GLOBAL_CACHE_DIR="$RUNNER_TEMP/ci-zig-cache"
mkdir -p "$bundle" "$ZIG_GLOBAL_CACHE_DIR/p"

while IFS= read -r -d '' manifest; do
  echo "Fetching Zig dependencies: $manifest"
  (cd "$(dirname "$manifest")" && zig build --fetch=all)
done < <(git grep -l -z '\.url' -- '*build.zig.zon')

previous="$RUNNER_TEMP/ci-previous"
mkdir -p "$previous"
git archive HEAD^ | tar -xf - -C "$previous"
(cd "$previous/examples/vanilla" && zig build --fetch=all)
rm -rf "$previous"

tar --zstd -cf "$bundle/zig.tar.zst" -C "$ZIG_GLOBAL_CACHE_DIR" p
tar --zstd -cf "$bundle/toolchain.tar.zst" -C "$bundle" zig
rm -rf "$bundle/zig"
