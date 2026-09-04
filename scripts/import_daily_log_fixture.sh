#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/import_daily_log_fixture.sh [options]

Options:
  --source <dir>                  Source daily-log dir or fixture root.
  --bundle-name <name>            Debug bundle name. Default: AppScope/app.json5.
  --module-name <name>            Module name for default device path. Default: entry.
  --device-workflows-root <path>  Device workflows root.
  --hdc <path>                    hdc executable path. Defaults to $HDC or hdc in PATH.
  --include-runs                  Also send runs/ when the source fixture root contains it.
  -h, --help                      Show this help.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
source "$script_dir/app_identity.sh"

detect_hdc() {
  if [[ -n "${HDC:-}" ]]; then
    printf '%s\n' "$HDC"
  elif command -v hdc >/dev/null 2>&1; then
    command -v hdc
  elif [[ -n "${DEVECO_SDK_HOME:-}" && -x "$DEVECO_SDK_HOME/default/openharmony/toolchains/hdc" ]]; then
    printf '%s\n' "$DEVECO_SDK_HOME/default/openharmony/toolchains/hdc"
  else
    printf '%s\n' "hdc"
  fi
}

ensure_hdc() {
  if [[ "$hdc_path" == */* ]]; then
    [[ -x "$hdc_path" ]] || die "hdc not found or not executable: $hdc_path"
  else
    command -v "$hdc_path" >/dev/null 2>&1 || die "hdc not found in PATH: $hdc_path"
  fi
}

resolve_path_if_relative() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s\n' "$repo_root/$1" ;;
  esac
}

invoke_hdc_checked() {
  local failure_message="$1"
  shift
  local output status

  set +e
  output="$("$hdc_path" "$@" 2>&1)"
  status=$?
  set -e

  if [[ -n "$output" ]]; then
    echo "$output"
  fi
  if [[ "$status" -ne 0 ]] || printf '%s\n' "$output" | grep -E "\[Fail\]|Permission denied|No such file|not found" >/dev/null; then
    die "$failure_message"$'\n'"$output"
  fi
}

source_path=""
bundle_name="$(read_app_bundle_name "$repo_root")"
module_name="entry"
device_workflows_root=""
hdc_path="$(detect_hdc)"
include_runs=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)
      [[ $# -ge 2 ]] || die "--source requires a value"
      source_path="$2"
      shift 2
      ;;
    --bundle-name)
      [[ $# -ge 2 ]] || die "--bundle-name requires a value"
      bundle_name="$2"
      shift 2
      ;;
    --module-name)
      [[ $# -ge 2 ]] || die "--module-name requires a value"
      module_name="$2"
      shift 2
      ;;
    --device-workflows-root)
      [[ $# -ge 2 ]] || die "--device-workflows-root requires a value"
      device_workflows_root="$2"
      shift 2
      ;;
    --hdc)
      [[ $# -ge 2 ]] || die "--hdc requires a value"
      hdc_path="$2"
      shift 2
      ;;
    --include-runs)
      include_runs=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

ensure_hdc

if [[ -z "$source_path" ]]; then
  source_path="$repo_root/mock/workflows-source"
else
  source_path="$(resolve_path_if_relative "$source_path")"
fi

runs_source=""
if [[ -d "$source_path" ]]; then
  daily_log_child="$source_path/daily-log"
  runs_child="$source_path/runs"
  if [[ "$(basename "$source_path")" != "daily-log" && -d "$daily_log_child" ]]; then
    if [[ "$include_runs" -eq 1 && -d "$runs_child" ]]; then
      runs_source="$runs_child"
    fi
    source_path="$daily_log_child"
  fi
fi

[[ -d "$source_path" ]] || die "daily-log fixture source dir does not exist: $source_path"
resolved_source="$(cd "$source_path" && pwd)"

if [[ -z "$device_workflows_root" ]]; then
  device_workflows_root="/data/storage/el2/base/haps/$module_name/files/workflows"
fi

echo "Using device workflows root:"
echo "  $device_workflows_root"
echo "Using debug bundle argument:"
echo "  -b $bundle_name"
echo "If this path does not match your device, override --device-workflows-root, --bundle-name, or --module-name."

echo "Sending daily-log fixture:"
echo "  source: $resolved_source"
echo "  target: $device_workflows_root/daily-log"
invoke_hdc_checked "hdc file send failed" file send -b "$bundle_name" "$resolved_source" "$device_workflows_root"

if [[ "$include_runs" -eq 1 ]]; then
  if [[ -z "$runs_source" ]]; then
    echo "Requested --include-runs, but no runs source dir was found. Skipping runs import."
  else
    resolved_runs="$(cd "$runs_source" && pwd)"
    echo "Sending optional run summaries:"
    echo "  source: $resolved_runs"
    echo "  target: $device_workflows_root/runs"
    invoke_hdc_checked "hdc file send runs failed" file send -b "$bundle_name" "$resolved_runs" "$device_workflows_root"
  fi
fi

echo "Done. Open the app, enter data collection, then tap sync."
