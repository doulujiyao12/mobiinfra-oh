param(
  [string]$Source = "",
  [string]$BundleName = "",
  [string]$ModuleName = "entry",
  [string]$DeviceWorkflowsRoot = "",
  [string]$Hdc = "hdc",
  [switch]$IncludeRuns
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "app_identity.ps1")

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ([string]::IsNullOrWhiteSpace($BundleName)) {
  $BundleName = Get-AppBundleName -RepoRoot $repoRoot
}

function Invoke-HdcChecked {
  param(
    [string[]]$Arguments,
    [string]$FailureMessage
  )

  # hdc 有时会在输出里打印失败标记，单看退出码不够稳定；
  # 因此同时检查退出码和常见失败字符串。
  $output = & $Hdc @Arguments 2>&1
  $exitCode = $LASTEXITCODE
  if ($output) {
    $output | ForEach-Object { Write-Host $_ }
  }
  $text = ($output | Out-String)
  if ($exitCode -ne 0 -or $text -match "\[Fail\]|Permission denied|No such file|not found") {
    throw "$FailureMessage`n$text"
  }
}

if ([string]::IsNullOrWhiteSpace($Source)) {
  $Source = Join-Path $PSScriptRoot "..\mock\workflows-source"
}

$runsSource = ""
if (Test-Path -LiteralPath $Source) {
  # 兼容完整 mock 根目录和直接传入 daily-log 目录两种形式，
  # 旧的 fixture 导入流程也可以继续使用。
  $dailyLogChild = Join-Path $Source "daily-log"
  $runsChild = Join-Path $Source "runs"
  if ((Split-Path -Leaf $Source) -ne "daily-log" -and (Test-Path -LiteralPath $dailyLogChild)) {
    if ($IncludeRuns -and (Test-Path -LiteralPath $runsChild)) {
      $runsSource = $runsChild
    }
    $Source = $dailyLogChild
  }
}

if (-not (Test-Path -LiteralPath $Source)) {
  throw "Daily-log fixture 源目录不存在: $Source"
}

$resolvedSource = (Resolve-Path -LiteralPath $Source).Path

if ([string]::IsNullOrWhiteSpace($DeviceWorkflowsRoot)) {
  # 配合 hdc file send -b <bundle> 使用运行时 filesDir 别名。
  # 直接访问 /data/app/el2/... 物理路径通常会遇到权限问题。
  $DeviceWorkflowsRoot = "/data/storage/el2/base/haps/$ModuleName/files/workflows"
}

Write-Host "使用设备 workflows 目录:"
Write-Host "  $DeviceWorkflowsRoot"
Write-Host "使用调试 bundle 参数:"
Write-Host "  -b $BundleName"
Write-Host "如果该路径不适配当前设备，请覆盖 -DeviceWorkflowsRoot、-BundleName 或 -ModuleName。"

Write-Host "发送 daily-log fixture:"
Write-Host "  来源: $resolvedSource"
Write-Host "  目标: $DeviceWorkflowsRoot/daily-log"
Invoke-HdcChecked -Arguments @("file", "send", "-b", $BundleName, $resolvedSource, $DeviceWorkflowsRoot) -FailureMessage "hdc file send 失败"

if ($IncludeRuns) {
  # runs 是可选输入，因为 consolidation 的真实源头是 daily-log。
  # run_summary.json 只用于图片引用和索引验证。
  if ([string]::IsNullOrWhiteSpace($runsSource)) {
    Write-Host "已请求 IncludeRuns，但未找到 runs 源目录。跳过可选 runs 导入。"
  } else {
    $resolvedRuns = (Resolve-Path -LiteralPath $runsSource).Path
    Write-Host "发送可选 run summaries:"
    Write-Host "  来源: $resolvedRuns"
    Write-Host "  目标: $DeviceWorkflowsRoot/runs"
    Invoke-HdcChecked -Arguments @("file", "send", "-b", $BundleName, $resolvedRuns, $DeviceWorkflowsRoot) -FailureMessage "hdc file send runs 失败"
  }
}

Write-Host "完成。请打开 App，进入数据采集，然后点击同步。"
