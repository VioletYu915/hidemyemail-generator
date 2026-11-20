<#
  hme-common.ps1 — 共享函数（由各脚本 dot-source）
  约定：调用方已加载 $cfg（config.json）并设置好 UTF-8 环境
  兼容性：自动探测当前程序（源码 / EXE）是否支持 batch、result-json 等能力，
          不支持时降级（EXE v2.1.0 无 batch/quota，inbox 子命令无 result-json）
#>

$script:HmeRunner = $null
$script:HmeCaps = $null

function Resolve-CfgPath {
  param([string]$PathValue)
  if (-not $PathValue) { return $PathValue }
  if ([System.IO.Path]::IsPathRooted($PathValue)) { return $PathValue }
  return (Join-Path $PSScriptRoot $PathValue)
}

function Initialize-HmePaths {
  foreach ($k in @("hme_exe", "hme_src", "cookie_file", "inbox_config", "db_file", "export_dir", "log_dir", "emails_output")) {
    if ($cfg.PSObject.Properties.Name -contains $k) { $cfg.$k = Resolve-CfgPath "$($cfg.$k)" }
  }
}

function Get-HmeRunner {
  if ($script:HmeRunner) { return $script:HmeRunner }
  if ("$($cfg.run_mode)" -eq "exe") {
    $exe = Resolve-CfgPath "$($cfg.hme_exe)"
    if (-not $exe -or -not (Test-Path $exe)) {
      throw "run_mode=exe，但找不到 hidemyemail-windows.exe（检查 config.json 的 hme_exe）"
    }
    $script:HmeRunner = @{ Kind = "exe"; Exe = (Resolve-Path $exe).Path }
  }
  else {
    $src = Resolve-CfgPath "$($cfg.hme_src)"
    if (-not $src -or -not (Test-Path (Join-Path $src "pyproject.toml"))) {
      throw "run_mode=source，但找不到源码目录（检查 config.json 的 hme_src）"
    }
    $uv = "$($cfg.uv_path)"
    if (-not $uv -or -not (Test-Path $uv)) {
      $c = Get-Command uv -ErrorAction SilentlyContinue
      $uv = if ($c) { $c.Source } else { "uv" }
    }
    $script:HmeRunner = @{ Kind = "source"; Src = (Resolve-Path $src).Path; Uv = $uv }
  }
  return $script:HmeRunner
}

function Invoke-HmeRaw {
  param([string[]]$CmdArgs)
  $r = Get-HmeRunner
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    if ($r.Kind -eq "exe") {
      $lines = @(& $r.Exe @CmdArgs 2>&1 | ForEach-Object { "$_" })
      return ($lines -join "`r`n")
    }
    Push-Location $r.Src
    try {
      $lines = @(& $r.Uv run hidemyemail @CmdArgs 2>&1 | ForEach-Object { "$_" })
      return ($lines -join "`r`n")
    }
    finally { Pop-Location }
  }
  finally { $ErrorActionPreference = $prev }
}

function Write-HmeOutput {
  param([string]$Text, [string]$LogFile = "")
  if (-not $Text) { return }
  $Text -split "`r?`n" | Where-Object { $_.Trim() -ne "" } | ForEach-Object {
    Write-Host "[hme] $_"
    if ($LogFile) {
      Add-Content -Path $LogFile -Value "[hme] $_" -Encoding UTF8 -ErrorAction SilentlyContinue
    }
  }
}

function Invoke-Hme {
  param([string[]]$CmdArgs, [string]$LogFile = "")
  $out = Invoke-HmeRaw $CmdArgs
  Write-HmeOutput -Text $out -LogFile $LogFile
}

function Read-HmeResult {
  param([string]$File)
  if (Test-Path $File) { return (Get-Content $File -Raw | ConvertFrom-Json) }
  return $null
}

function Get-HmeCapabilities {
  if ($script:HmeCaps) { return $script:HmeCaps }
  $caps = @{
    Batch                    = $false
    InboxAddressesResultJson = $false
    SyncHmeResultJson        = $false
    SyncResultJson           = $false
    UpdateMetadataDb         = $false
  }
  $h = Invoke-HmeRaw @("batch", "--help")
  if ($LASTEXITCODE -eq 0 -and $h -match "(?m)^\s+start\b") { $caps.Batch = $true }

  $h = Invoke-HmeRaw @("inbox", "addresses", "--help")
  if ($LASTEXITCODE -eq 0 -and $h -match "result-json") { $caps.InboxAddressesResultJson = $true }

  $h = Invoke-HmeRaw @("inbox", "sync-hme", "--help")
  if ($LASTEXITCODE -eq 0 -and $h -match "result-json") { $caps.SyncHmeResultJson = $true }

  $h = Invoke-HmeRaw @("inbox", "sync", "--help")
  if ($LASTEXITCODE -eq 0 -and $h -match "result-json") { $caps.SyncResultJson = $true }

  $h = Invoke-HmeRaw @("update-metadata", "--help")
  if ($LASTEXITCODE -eq 0 -and $h -match "db-file") { $caps.UpdateMetadataDb = $true }

  $script:HmeCaps = $caps
  return $caps
}

# 返回本地地址行（对象：email/label/note/state/source）
# 优先 result-json；EXE v2.1.0 无该选项时降级为导出 CSV 读取
function Get-LocalAddressRows {
  $caps = Get-HmeCapabilities
  if ($caps.InboxAddressesResultJson) {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("hme-addr-{0}.json" -f (Get-Random))
    Remove-Item $tmp -ErrorAction SilentlyContinue
    Invoke-Hme @("inbox", "addresses", "--db-file", $cfg.db_file, "--limit", "100000", "--result-json", $tmp) | Out-Null
    $r = Read-HmeResult $tmp
    Remove-Item $tmp -ErrorAction SilentlyContinue
    if ($r -and $r.ok) { return @($r.addresses) }
  }

  $exp = Join-Path ([System.IO.Path]::GetTempPath()) ("hme-exp-{0}" -f (Get-Random))
  New-Item -ItemType Directory -Force -Path $exp | Out-Null
  try {
    Invoke-Hme @("inbox", "export", "--db-file", $cfg.db_file, "--export-dir", $exp) | Out-Null
    $csv = Join-Path $exp "addresses.csv"
    if (Test-Path $csv) { return @(Import-Csv $csv) }
    return @()
  }
  finally {
    Remove-Item $exp -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Test-AuthError {
  param([string]$message)
  if (-not $message) { return $false }
  $m = $message.ToLower()
  return ($m.Contains("invalid global session") -or $m.Contains("invalid session") -or
          $m.Contains("x-apple-webauth-user") -or $m.Contains("cookie"))
}

function Test-NetworkError {
  param([string]$message)
  if (-not $message) { return $false }
  $m = $message.ToLower()
  $markers = @(
    "cannot connect", "connection reset", "connection refused",
    "timed out", "timeout", "getaddrinfo", "name resolution",
    "temporary failure", "network is unreachable", "server disconnected",
    "clientconnector", "connect call failed", "ssl"
  )
  foreach ($k in $markers) {
    if ($m.Contains($k)) { return $true }
  }
  return $false
}
