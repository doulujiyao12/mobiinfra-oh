#!/bin/sh
set -eu
resources="$(CDPATH= cd -- "$(/usr/bin/dirname -- "$0")/.." && pwd -P)"
exec "$resources/runtime/node" "$resources/host/macos-shared-launch.mjs" "$@"
