#!/usr/bin/env bash
set -euo pipefail

bundle="$RUNNER_TEMP/ci-dependencies"
export ZIG_GLOBAL_CACHE_DIR="$RUNNER_TEMP/ci-zig-cache"
export GRADLE_USER_HOME="$RUNNER_TEMP/ci-gradle"
export LIGHTNING_ROD_E2E_CLIENT_SOURCE="$PWD/e2e/client"
mkdir -p "$bundle"

while IFS= read -r -d '' manifest; do
  (cd "$(dirname "$manifest")" && zig build --fetch=all)
done < <(git ls-files -z '*build.zig.zon')

previous="$RUNNER_TEMP/ci-previous"
mkdir -p "$previous"
git archive HEAD^ | tar -xf - -C "$previous"
(cd "$previous/examples/vanilla" && zig build --fetch=all)
rm -rf "$previous"

while IFS=$'\t' read -r version api fabric; do
  project="$LIGHTNING_ROD_E2E_CLIENT_SOURCE/build/clients/$version"
  mkdir -p "$project"
  cp e2e/client/{build.gradle,settings.gradle,gradle.properties} "$project/"
  e2e/client/gradlew --no-daemon -p "$project" \
    "-Pminecraft_version=$version" "-Pclient_api=$api" "-Pfabric_api_version=$fabric" \
    prepareDependencies
done < <(jq -r '.[] | [.release, .api, .fabric] | @tsv' e2e/client/versions.json)

while IFS=$'\t' read -r version api; do
  registry_snapshotter/gradlew --no-daemon -p registry_snapshotter \
    "-Pminecraft_version=$version" "-Pregistry_api=$api" \
    "-PbuildRoot=$RUNNER_TEMP/ci-registry/$version" prepareDependencies
done < <(jq -r '.[] | [.release, .api] | @tsv' registry_snapshotter/versions.json)

server_sha1=823e2250d24b3ddac457a60c92a6a941943fcd6a
curl --fail --silent --show-error --location \
  "https://piston-data.mojang.com/v1/objects/$server_sha1/server.jar" \
  -o "$RUNNER_TEMP/benchmark-minecraft.jar"
printf '%s  %s\n' "$server_sha1" "$RUNNER_TEMP/benchmark-minecraft.jar" | sha1sum --check --status
(cd bench/chunks && zig build --release=safe world -- \
  --server "$RUNNER_TEMP/benchmark-minecraft.jar" --output "$RUNNER_TEMP/benchmark-world")

sudo apt-get update
sudo apt-get install --download-only --reinstall -y --no-install-recommends \
  xvfb libgl1-mesa-dri libglx-mesa0 libgl1 libxrandr2 libxinerama1 libxcursor1 libxi6 libasound2t64

tar --zstd -cf "$bundle/zig.tar.zst" -C "$ZIG_GLOBAL_CACHE_DIR" p
tar --zstd -cf "$bundle/jdk.tar.zst" -C "$JAVA_HOME" .
tar --zstd --exclude='*.lock' --exclude=gc.properties -cf "$bundle/gradle.tar.zst" \
  -C "$GRADLE_USER_HOME" caches wrapper
tar --zstd --exclude=lock --exclude=partial -cf "$bundle/native.tar.zst" -C /var/cache/apt/archives .
tar --zstd -cf "$bundle/world.tar.zst" -C "$RUNNER_TEMP/benchmark-world" \
  corpus.bin corpus.json anvil registry.json
