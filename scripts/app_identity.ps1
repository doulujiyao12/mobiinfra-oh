function Get-AppBundleName {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepoRoot
  )

  $appConfigPath = Join-Path $RepoRoot "AppScope\app.json5"
  if (!(Test-Path -LiteralPath $appConfigPath)) {
    throw "App config not found: $appConfigPath"
  }
  $content = [System.IO.File]::ReadAllText($appConfigPath, [System.Text.Encoding]::UTF8)
  $match = [regex]::Match($content, '"bundleName"\s*:\s*"([^"]+)"')
  if (!$match.Success -or [string]::IsNullOrWhiteSpace($match.Groups[1].Value)) {
    throw "app.bundleName is missing in: $appConfigPath"
  }
  return $match.Groups[1].Value
}
