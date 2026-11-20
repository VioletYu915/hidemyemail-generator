<#
  burst-gen.ps1 — hidemyemail 批量刷号驱动（三模式，由 config.json 的 burst_mode 切换）

  兼容性：
    - 源码模式：支持 batch 记账（-Resume 精确续跑）
    - EXE 模式（v2.1.0 无 batch 命令）：自动降级为本地状态文件跟踪，-Resume 仍可用

  模式：
    group    组模式（默认）：组内每两个创建之间等 随机(60±30 秒)；本组第 5 个完成后，
             冷却到「第 5 个完成时刻 + cooldown_minutes」；然后开始下一组
    interval 间隔模式：每个创建后等固定 N 分钟（跨小时恒定）
    burst    连发模式：成功即继续（无等待）

  通用行为：
    -41015          -> 兜底冷却 max(retry_after, cooldown分钟) 后自动续跑
    网络错误        -> 等 network_retry_seconds 秒后重试（最多 network_retry_count 次）
    会话失效        -> 停下，提示更新 cookies.txt
    其它错误        -> 停下，记录
  互斥：不要与其它生成工具同时运行，避免共享 Apple 配额互相干扰

  用法：
    双击 启动刷号.bat（推荐）
    powershell -ExecutionPolicy Bypass -File .\burst-gen.ps1
    powershell -ExecutionPolicy Bypass -File .\burst-gen.ps1 -Resume
    powershell -ExecutionPolicy Bypass -File .\burst-gen.ps1 -Target 20 -IntervalMinutes 15 -CooldownMinutes 60
#>
[CmdletBinding()]
param(
  [int]$Target = 0,
  [string]$Label = "",
  [int]$CooldownMinutes = 0,
  [int]$IntervalMinutes = -1,
  [int]$MaxConsecutiveRateLimits = 20,
  [switch]$Resume,
  [string]$Config = ""
)

if (-not $Config) { $Config = Join-Path $PSScriptRoot "config.json" }

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = "utf-8"
$env:PYTHONUTF8 = "1"

$cfg = Get-Content $Config -Raw | ConvertFrom-Json
. (Join-Path $PSScriptRoot "hme-common.ps1")
Initialize-HmePaths

if (-not $Target -and -not $Resume) {
  $entered = Read-Host "本次刷几个？[默认 $($cfg.daily_target)]"
  if ($entered -match '^\d+$' -and [int]$entered -gt 0) { $Target = [int]$entered }
}
if (-not $Target) { $Target = $cfg.daily_target }
if (-not $CooldownMinutes) { $CooldownMinutes = $cfg.cooldown_minutes }
if ($IntervalMinutes -lt 0) {
  $IntervalMinutes = if ($null -ne $cfg.burst_interval_minutes) { [int]$cfg.burst_interval_minutes } else { 0 }
}
$Mode = if ($cfg.burst_mode) { "$($cfg.burst_mode)".ToLower() } else { "group" }
if (@("group", "interval", "burst") -notcontains $Mode) { $Mode = "group" }
$GroupSize = if ($null -ne $cfg.burst_group_size) { [int]$cfg.burst_group_size } else { 5 }
if ($GroupSize -lt 1) { $GroupSize = 1 }
$GroupGap = if ($null -ne $cfg.burst_group_gap_seconds) { [int]$cfg.burst_group_gap_seconds } else { 60 }
if ($GroupGap -le 0) { $GroupGap = 1 }
$GroupJitter = if ($null -ne $cfg.burst_group_jitter_seconds) { [int]$cfg.burst_group_jitter_seconds } else { 30 }
if ($GroupJitter -lt 0) { $GroupJitter = 0 }
$NetworkRetryCount = if ($null -ne $cfg.network_retry_count) { [int]$cfg.network_retry_count } else { 3 }
if ($NetworkRetryCount -lt 0) { $NetworkRetryCount = 0 }
$NetworkRetrySeconds = if ($null -ne $cfg.network_retry_seconds) { [int]$cfg.network_retry_seconds } else { 60 }
if ($NetworkRetrySeconds -lt 1) { $NetworkRetrySeconds = 60 }
if (-not $Label) { $Label = "burst-" + (Get-Date -Format "yyMMdd-HHmm") }

$date = Get-Date -Format "yyyyMMdd"
$logDir = Join-Path $cfg.log_dir "$date-burst"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$log = Join-Path $logDir "burst.log"
$stateFile = Join-Path (Split-Path $cfg.db_file -Parent) "burst-state.json"

function Write-Log {
  param([string]$m)
  $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $m
  Write-Host $line
  Add-Content -Path $log -Value $line -Encoding UTF8
}

function Save-State {
  param([int]$CreatedCount)
  @{ batch_id = $batchId; target = $Target; label = $Label; created = $CreatedCount } |
    ConvertTo-Json | Set-Content $stateFile -Encoding UTF8
}

$caps = Get-HmeCapabilities
$batchId = $null
$created = 0

# ── 0. 取得/恢复 batch ──
if ($Resume -and (Test-Path $stateFile)) {
  $state = Get-Content $stateFile -Raw | ConvertFrom-Json
  $batchId = $state.batch_id
  if (-not $Label -and $state.label) { $Label = $state.label }
  if (-not $Target -or $Target -eq $cfg.daily_target) { $Target = [int]$state.target }
  if ($caps.Batch -and $batchId) {
    $tmp = Join-Path $logDir "batch-status.json"
    Remove-Item $tmp -ErrorAction SilentlyContinue
    Invoke-Hme @("batch", "status", $batchId, "--db-file", $cfg.db_file, "--result-json", $tmp) -LogFile $log
    $bs = (Read-HmeResult $tmp).batch
    if ($bs) { $created = [int]$bs.reserved }
  }
  else {
    if ($null -ne $state.created) { $created = [int]$state.created }
    if (-not $batchId) { $batchId = "local-" + (Get-Date -Format "yyMMdd-HHmm") }
  }
  Write-Log "续跑：batch $batchId，已创建 $created / $Target，label=$Label$(if (-not $caps.Batch) { '（兼容模式：无 batch 命令）' })"
}
else {
  if ($caps.Batch) {
    $tmp = Join-Path $logDir "batch-start.json"
    Remove-Item $tmp -ErrorAction SilentlyContinue
    Invoke-Hme @("batch", "start",
      "--label", $Label, "--target", "$Target",
      "--interval-minutes", "$CooldownMinutes",
      "--db-file", $cfg.db_file, "--result-json", $tmp) -LogFile $log
    $batchId = (Read-HmeResult $tmp).batch.id
    if (-not $batchId) { Write-Log "batch 创建失败，退出"; exit 1 }
    Write-Log "新建 batch $batchId（target=$Target, cooldown=${CooldownMinutes}min, label=$Label）"
  }
  else {
    $batchId = "local-" + (Get-Date -Format "yyMMdd-HHmm")
    Write-Log "程序不支持 batch 命令（如 EXE v2.1.0），使用本地状态跟踪：$batchId"
  }
  Save-State -CreatedCount 0
}

if ($created -ge $Target) { Write-Log "已达目标，无需运行"; exit 0 }

if ($Mode -eq "group") {
  $modeText = "组模式（每组 $GroupSize 个，组内 $($GroupGap - $GroupJitter)~$($GroupGap + $GroupJitter) 秒，组间冷却 $CooldownMinutes 分钟）"
}
elseif ($Mode -eq "interval" -and $IntervalMinutes -gt 0) {
  $modeText = "间隔模式（每 $IntervalMinutes 分钟 1 个）"
}
else {
  $modeText = "连发模式（无间隔）"
}
Write-Log "模式：目标 $Target 个 ｜ $modeText"

# ── 1. 主循环 ──
$consecutive = 0
$groupCount = 0
$netRetries = 0
while ($created -lt $Target) {
  $tmp = Join-Path $logDir "gen-$created.json"
  Remove-Item $tmp -ErrorAction SilentlyContinue
  $genArgs = @("generate", "--count", "1", "--label", $Label,
    "--cookie-file", $cfg.cookie_file,
    "--region", $cfg.region,
    "--db-file", $cfg.db_file,
    "--output", $cfg.emails_output,
    "--result-json", $tmp)
  if ($caps.Batch -and $batchId) { $genArgs += @("--batch-id", $batchId) }
  Invoke-Hme $genArgs -LogFile $log

  $cliExit = $LASTEXITCODE
  $r = Read-HmeResult $tmp
  if ($null -eq $r) { Write-Log "结果文件缺失（CLI exit=$cliExit），终止"; exit 1 }

  if ($r.ok) {
    $created++
    $consecutive = 0
    $netRetries = 0
    $groupCount++
    Save-State -CreatedCount $created
    Write-Log "已创建 $created / $Target : $($r.emails[0])"

    if ($created -ge $Target) { continue }

    if ($Mode -eq "group") {
      if ($groupCount -ge $GroupSize) {
        $groupCount = 0
        $wait = $CooldownMinutes * 60
        $until = (Get-Date).AddSeconds($wait).ToString("HH:mm:ss")
        Write-Log "本组完成（第 $GroupSize 个）：冷却 $CooldownMinutes 分钟，预计 $until 开始下一组（$created / $Target）"
        $rest = $wait
        while ($rest -gt 0) {
          Start-Sleep -Seconds ([Math]::Min(300, $rest))
          $rest -= 300
          if ($rest -gt 0) { Write-Log "  组间冷却剩余 $([Math]::Ceiling($rest / 60)) 分钟" }
        }
      }
      else {
        $gap = $GroupGap - $GroupJitter + (Get-Random -Minimum 0 -Maximum ($GroupJitter * 2 + 1))
        $nextAt = (Get-Date).AddSeconds($gap).ToString("HH:mm:ss")
        Write-Log "本组小间隔 $gap 秒（预计 $nextAt 创建本组第 $($groupCount + 1) 个）"
        Start-Sleep -Seconds $gap
      }
    }
    elseif ($Mode -eq "interval" -and $IntervalMinutes -gt 0) {
      $wait = $IntervalMinutes * 60
      $nextAt = (Get-Date).AddSeconds($wait).ToString("HH:mm:ss")
      Write-Log "间隔 $IntervalMinutes 分钟（预计 $nextAt 创建下一个）"
      $rest = $wait
      while ($rest -gt 0) {
        Start-Sleep -Seconds ([Math]::Min(300, $rest))
        $rest -= 300
        if ($rest -gt 0) { Write-Log "  间隔剩余 $([Math]::Ceiling($rest / 60)) 分钟" }
      }
    }
    continue
  }

  $err = $r.error
  if ($err.code -eq "-41015") {
    $consecutive++
    if ($consecutive -gt $MaxConsecutiveRateLimits) {
      Write-Log "连续 $consecutive 次限速仍未成功，终止（防止空转）"
      exit 1
    }
    $retryAfter = if ($err.retry_after) { [double]$err.retry_after } else { 0 }
    $cooldown = [Math]::Max($retryAfter, $CooldownMinutes * 60)
    $until = (Get-Date).AddSeconds($cooldown).ToString("HH:mm:ss")
    Write-Log "撞限速（-41015）：冷却 $([Math]::Ceiling($cooldown / 60)) 分钟，预计 $until 自动续跑（$created / $Target）"
    $rest = [int]$cooldown
    while ($rest -gt 0) {
      Start-Sleep -Seconds ([Math]::Min(300, $rest))
      $rest -= 300
      if ($rest -gt 0) { Write-Log "  冷却剩余 $([Math]::Ceiling($rest / 60)) 分钟" }
    }
    continue
  }

  if (Test-NetworkError $err.message) {
    $netRetries++
    if ($netRetries -gt $NetworkRetryCount) {
      Write-Log "网络错误连续 $netRetries 次，终止：$($err.message)"
      exit 1
    }
    $until = (Get-Date).AddSeconds($NetworkRetrySeconds).ToString("HH:mm:ss")
    Write-Log "网络错误（$($err.message)）：$NetworkRetrySeconds 秒后重试（第 $netRetries / $NetworkRetryCount 次），预计 $until（$created / $Target）"
    Start-Sleep -Seconds $NetworkRetrySeconds
    continue
  }

  if (Test-AuthError $err.message) {
    Write-Log "会话失效：$($err.message)"
    Write-Log "请更新 cookies.txt（源码模式可重跑 capture-cookie；EXE 模式用浏览器扩展重新导出），再用 -Resume 续跑"
    exit 2
  }

  Write-Log "其它错误，终止：$($err.message)"
  exit 1
}

# ── 2. 完成 ──
if ($caps.Batch -and $batchId) {
  Invoke-Hme @("batch", "stop", $batchId, "--db-file", $cfg.db_file) -LogFile $log
}
Write-Log "完成：共创建 $created 个（batch $batchId）"
Write-Log "地址见 $($cfg.emails_output)；检索：inbox addresses --query ..."
Write-Log "日志：$log"
