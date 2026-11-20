<#
  sync.ps1 — 归档
  步骤：sync-hme（云端地址入库）→ inbox sync（邮件+验证码）→ 删除对账 → 导出 CSV → 汇总

  兼容性：
    - result-json 不可用时（EXE v2.1.0 的 inbox 子命令）自动解析命令输出
    - 对账读取本地库：优先 result-json，不支持时用导出 CSV（两种模式都可用）

  配置见 config.json；Invoke-Hme 用数组传参，规避 PowerShell 对 --options 的参数解析陷阱
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

if (-not (Test-Path $Config)) {
  Write-Host "[ERR] 未找到 config.json" -ForegroundColor Red
  Write-Host "      请先双击 setup.bat 完成首次配置（会生成 config.json），或指定 -Config <路径>"
  exit 1
}

$cfg = Get-Content $Config -Raw | ConvertFrom-Json
. (Join-Path $PSScriptRoot "hme-common.ps1")
Initialize-HmePaths
$caps = Get-HmeCapabilities

$date = Get-Date -Format "yyyyMMdd"
$logDir = Join-Path $cfg.log_dir $date
New-Item -ItemType Directory -Force -Path $logDir, $cfg.export_dir | Out-Null
$log = Join-Path $logDir "sync.log"

function Write-Log {
  param([string]$m)
  $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $m
  Write-Host $line
  Add-Content -Path $log -Value $line -Encoding UTF8
}

$summary = [ordered]@{
  synced_cloud  = 0
  new_messages  = 0
  new_codes     = 0
  marked_trash  = 0
  exported      = $false
  cloud_list_ok = $false
}

# ── 1. 归档云端地址 ──
Write-Log "=== sync-hme 开始 ==="
$tmp = Join-Path $logDir "sync-hme.json"
Remove-Item $tmp -ErrorAction SilentlyContinue
$args = @("inbox", "sync-hme",
  "--cookie-file", $cfg.cookie_file,
  "--region", $cfg.region,
  "--db-file", $cfg.db_file)
if ($caps.SyncHmeResultJson) { $args += @("--result-json", $tmp) }
$out = Invoke-HmeRaw $args
Write-HmeOutput -Text $out -LogFile $log
if ($caps.SyncHmeResultJson) {
  $r = Read-HmeResult $tmp
  if ($r -and $r.ok) {
    $summary.synced_cloud = $r.count
    Write-Log "sync-hme 完成：$($r.count) 个云端地址已入库"
  }
  else {
    $msg = if ($r -and $r.error) { $r.error.message } else { "无结果文件" }
    Write-Log "sync-hme 失败（可能是 cookie 失效）：$msg"
  }
}
else {
  if ($out -match "Synced\s+(\d+)\s+Hide") { $summary.synced_cloud = [int]$Matches[1] }
  if ($LASTEXITCODE -ne 0) { Write-Log "sync-hme 失败（可能是 cookie 失效），详见上方输出" }
  else { Write-Log "sync-hme 完成（共 $($summary.synced_cloud) 个）" }
}

# ── 2. 同步邮件 + 提取验证码 ──
Write-Log "=== inbox sync 开始 ==="
$tmp = Join-Path $logDir "inbox-sync.json"
Remove-Item $tmp -ErrorAction SilentlyContinue
$args = @("inbox", "sync",
  "--config-file", $cfg.inbox_config,
  "--db-file", $cfg.db_file,
  "--limit", "100", "--show-codes")
if ($caps.SyncResultJson) { $args += @("--result-json", $tmp) }
$out = Invoke-HmeRaw $args
Write-HmeOutput -Text $out -LogFile $log
if ($caps.SyncResultJson) {
  $r = Read-HmeResult $tmp
  if ($r -and $r.ok) {
    $summary.new_messages = [int]$r.count
    if ($r.messages) { $summary.new_codes = @($r.messages | Where-Object { $_.code }).Count }
    Write-Log "inbox sync 完成：新增 $($r.count) 封"
  }
  else {
    $msg = if ($r -and $r.error) { $r.error.message } else { "无结果文件（IMAP 未配置？）" }
    Write-Log "inbox sync 失败/跳过：$msg"
  }
}
else {
  if ($out -match "Synced\s+(\d+)\s+new") { $summary.new_messages = [int]$Matches[1] }
  if ($LASTEXITCODE -ne 0) { Write-Log "inbox sync 失败/跳过（IMAP 未配置或登录失败），详见上方输出" }
  else { Write-Log "inbox sync 完成：新增 $($summary.new_messages) 封（验证码见上方输出）" }
}

# ── 3. 删除对账（云端已删的，本地标 trash） ──
# 数据源 = 苹果云端全量列表（active + inactive 两次合并），不依赖任何本地服务
if ($cfg.reconcile_enabled) {
  Write-Log "=== 删除对账开始 ==="
  try {
    $tmpA = Join-Path $logDir "cloud-active.json"
    Remove-Item $tmpA -ErrorAction SilentlyContinue
    Invoke-Hme @("list", "--cookie-file", $cfg.cookie_file, "--region", $cfg.region, "--result-json", $tmpA) | Out-Null
    $activeList = Read-HmeResult $tmpA

    $tmpI = Join-Path $logDir "cloud-inactive.json"
    Remove-Item $tmpI -ErrorAction SilentlyContinue
    Invoke-Hme @("list", "--inactive", "--cookie-file", $cfg.cookie_file, "--region", $cfg.region, "--result-json", $tmpI) | Out-Null
    $inactiveList = Read-HmeResult $tmpI

    if (-not $activeList -or -not $activeList.ok -or -not $inactiveList -or -not $inactiveList.ok) {
      throw "云端列表获取不完整（active/inactive 任一失败），为安全跳过本次对账"
    }

    $cloudEmails = @()
    if ($activeList.addresses) { $cloudEmails += @($activeList.addresses | ForEach-Object { $_.email.ToLower() }) }
    if ($inactiveList.addresses) { $cloudEmails += @($inactiveList.addresses | ForEach-Object { $_.email.ToLower() }) }
    $cloudEmails = @($cloudEmails | Sort-Object -Unique)
    $summary.cloud_list_ok = $true

    $local = @(Get-LocalAddressRows)
    $deleted = @($local | Where-Object {
      "$($_.source)" -eq "icloud" -and ($cloudEmails -notcontains "$($_.email)".ToLower())
    })
    foreach ($d in $deleted) {
      Invoke-Hme @("inbox", "mark", "$($d.email)", "trash", "--db-file", $cfg.db_file) | Out-Null
      Write-Log "对账：$($d.email) 已从 iCloud 删除，本地标 trash"
    }
    $summary.marked_trash = $deleted.Count
    Write-Log "对账完成：云端 $($cloudEmails.Count) 个，本地 $($local.Count) 个，新标 trash $($deleted.Count) 个"
  }
  catch {
    Write-Log "对账跳过：$($_.Exception.Message)"
  }
}

# ── 4. 导出 CSV ──
$month = Get-Date -Format "yyyyMM"
$expDir = Join-Path $cfg.export_dir $month
Invoke-Hme @("inbox", "export", "--db-file", $cfg.db_file, "--export-dir", $expDir) | Out-Null
if (Test-Path (Join-Path $expDir "addresses.csv")) {
  $summary.exported = $true
  Write-Log "已导出 CSV 到 $expDir"
}
else {
  Write-Log "导出失败或未找到 addresses.csv"
}

# ── 5. 汇总 ──
Write-Log "=== 汇总 ==="
foreach ($k in $summary.Keys) { Write-Log "  $k = $($summary[$k])" }
Write-Log "日志：$log"
