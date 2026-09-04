#!/usr/bin/env python3
"""把源级 Workflow mock 数据导入已连接的 HarmonyOS 设备。"""

from __future__ import annotations

import argparse
import re
import subprocess
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_SOURCE_ROOT = REPO_ROOT / "mock" / "workflows-source"
DEFAULT_MODULE_NAME = "entry"


def load_app_bundle_name() -> str:
    """Read the bundle name from the repository's single app configuration."""

    app_config = REPO_ROOT / "AppScope" / "app.json5"
    content = app_config.read_text(encoding="utf-8")
    match = re.search(r'"bundleName"\s*:\s*"([^"]+)"', content)
    if match is None or not match.group(1).strip():
        raise RuntimeError(f"app.bundleName is missing in: {app_config}")
    return match.group(1).strip()


DEFAULT_BUNDLE_NAME = load_app_bundle_name()


def invoke_hdc(hdc: str, args: list[str], dry_run: bool = False) -> None:
    """执行一条 hdc 命令，并把常见 hdc 失败字符串也视为错误。"""

    command = [hdc] + args
    print(" ".join(command))
    if dry_run:
        return
    completed = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False)
    if completed.stdout:
        print(completed.stdout, end="")
    if completed.returncode != 0 or any(token in completed.stdout for token in ("[Fail]", "Permission denied", "No such file", "not found")):
        raise RuntimeError("hdc command failed: " + " ".join(command))


def import_mock(
    source_root: Path,
    bundle_name: str,
    module_name: str,
    device_workflows_root: str,
    hdc: str,
    include_runs: bool,
    dry_run: bool,
) -> None:
    """只把源级 mock 数据导入 App 的 workflows 目录。"""

    daily_log_source = source_root / "daily-log"
    if not daily_log_source.is_dir():
        raise FileNotFoundError(f"daily-log source not found: {daily_log_source}")
    if (source_root / "profile-consolidation").exists():
        raise RuntimeError("Source mock data must not include profile-consolidation derived outputs")

    # 将 daily-log 目录发送到 workflows 根目录。hdc 会保留目录名，
    # 因此设备端会得到 workflows/daily-log/YYYY-MM-DD/*.md。
    invoke_hdc(
        hdc,
        ["file", "send", "-b", bundle_name, str(daily_log_source), device_workflows_root],
        dry_run=dry_run,
    )

    runs_source = source_root / "runs"
    if include_runs:
        if not runs_source.is_dir():
            raise FileNotFoundError(f"runs source not found: {runs_source}")
        invoke_hdc(
            hdc,
            ["file", "send", "-b", bundle_name, str(runs_source), device_workflows_root],
            dry_run=dry_run,
        )


def main() -> int:
    parser = argparse.ArgumentParser(description="通过 hdc 导入 Workflow mock 源数据。")
    parser.add_argument("--source-root", default=str(DEFAULT_SOURCE_ROOT), help="Mock 源数据根目录，默认 mock/workflows-source")
    parser.add_argument("--bundle-name", default=DEFAULT_BUNDLE_NAME)
    parser.add_argument("--module-name", default=DEFAULT_MODULE_NAME)
    parser.add_argument("--device-workflows-root", default="")
    parser.add_argument("--hdc", default="hdc")
    parser.add_argument("--include-runs", action="store_true", help="同时导入可选 runs 数据")
    parser.add_argument("--dry-run", action="store_true", help="只打印 hdc 命令，不实际执行")
    args = parser.parse_args()

    device_workflows_root = args.device_workflows_root.strip()
    if not device_workflows_root:
        # 配合 hdc file send -b 使用 bundle 作用域 /data/storage 别名，
        # 避免依赖物理 /data/app/el2/... 目录结构。
        device_workflows_root = f"/data/storage/el2/base/haps/{args.module_name}/files/workflows"

    import_mock(
        source_root=Path(args.source_root),
        bundle_name=args.bundle_name,
        module_name=args.module_name,
        device_workflows_root=device_workflows_root,
        hdc=args.hdc,
        include_runs=args.include_runs,
        dry_run=args.dry_run,
    )
    print("完成。请打开 App 并触发应用内同步/分析流程。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
