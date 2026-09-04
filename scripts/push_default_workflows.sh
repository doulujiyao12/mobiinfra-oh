#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/push_default_workflows.sh [options]

Options:
  --hdc <path>                   hdc executable path. Defaults to $HDC or hdc in PATH.
  --remote-workflow-root <dir>   Device workflows root to push into.
  --repo-config-dir <dir>        Local repo workflow config dir.
  -h, --help                     Show this help.
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

default_remote_workflow_roots=(
  "/data/app/el2/100/base/$app_bundle_name/haps/entry/files/workflows"
  "/data/storage/el2/base/haps/entry/files/workflows"
)

default_workflows=(
  "default_alipay_bill|0|Buy|#4B8BFF|default_alipay_bill.json"
  "default_ele_order|1|Food|#39BFA3|default_ele_order.json"
  "default_bilibili_history|2|Play|#8066FF|default_bilibili_history.json"
  "default_tencent_video_history|2|Play|#8066FF|default_tencent_video_history.json"
  "default_weixin_chat|3|Chat|#FF9347|default_weixin_chat.json"
  "default_weixin_today_chat|3|Chat|#FF9347|default_weixin_today_chat.json"
  "default_dianping_order|4|Life|#F59E0B|default_dianping_order.json"
  "default_meituan_order|4|Life|#F59E0B|default_meituan_order.json"
  "default_weibo_hot_search|5|Social|#E85D8E|default_weibo_hot_search.json"
  "default_xiaohongshu_history|5|Social|#E85D8E|default_xiaohongshu_history.json"
  "default_ctrip_order|6|Trip|#0EA5E9|default_ctrip_order.json"
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

capture_hdc() {
  set +e
  HDC_CAPTURE_OUTPUT="$("$hdc_path" "$@" 2>&1)"
  HDC_CAPTURE_STATUS=$?
  set -e
}

invoke_hdc() {
  capture_hdc "$@"
  if [[ "$HDC_CAPTURE_STATUS" -ne 0 ]]; then
    die "hdc failed: $*"$'\n'"$HDC_CAPTURE_OUTPUT"
  fi
  if [[ -n "$HDC_CAPTURE_OUTPUT" ]]; then
    printf '%s\n' "$HDC_CAPTURE_OUTPUT"
  fi
}

resolve_remote_workflow_root() {
  if [[ -n "$remote_workflow_root" ]]; then
    printf '%s\n' "$remote_workflow_root"
    return
  fi

  local candidate_root
  for candidate_root in "${default_remote_workflow_roots[@]}"; do
    capture_hdc shell "ls -la $candidate_root/configs"
    if [[ "$HDC_CAPTURE_STATUS" -eq 0 ]] && ! printf '%s\n' "$HDC_CAPTURE_OUTPUT" | grep -E "Permission denied|No such file|not exist" >/dev/null; then
      printf '%s\n' "$candidate_root"
      return
    fi
  done

  printf '%s\n' "${default_remote_workflow_roots[0]}"
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

compare_json_files() {
  local expected="$1"
  local actual="$2"
  python3 - "$expected" "$actual" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    expected = json.load(f)
with open(sys.argv[2], "r", encoding="utf-8") as f:
    actual = json.load(f)
sys.exit(0 if expected == actual else 1)
PY
}

upsert_task_index() {
  local index_path="$1"
  local workflow_path="$2"
  local workflow_id="$3"
  local scene_id="$4"
  local icon="$5"
  local icon_color="$6"
  local file_name="$7"

  python3 - "$index_path" "$workflow_path" "$workflow_id" "$scene_id" "$icon" "$icon_color" "$file_name" <<'PY'
import json
import os
import sys

index_path, workflow_path, workflow_id, scene_id, icon, icon_color, file_name = sys.argv[1:8]

if os.path.exists(index_path):
    with open(index_path, "r", encoding="utf-8") as f:
        task_index = json.load(f)
else:
    task_index = {"version": 1, "tasks": []}

if not isinstance(task_index, dict):
    task_index = {"version": 1, "tasks": []}
if "version" not in task_index:
    task_index["version"] = 1
if not isinstance(task_index.get("tasks"), list):
    task_index["tasks"] = []

with open(workflow_path, "r", encoding="utf-8") as f:
    workflow_json = f.read()
workflow = json.loads(workflow_json)
metadata = workflow.get("metadata") if isinstance(workflow, dict) else None
metadata = metadata if isinstance(metadata, dict) else {}
title = metadata.get("description") or "Custom Workflow"
source = metadata.get("name") or "workflow"

tasks = task_index["tasks"]
existing = None
for task in tasks:
    if isinstance(task, dict) and task.get("id") == workflow_id:
        existing = task
        break

if existing is None:
    existing = {
        "id": workflow_id,
        "sceneId": int(scene_id),
        "icon": icon,
        "iconColor": icon_color,
        "title": title,
        "source": source,
        "enabled": True,
        "configFileName": file_name,
        "workflowJson": workflow_json,
        "lastStatus": "not run",
        "lastRun": "never",
        "lastMessage": "Tap run to start workflow",
    }
    tasks.append(existing)
else:
    existing["sceneId"] = int(scene_id)
    existing["icon"] = icon
    existing["iconColor"] = icon_color
    existing["title"] = title
    existing["source"] = source
    if "enabled" not in existing:
        existing["enabled"] = True
    existing["configFileName"] = file_name
    existing["workflowJson"] = workflow_json
    existing.pop("isUserModified", None)

with open(index_path, "w", encoding="utf-8", newline="\n") as f:
    json.dump(task_index, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
}

validate_json_file() {
  local path="$1"
  python3 - "$path" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    json.load(f)
PY
}

write_deleted_index() {
  local deleted_path="$1"
  shift

  python3 - "$deleted_path" "$@" <<'PY'
import json
import os
import sys

deleted_path = sys.argv[1]
default_ids = set(sys.argv[2:])
remaining = []

if os.path.exists(deleted_path):
    with open(deleted_path, "r", encoding="utf-8") as f:
        deleted_index = json.load(f)
    ids = deleted_index.get("ids") if isinstance(deleted_index, dict) else []
    if isinstance(ids, list):
        remaining = [item for item in ids if item not in default_ids]

with open(deleted_path, "w", encoding="utf-8", newline="\n") as f:
    json.dump({"ids": remaining}, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
}

receive_remote_file() {
  local remote_path="$1"
  local local_path="$2"
  rm -f "$local_path"
  capture_hdc file recv "$remote_path" "$local_path"
  if [[ ! -f "$local_path" ]]; then
    die "failed to receive $remote_path"$'\n'"$HDC_CAPTURE_OUTPUT"
  fi
}

hdc_path="$(detect_hdc)"
remote_workflow_root=""
repo_config_dir=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hdc)
      [[ $# -ge 2 ]] || die "--hdc requires a value"
      hdc_path="$2"
      shift 2
      ;;
    --remote-workflow-root)
      [[ $# -ge 2 ]] || die "--remote-workflow-root requires a value"
      remote_workflow_root="$2"
      shift 2
      ;;
    --repo-config-dir)
      [[ $# -ge 2 ]] || die "--repo-config-dir requires a value"
      repo_config_dir="$2"
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

if [[ -z "$repo_config_dir" ]]; then
  repo_config_path="$repo_root/entry/src/main/resources/rawfile/workflows/configs"
else
  repo_config_path="$(resolve_repo_path "$repo_config_dir")"
fi
[[ -d "$repo_config_path" ]] || die "repo default workflow dir not found: $repo_config_path"

resolved_root="$(resolve_remote_workflow_root)"
remote_config_dir="$resolved_root/configs"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/mobiinfra-default-workflow-push.XXXXXX")"
trap 'rm -rf "$temp_dir"' EXIT

invoke_hdc shell "mkdir -p $remote_config_dir" >/dev/null

remote_index="$resolved_root/task-index.json"
local_index="$temp_dir/task-index.json"
capture_hdc file recv "$remote_index" "$local_index"
if [[ "$HDC_CAPTURE_STATUS" -ne 0 || ! -f "$local_index" ]]; then
  printf '{\n  "version": 1,\n  "tasks": []\n}\n' > "$local_index"
fi

default_ids=()
for meta in "${default_workflows[@]}"; do
  IFS='|' read -r workflow_id scene_id icon icon_color file_name <<< "$meta"
  default_ids+=("$workflow_id")

  local_config="$repo_config_path/$file_name"
  [[ -f "$local_config" ]] || die "missing repo default workflow: $local_config"

  normalize_json_file "$local_config"
  remote_config="$remote_config_dir/$file_name"
  invoke_hdc file send "$local_config" "$remote_config" >/dev/null

  verify_config="$temp_dir/verify-$file_name"
  receive_remote_file "$remote_config" "$verify_config"
  if ! compare_json_files "$local_config" "$verify_config"; then
    die "remote config verification failed for $file_name"
  fi

  upsert_task_index "$local_index" "$local_config" "$workflow_id" "$scene_id" "$icon" "$icon_color" "$file_name"
  echo "pushed and verified $file_name"
done

invoke_hdc file send "$local_index" "$remote_index" >/dev/null

verify_index="$temp_dir/verify-task-index.json"
receive_remote_file "$remote_index" "$verify_index"
validate_json_file "$verify_index"

remote_deleted="$resolved_root/deleted-default-tasks.json"
local_deleted="$temp_dir/deleted-default-tasks.json"
capture_hdc file recv "$remote_deleted" "$local_deleted"
if [[ "$HDC_CAPTURE_STATUS" -ne 0 || ! -f "$local_deleted" ]]; then
  printf '{\n  "ids": []\n}\n' > "$local_deleted"
fi
write_deleted_index "$local_deleted" "${default_ids[@]}"
invoke_hdc file send "$local_deleted" "$remote_deleted" >/dev/null

echo "repo default workflows forced into $resolved_root"
