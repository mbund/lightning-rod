#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
export ZIG_LOCAL_CACHE_DIR="${ZIG_LOCAL_CACHE_DIR:-$repo_dir/.zig-cache}"

exec sudo --preserve-env unshare --net -- bash -euo pipefail -c '
  ip link set lo up
  exec setpriv --reuid="$1" --regid="$2" --init-groups \
    env "PATH=$3" "HOME=$4" "USER=$5" "LOGNAME=$5" "${@:6}"
' bash "$(id -u)" "$(id -g)" "$PATH" "$HOME" "$(id -un)" "$@"
