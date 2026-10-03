[CmdletBinding()]
param(
  [string]$HdcPath = "D:\download\deveco\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe",
  [string]$RemoteWorkflowRoot = "",
  [string]$RepoConfigDir = ""
)

$ErrorActionPreference = "Stop"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
. (Join-Path $PSScriptRoot "app_identity.ps1")

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$appBundleName = Get-AppBundleName -RepoRoot $repoRoot

$DefaultRemoteWorkflowRoots = @(
  "/data/app/el2/100/base/$appBundleName/haps/entry/files/workflows",
  "/data/storage/el2/base/haps/entry/files/workflows"
)

$DefaultWorkflows = @(
  [pscustomobject]@{ Id = "default_alipay_bill"; SceneId = 0; Icon = "Buy"; IconColor = "#4B8BFF"; FileName = "default_alipay_bill.json" },
  [pscustomobject]@{ Id = "default_ele_order"; SceneId = 1; Icon = "Food"; IconColor = "#39BFA3"; FileName = "default_ele_order.json" },
  [pscustomobject]@{ Id = "default_bilibili_history"; SceneId = 2; Icon = "Play"; IconColor = "#8066FF"; FileName = "default_bilibili_history.json" },
  [pscustomobject]@{ Id = "default_tencent_video_history"; SceneId = 2; Icon = "Play"; IconColor = "#8066FF"; FileName = "default_tencent_video_history.json" },
  [pscustomobject]@{ Id = "default_weixin_chat"; SceneId = 3; Icon = "Chat"; IconColor = "#FF9347"; FileName = "default_weixin_chat.json" },
  [pscustomobject]@{ Id = "default_weixin_today_chat"; SceneId = 3; Icon = "Chat"; IconColor = "#FF9347"; FileName = "default_weixin_today_chat.json" },
  [pscustomobject]@{ Id = "default_dianping_order"; SceneId = 4; Icon = "Life"; IconColor = "#F59E0B"; FileName = "default_dianping_order.json" },
  [pscustomobject]@{ Id = "default_meituan_order"; SceneId = 4; Icon = "Life"; IconColor = "#F59E0B"; FileName = "default_meituan_order.json" },
  [pscustomobject]@{ Id = "default_weibo_hot_search"; SceneId = 5; Icon = "Social"; IconColor = "#E85D8E"; FileName = "default_weibo_hot_search.json" },
  [pscustomobject]@{ Id = "default_xiaohongshu_history"; SceneId = 5; Icon = "Social"; IconColor = "#E85D8E"; FileName = "default_xiaohongshu_history.json" },
  [pscustomobject]@{ Id = "default_ctrip_order"; SceneId = 6; Icon = "Trip"; IconColor = "#0EA5E9"; FileName = "default_ctrip_order.json" }
)

function Invoke-Hdc {
  param([string[]]$HdcArgs)
  $output = & $HdcPath @HdcArgs 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "hdc failed: $($HdcArgs -join ' ')`n$($output | Out-String)"
  }
  return $output
}

function Try-Hdc {
  param([string[]]$HdcArgs)
  $output = & $HdcPath @HdcArgs 2>&1
  return @{
    Ok = ($LASTEXITCODE -eq 0)
    Output = ($output | Out-String)
  }
}

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
  return $json + [Environment]::NewLine
}

function Json-Fingerprint {
  param([string]$JsonText)
  return (($JsonText | ConvertFrom-Json) | ConvertTo-Json -Depth 100 -Compress)
}

function Receive-RemoteFile {
  param([string]$RemotePath, [string]$LocalPath)
  if (Test-Path -LiteralPath $LocalPath) {
    Remove-Item -LiteralPath $LocalPath -Force
  }
  $output = & $HdcPath @("file", "recv", $RemotePath, $LocalPath) 2>&1
  if (!(Test-Path -LiteralPath $LocalPath)) {
    throw "failed to receive $RemotePath`n$($output | Out-String)"
  }
}

function Resolve-RemoteWorkflowRoot {
  if (![string]::IsNullOrWhiteSpace($RemoteWorkflowRoot)) {
    return $RemoteWorkflowRoot
  }
  foreach ($candidateRoot in $DefaultRemoteWorkflowRoots) {
    $probe = Try-Hdc @("shell", "ls -la $candidateRoot/configs")
    if ($probe.Ok -and $probe.Output -notmatch "Permission denied|No such file|not exist") {
      return $candidateRoot
    }
  }
  return $DefaultRemoteWorkflowRoots[0]
}

function Set-JsonProperty {
  param([object]$Object, [string]$Name, [object]$Value)
  if ($Object.PSObject.Properties.Name -contains $Name) {
    $Object.$Name = $Value
  } else {
    Add-Member -InputObject $Object -NotePropertyName $Name -NotePropertyValue $Value
  }
}

function Remove-JsonProperty {
  param([object]$Object, [string]$Name)
  if ($Object.PSObject.Properties.Name -contains $Name) {
    $Object.PSObject.Properties.Remove($Name)
  }
}

function Workflow-Title {
  param([object]$Workflow)
  if ($Workflow.metadata -and $Workflow.metadata.description) {
    return [string]$Workflow.metadata.description
  }
  return "Custom Workflow"
}

function Workflow-Source {
  param([object]$Workflow)
  if ($Workflow.metadata -and $Workflow.metadata.name) {
    return [string]$Workflow.metadata.name
  }
  return "workflow"
}

if ([string]::IsNullOrWhiteSpace($RepoConfigDir)) {
  $repoConfigPath = Join-Path $repoRoot "entry\src\main\resources\rawfile\workflows\configs"
} elseif ([System.IO.Path]::IsPathRooted($RepoConfigDir)) {
  $repoConfigPath = $RepoConfigDir
} else {
  $repoConfigPath = Join-Path $repoRoot $RepoConfigDir
}

if (!(Test-Path -LiteralPath $HdcPath)) {
  throw "hdc not found: $HdcPath"
}
if (!(Test-Path -LiteralPath $repoConfigPath)) {
  throw "repo default workflow dir not found: $repoConfigPath"
}

$resolvedRoot = Resolve-RemoteWorkflowRoot
$remoteConfigDir = "$resolvedRoot/configs"
$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "mobiinfra-default-workflow-push"
New-Item -ItemType Directory -Force -Path $tempDir | Out-Null

Invoke-Hdc @("shell", "mkdir -p $remoteConfigDir") | Out-Null

$remoteIndex = "$resolvedRoot/task-index.json"
$localIndex = Join-Path $tempDir "task-index.json"
$indexRecv = Try-Hdc @("file", "recv", $remoteIndex, $localIndex)
if ($indexRecv.Ok -and (Test-Path -LiteralPath $localIndex)) {
  $taskIndex = Read-Utf8Text $localIndex | ConvertFrom-Json
} else {
  $taskIndex = [pscustomobject]@{ version = 1; tasks = @() }
}

if (!($taskIndex.PSObject.Properties.Name -contains "version")) {
  Set-JsonProperty $taskIndex "version" 1
}
if (!($taskIndex.PSObject.Properties.Name -contains "tasks") -or $null -eq $taskIndex.tasks) {
  Set-JsonProperty $taskIndex "tasks" @()
}

$tasks = New-Object System.Collections.ArrayList
foreach ($task in @($taskIndex.tasks)) {
  [void]$tasks.Add($task)
}

foreach ($meta in $DefaultWorkflows) {
  $localConfig = Join-Path $repoConfigPath $meta.FileName
  if (!(Test-Path -LiteralPath $localConfig)) {
    throw "missing repo default workflow: $localConfig"
  }

  $workflowJson = Normalize-JsonFile $localConfig
  $workflow = $workflowJson | ConvertFrom-Json
  $remoteConfig = "$remoteConfigDir/$($meta.FileName)"
  Invoke-Hdc @("file", "send", $localConfig, $remoteConfig) | Out-Null

  $verifyConfig = Join-Path $tempDir ("verify-" + $meta.FileName)
  Receive-RemoteFile $remoteConfig $verifyConfig
  $remoteJson = Read-Utf8Text $verifyConfig
  if ((Json-Fingerprint $remoteJson) -ne (Json-Fingerprint $workflowJson)) {
    throw "remote config verification failed for $($meta.FileName)"
  }

  $existing = $null
  foreach ($task in $tasks) {
    if ($task.id -eq $meta.Id) {
      $existing = $task
      break
    }
  }
  if ($null -eq $existing) {
    $existing = [pscustomobject]@{
      id = $meta.Id
      sceneId = [int]$meta.SceneId
      icon = $meta.Icon
      iconColor = $meta.IconColor
      title = Workflow-Title $workflow
      source = Workflow-Source $workflow
      enabled = $true
      configFileName = $meta.FileName
      workflowJson = $workflowJson
      lastStatus = "not run"
      lastRun = "never"
      lastMessage = "Tap run to start workflow"
    }
    [void]$tasks.Add($existing)
  } else {
    Set-JsonProperty $existing "sceneId" ([int]$meta.SceneId)
    Set-JsonProperty $existing "icon" $meta.Icon
    Set-JsonProperty $existing "iconColor" $meta.IconColor
    Set-JsonProperty $existing "title" (Workflow-Title $workflow)
    Set-JsonProperty $existing "source" (Workflow-Source $workflow)
    if (!($existing.PSObject.Properties.Name -contains "enabled")) {
      Set-JsonProperty $existing "enabled" $true
    }
    Set-JsonProperty $existing "configFileName" $meta.FileName
    Set-JsonProperty $existing "workflowJson" $workflowJson
    Remove-JsonProperty $existing "isUserModified"
  }
  Write-Host "pushed and verified $($meta.FileName)"
}

Set-JsonProperty $taskIndex "tasks" ([object[]]$tasks.ToArray())
$nextIndexJson = $taskIndex | ConvertTo-Json -Depth 100
Write-Utf8Text $localIndex $nextIndexJson
Invoke-Hdc @("file", "send", $localIndex, $remoteIndex) | Out-Null

$verifyIndex = Join-Path $tempDir "verify-task-index.json"
Receive-RemoteFile $remoteIndex $verifyIndex
Read-Utf8Text $verifyIndex | ConvertFrom-Json | Out-Null

$remoteDeleted = "$resolvedRoot/deleted-default-tasks.json"
$localDeleted = Join-Path $tempDir "deleted-default-tasks.json"
$defaultIds = @($DefaultWorkflows | ForEach-Object { $_.Id })
$deletedRecv = Try-Hdc @("file", "recv", $remoteDeleted, $localDeleted)
if ($deletedRecv.Ok -and (Test-Path -LiteralPath $localDeleted)) {
  $deletedIndex = Read-Utf8Text $localDeleted | ConvertFrom-Json
  $remaining = @($deletedIndex.ids) | Where-Object { $defaultIds -notcontains $_ }
} else {
  $remaining = @()
}
$nextDeleted = [pscustomobject]@{ ids = @($remaining) }
Write-Utf8Text $localDeleted ($nextDeleted | ConvertTo-Json -Depth 20)
Invoke-Hdc @("file", "send", $localDeleted, $remoteDeleted) | Out-Null

Write-Host "repo default workflows forced into $resolvedRoot"
