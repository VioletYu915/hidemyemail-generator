<#
  stop-burst.ps1 — 停止 burst 刷号
  1) 查找命令行为 burst-gen.ps1 的 PowerShell 进程（排除自身）
  2) 整树终止（连同正在运行的 uv / python / exe 子进程）
  3) 读取 burst-state.json，提示当前批次可 -Resume 续跑
  用法：双击 stop-burst.bat
#>
[CmdletBinding()]
param(
  [string]$Config = ""
)

if (-not $Config) { $Config = Join-Path $PSScriptRoot "config.json" }

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# 状态文件与 burst-gen.ps1 保持一致：位于 db_file 所在目录
$stateFile = Join-Path $PSScriptRoot "burst-state.json"
if (Test-Path $Config) {
  try {
    $cfg = Get-Content $Config -Raw | ConvertFrom-Json
    $db = "$($cfg.db_file)"
    if ($db) {
      if (-not [System.IO.Path]::IsPathRooted($db)) { $db = Join-Path $PSScriptRoot $db }
      $stateFile = Join-Path (Split-Path $db -Parent) "burst-state.json"
    }
  }
  catch { }
}

function Get-BurstProcesses {
  Get-CimInstance Win32_Process |
    Where-Object {
      $_.Name -in @("powershell.exe", "pwsh.exe") -and
      $_.ProcessId -ne $PID -and
      $_.CommandLine -and
      $_.CommandLine.Contains("burst-gen.ps1")
    }
}

$targets = @(Get-BurstProcesses)
if ($targets.Count -eq 0) {
  Write-Host "[OK] burst 未在运行，无需停止。"
  exit 0
}

foreach ($p in $targets) {
  taskkill /F /T /PID $p.ProcessId 2>&1 | Out-Null
  Write-Host "[OK] 已停止 burst 进程（PID $($p.ProcessId)）"
}

Start-Sleep -Seconds 2
$left = @(Get-BurstProcesses)
if ($left.Count -gt 0) {
  Write-Host "[WARN] 仍有残留进程: $(($left | ForEach-Object { $_.ProcessId }) -join ', ')"
}
else {
  Write-Host "[OK] burst 已全部停止"
}

if (Test-Path $stateFile) {
  try {
    $state = Get-Content $stateFile -Raw | ConvertFrom-Json
    Write-Host "当前批次: $($state.batch_id)（label=$($state.label)，已创建数保存在本地库）"
    Write-Host "如需继续该批次，在工具包目录运行:"
    Write-Host "  powershell -ExecutionPolicy Bypass -File `"$PSScriptRoot\burst-gen.ps1`" -Resume"
  }
  catch { }
}
