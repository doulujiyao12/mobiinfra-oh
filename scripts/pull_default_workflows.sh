#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/pull_default_workflows.sh [options]

Options:
  --hdc <path>                hdc executable path. Defaults to $HDC or hdc in PATH.
  --remote-config-dir <dir>   Device workflow configs dir to pull from.
  --output-dir <dir>          Local output dir. Defaults to repo rawfile workflow configs.
  -h, --help                  Show this help.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
source "$script_dir/app_identity.sh"
app_bundle_name="$(read_app_bundle_name "$repo_root")"

default_remote_config_dirs=(
  "/data/app/el2/100/base/$app_bundle_name/haps/entry/files/workflows/configs"
  "/data/storage/el2/base/haps/entry/files/workflows/configs"
)

default_workflow_files=(
  "default_alipay_bill.json"
  "default_ele_order.json"
  "default_bilibili_history.json"
  "default_tencent_video_history.json"
  "default_weixin_chat.json"
  "default_weixin_today_chat.json"
  "default_dianping_order.json"
  "default_meituan_order.json"
  "default_weibo_hot_search.json"
  "default_xiaohongshu_history.json"
  "default_ctrip_order.json"
)

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

resolve_repo_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s\n' "$repo_root/$1" ;;
  esac
}

ensure_command() {
  local command_path="$1"
  local label="$2"
  if [[ "$command_path" == */* ]]; then
    [[ -x "$command_path" ]] || die "$label not found or not executable: $command_path"
  else
    command -v "$command_path" >/dev/null 2>&1 || die "$label not found in PATH: $command_path"
  fi
}

normalize_json_file() {
  local path="$1"
  python3 - "$path" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
with open(path, "w", encoding="utf-8", newline="\n") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
}

receive_json_file() {
  local remote_path="$1"
  local local_path="$2"
  local temp_path="${local_path}.tmp-$(date +%s)-$$-$RANDOM"
  local output status

  rm -f "$temp_path"
  set +e
  output="$("$hdc_path" file recv "$remote_path" "$temp_path" 2>&1)"
  status=$?
  set -e

  if [[ ! -f "$temp_path" ]]; then
    if [[ -n "$output" ]]; then
      echo "$output" >&2
    fi
    return 1
  fi

  if ! normalize_json_file "$temp_path"; then
    rm -f "$temp_path"
    return 1
  fi
  mv "$temp_path" "$local_path"
  return 0
}

hdc_path="$(detect_hdc)"
remote_config_dir=""
output_dir=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hdc)
      [[ $# -ge 2 ]] || die "--hdc requires a value"
      hdc_path="$2"
      shift 2
      ;;
    --remote-config-dir)
      [[ $# -ge 2 ]] || die "--remote-config-dir requires a value"
      remote_config_dir="$2"
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || die "--output-dir requires a value"
      output_dir="$2"
      shift 2
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

ensure_command "$hdc_path" "hdc"
ensure_command "python3" "python3"

if [[ -z "$output_dir" ]]; then
  output_path="$repo_root/entry/src/main/resources/rawfile/workflows/configs"
else
  output_path="$(resolve_repo_path "$output_dir")"
fi
mkdir -p "$output_path"

if [[ -n "$remote_config_dir" ]]; then
  remote_dirs=("$remote_config_dir")
else
  remote_dirs=("${default_remote_config_dirs[@]}")
fi

for file_name in "${default_workflow_files[@]}"; do
  local_path="$output_path/$file_name"
  pulled=0
  for candidate_dir in "${remote_dirs[@]}"; do
    remote_path="$candidate_dir/$file_name"
    if receive_json_file "$remote_path" "$local_path"; then
      echo "pulled $file_name from $candidate_dir"
      pulled=1
      break
    fi
  done
  if [[ "$pulled" -ne 1 ]]; then
    die "failed to pull $file_name from any candidate default workflow config dir"
  fi
done

echo "default workflow JSON copied to $output_path"
