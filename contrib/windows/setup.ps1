<#
  setup.ps1 — 首次配置向导
  1) 选择运行模式（EXE 推荐 / 源码进阶）
  2) 定位程序（exe 或源码目录）
  3) 检查 cookies.txt 并验证登录
  4) 生成 config.json

  用法：双击 setup.bat
#>
[CmdletBinding()]
param(
  [string]$Config = ""
)

if (-not $Config) { $Config = Join-Path $PSScriptRoot "config.json" }

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = "utf-8"
$env:PYTHONUTF8 = "1"

function Resolve-InputPath {
  param([string]$p)
  if (-not $p) { return $p }
  if ([System.IO.Path]::IsPathRooted($p)) { return $p }
  return (Join-Path $PSScriptRoot $p)
}

$cfg = $null
if (Test-Path $Config) {
  try { $cfg = Get-Content $Config -Raw | ConvertFrom-Json } catch { }
}

Write-Host "=== hidemyemail Windows 工具包 · 首次配置 ==="
Write-Host ""
Write-Host "选择运行模式："
Write-Host "  1. EXE 模式（推荐，无需 Python）"
Write-Host "  2. 源码模式（进阶，支持自动抓取 cookie）"
$modeChoice = Read-Host "输入 1/2 [默认 1]"
$runMode = if ($modeChoice -eq "2") { "source" } else { "exe" }

$hmeExe = if ($cfg -and $cfg.hme_exe) { "$($cfg.hme_exe)" } else { "hidemyemail-windows.exe" }
$hmeSrc = if ($cfg -and $cfg.hme_src) { "$($cfg.hme_src)" } else { "../hidemyemail" }

if ($runMode -eq "exe") {
  $candidate = Resolve-InputPath $hmeExe
  if (-not (Test-Path $candidate)) {
    $found = Get-ChildItem $PSScriptRoot -Filter "hidemyemail*.exe" -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { $candidate = $found.FullName }
  }

  if (-not (Test-Path $candidate)) {
    Write-Host ""
    Write-Host "[WARN] 未找到 hidemyemail-windows.exe（约 15.5MB）"
    Write-Host "       请下载完整压缩包并解压后使用（不要只下载单个脚本）："
    Write-Host "       https://github.com/VioletYu915/hidemyemail-generator/releases/tag/v2.1.0-win"
    Write-Host "       也可以把 exe 放到本目录，或在下面输入完整路径"
  }

  while (-not (Test-Path $candidate)) {
    Write-Host "[WARN] 未找到 hidemyemail-windows.exe（可放到本目录，或输入完整路径）"
    $entered = Read-Host "EXE 路径（直接回车退出）"
    if (-not $entered) { Write-Host "已取消"; exit 1 }
    $candidate = Resolve-InputPath $entered
  }
  $hmeExe = $candidate
  Write-Host "[OK] EXE: $hmeExe"
}
else {
  $candidate = Resolve-InputPath $hmeSrc
  while (-not (Test-Path (Join-Path $candidate "pyproject.toml"))) {
    Write-Host "[WARN] 未找到源码目录（应包含 pyproject.toml）"
    $entered = Read-Host "源码目录路径（直接回车退出）"
    if (-not $entered) { Write-Host "已取消"; exit 1 }
    $candidate = Resolve-InputPath $entered
  }
  $hmeSrc = $candidate
  Write-Host "[OK] 源码目录: $hmeSrc"
  $uvCmd = Get-Command uv -ErrorAction SilentlyContinue
  if (-not $uvCmd) {
    Write-Host "[WARN] 未检测到 uv。请先安装后再运行本工具："
    Write-Host "       powershell -c `"irm https://astral.sh/uv/install.ps1 | iex`""
  }
  else {
    Write-Host "[OK] uv: $($uvCmd.Source)"
    $doSync = Read-Host "现在执行 uv python install 3.12 + uv sync --extra capture？[y/N]"
    if ($doSync -eq "y") {
      Push-Location $hmeSrc
      try {
        & $uvCmd.Source python install 3.12
        & $uvCmd.Source sync --extra capture
      }
      finally { Pop-Location }
    }
  }
}

$cookieFile = if ($cfg -and $cfg.cookie_file) { "$($cfg.cookie_file)" } else { "cookies.txt" }
$cookiePath = Resolve-InputPath $cookieFile
if (-not (Test-Path $cookiePath)) {
  Write-Host ""
  Write-Host "未找到 cookies.txt。获取方法见 README（浏览器扩展导出 Header string）。"
  $entered = Read-Host "cookies.txt 路径（直接回车跳过验证）"
  if ($entered) { $cookiePath = Resolve-InputPath $entered }
}

$region = if ($cfg -and $cfg.region) { "$($cfg.region)" } else { "china" }
$regionChoice = Read-Host "iCloud 区域：1) 中国区 icloud.com.cn  2) 全球 icloud.com [当前 $region]"
if ($regionChoice -eq "1") { $region = "china" }
elseif ($regionChoice -eq "2") { $region = "global" }

if ($cookiePath -and (Test-Path $cookiePath)) {
  Write-Host "== 验证 cookie =="
  $tmp = Join-Path $env:TEMP ("hme-whoami-{0}.json" -f (Get-Random))
  Remove-Item $tmp -ErrorAction SilentlyContinue
  if ($runMode -eq "exe") {
    & $hmeExe whoami --cookie-file $cookiePath --region $region --result-json $tmp 2>&1 | ForEach-Object { Write-Host "[hme] $_" }
  }
  else {
    Push-Location $hmeSrc
    try {
      & uv run hidemyemail whoami --cookie-file $cookiePath --region $region --result-json $tmp 2>&1 | ForEach-Object { Write-Host "[hme] $_" }
    }
    finally { Pop-Location }
  }
  if (Test-Path $tmp) {
    $r = Get-Content $tmp -Raw | ConvertFrom-Json
    if ($r.ok -and $r.account) { Write-Host "[OK] cookie 有效，Apple ID: $($r.account.apple_id)" }
    elseif ($r.error) { Write-Host "[WARN] cookie 验证失败：$($r.error.message)" }
    Remove-Item $tmp -ErrorAction SilentlyContinue
  }
  else {
    Write-Host "[WARN] 验证未返回结果（程序路径或依赖是否正确？）"
  }
}

$newCfg = [ordered]@{
  run_mode                  = $runMode
  hme_exe                   = if ($runMode -eq "exe") { $hmeExe } else { "hidemyemail-windows.exe" }
  hme_src                   = if ($runMode -eq "source") { $hmeSrc } else { "../hidemyemail" }
  uv_path                   = if ($cfg -and $cfg.uv_path) { "$($cfg.uv_path)" } else { "" }
  region                    = $region
  cookie_file               = if ($cookiePath) { $cookiePath } else { "cookies.txt" }
  inbox_config              = if ($cfg -and $cfg.inbox_config) { "$($cfg.inbox_config)" } else { "inbox_config.json" }
  db_file                   = if ($cfg -and $cfg.db_file) { "$($cfg.db_file)" } else { "hidemyemail.db" }
  export_dir                = if ($cfg -and $cfg.export_dir) { "$($cfg.export_dir)" } else { "exports" }
  log_dir                   = if ($cfg -and $cfg.log_dir) { "$($cfg.log_dir)" } else { "logs" }
  emails_output             = if ($cfg -and $cfg.emails_output) { "$($cfg.emails_output)" } else { "emails.txt" }
  reconcile_enabled         = if ($cfg) { [bool]$cfg.reconcile_enabled } else { $true }
  cooldown_minutes          = if ($cfg) { [int]$cfg.cooldown_minutes } else { 60 }
  burst_interval_minutes    = if ($cfg) { [int]$cfg.burst_interval_minutes } else { 10 }
  burst_mode                = if ($cfg) { "$($cfg.burst_mode)" } else { "group" }
  burst_group_size          = if ($cfg) { [int]$cfg.burst_group_size } else { 5 }
  burst_group_gap_seconds   = if ($cfg) { [int]$cfg.burst_group_gap_seconds } else { 60 }
  burst_group_jitter_seconds = if ($cfg) { [int]$cfg.burst_group_jitter_seconds } else { 30 }
  network_retry_count       = if ($cfg) { [int]$cfg.network_retry_count } else { 3 }
  network_retry_seconds     = if ($cfg) { [int]$cfg.network_retry_seconds } else { 60 }
  daily_target              = if ($cfg) { [int]$cfg.daily_target } else { 10 }
}
[System.IO.File]::WriteAllText($Config, ($newCfg | ConvertTo-Json), (New-Object System.Text.UTF8Encoding $false))

Write-Host ""
Write-Host "[OK] 配置已写入: $Config"
Write-Host "下一步：双击 start-burst.bat 开始"
