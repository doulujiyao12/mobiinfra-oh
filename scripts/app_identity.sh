#!/usr/bin/env bash

read_app_bundle_name() {
  local repo_root="$1"
  local app_config="$repo_root/AppScope/app.json5"
  local bundle_name

  [[ -f "$app_config" ]] || {
    echo "error: App config not found: $app_config" >&2
    return 1
  }
  bundle_name="$(sed -nE 's/^[[:space:]]*"bundleName"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$app_config")"
  [[ -n "$bundle_name" ]] || {
    echo "error: app.bundleName is missing in: $app_config" >&2
    return 1
  }
  printf '%s\n' "$bundle_name"
}
