#!/bin/sh
set -eu

version=$1
api=$2
output=$3
work=$(dirname "$output")
mkdir -p "$work"

set --
if [ -n "$api" ]; then
    set -- "-Pregistry_api=$api"
fi

if ./gradlew --no-daemon --project-cache-dir "$work/gradle-project-cache" registrySnapshot "-Pminecraft_version=$version" "$@" "-PsnapshotOutput=$output" "-PbuildRoot=$work/gradle-build" >"$work/gradle.log" 2>&1; then
    exit 0
fi

cat "$work/gradle.log" >&2
exit 1
