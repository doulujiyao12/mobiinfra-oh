[CmdletBinding()]
param(
  [string]$HdcPath = "D:\download\deveco\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe",
  [string]$RemoteConfigDir = "",
  [string]$OutputDir = ""
)

$ErrorActionPreference = "Stop"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
. (Join-Path $PSScriptRoot "app_identity.ps1")

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$appBundleName = Get-AppBundleName -RepoRoot $repoRoot

$DefaultRemoteConfigDirs = @(
  "/data/app/el2/100/base/$appBundleName/haps/entry/files/workflows/configs",
  "/data/storage/el2/base/haps/entry/files/workflows/configs"
)

$DefaultWorkflowFiles = @(
  "default_alipay_bill.json",
  "default_ele_order.json",
  "default_bilibili_history.json",
  "default_tencent_video_history.json",
  "default_weixin_chat.json",
  "default_weixin_today_chat.json",
  "default_dianping_order.json",
  "default_meituan_order.json",
  "default_weibo_hot_search.json",
  "default_xiaohongshu_history.json",
  "default_ctrip_order.json"
)

function Read-Utf8Text {
  param([string]$Path)
  return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function Write-Utf8Text {
  param([string]$Path, [string]$Text)
  [System.IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
}

function Normalize-JsonFile {
  param([string]$Path)
  $workflow = Read-Utf8Text $Path | ConvertFrom-Json
  $json = $workflow | ConvertTo-Json -Depth 100
  Write-Utf8Text $Path ($json + [Environment]::NewLine)
}

function Receive-JsonFile {
  param([string]$RemotePath, [string]$LocalPath)

  $tempPath = $LocalPath + ".tmp-" + [Guid]::NewGuid().ToString("N")
  if (Test-Path -LiteralPath $tempPath) {
    Remove-Item -LiteralPath $tempPath -Force
  }

  $output = & $HdcPath @("file", "recv", $RemotePath, $tempPath) 2>&1
  if (!(Test-Path -LiteralPath $tempPath)) {
    if ($output) {
      Write-Verbose ($output | Out-String)
    }
    return $false
  }

  try {
    Normalize-JsonFile $tempPath
    Move-Item -LiteralPath $tempPath -Destination $LocalPath -Force
    return $true
  } catch {
    if (Test-Path -LiteralPath $tempPath) {
      Remove-Item -LiteralPath $tempPath -Force
    }
    throw
  }
}

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
  $outputPath = Join-Path $repoRoot "entry\src\main\resources\rawfile\workflows\configs"
} elseif ([System.IO.Path]::IsPathRooted($OutputDir)) {
  $outputPath = $OutputDir
} else {
  $outputPath = Join-Path $repoRoot $OutputDir
}

if (!(Test-Path -LiteralPath $HdcPath)) {
  throw "hdc not found: $HdcPath"
}

New-Item -ItemType Directory -Force -Path $outputPath | Out-Null
$remoteDirs = if ([string]::IsNullOrWhiteSpace($RemoteConfigDir)) { $DefaultRemoteConfigDirs } else { @($RemoteConfigDir) }

foreach ($fileName in $DefaultWorkflowFiles) {
  $local = Join-Path $outputPath $fileName
  $pulled = $false
  foreach ($candidateDir in $remoteDirs) {
    $remote = "$candidateDir/$fileName"
    if (Receive-JsonFile $remote $local) {
      Write-Host "pulled $fileName from $candidateDir"
      $pulled = $true
      break
    }
  }
  if (!$pulled) {
    throw "failed to pull $fileName from any candidate default workflow config dir"
  }
}

Write-Host "default workflow JSON copied to $outputPath"
