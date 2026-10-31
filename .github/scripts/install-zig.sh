#!/usr/bin/env bash
set -euo pipefail

version=$(sed -n 's/.*\.minimum_zig_version = "\([^"]*\)".*/\1/p' build.zig.zon)
directory=${1:-$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/zig.XXXXXX")}
if [ -x "$directory/zig" ] && [ "$("$directory/zig" version)" = "$version" ]; then
  exit 0
fi
platform="$(uname -m)-linux"
release=$(curl --fail --silent --show-error --location https://ziglang.org/download/index.json |
  jq -ce --arg version "$version" --arg platform "$platform" '.[$version][$platform]')
url=$(jq -er '.tarball' <<< "$release")
checksum=$(jq -er '.shasum' <<< "$release")
mkdir -p "$directory"

curl --fail --silent --show-error --location "$url" -o "$directory/zig.tar.xz"
printf '%s  %s\n' "$checksum" "$directory/zig.tar.xz" | sha256sum --check --status
tar -xJf "$directory/zig.tar.xz" --strip-components=1 -C "$directory"
rm "$directory/zig.tar.xz"
test "$("$directory/zig" version)" = "$version"
