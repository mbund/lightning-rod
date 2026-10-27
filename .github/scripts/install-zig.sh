#!/usr/bin/env bash
set -euo pipefail

version=$(sed -n 's/.*\.minimum_zig_version = "\([^"]*\)".*/\1/p' build.zig.zon)
release=$(curl --fail --silent --show-error --location https://ziglang.org/download/index.json |
  jq -ce --arg version "$version" '.[$version]["x86_64-linux"]')
url=$(jq -er '.tarball' <<< "$release")
checksum=$(jq -er '.shasum' <<< "$release")
directory=${1:-$(mktemp -d "$RUNNER_TEMP/zig.XXXXXX")}
mkdir -p "$directory"

curl --fail --silent --show-error --location "$url" -o "$directory/zig.tar.xz"
printf '%s  %s\n' "$checksum" "$directory/zig.tar.xz" | sha256sum --check --status
tar -xJf "$directory/zig.tar.xz" --strip-components=1 -C "$directory"
rm "$directory/zig.tar.xz"
test "$("$directory/zig" version)" = "$version"
echo "$directory" >> "$GITHUB_PATH"
