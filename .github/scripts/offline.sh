#!/usr/bin/env bash
set -euo pipefail

exec sudo --preserve-env unshare --net -- bash -euo pipefail -c '
  ip link set lo up
  exec setpriv --reuid="$1" --regid="$2" --init-groups \
    env "PATH=$3" "HOME=$4" "USER=$5" "LOGNAME=$5" "${@:6}"
' bash "$(id -u)" "$(id -g)" "$PATH" "$HOME" "$(id -un)" "$@"
