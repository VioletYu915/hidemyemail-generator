<#
  retag.ps1 — 批量修改隐藏邮箱的标签/备注（可复用）

  用法：
    双击 改标签.bat（交互菜单，推荐）
    或命令行：
      powershell -File retag.ps1 -Template     生成/刷新模板 retag.csv（导出当前全部地址）
      powershell -File retag.ps1 -DryRun       预览将执行的修改（不动数据）
      powershell -File retag.ps1 -Apply        执行修改（交互确认）
      powershell -File retag.ps1 -Apply -Yes   执行修改（跳过确认，供自动化）

  模板填写规则（新标签/新备注 两列）：
    留空     = 保持原值
    文字     = 改为该文字
    单个 -   = 清空

  特性：
    - Excel 友好：模板为 UTF-8 BOM；兼容 Excel 另存的 GBK 编码
    - 本地库自动同步（--db-file）；标签/备注会直接改到苹果侧
    - 逐条执行、1.5 秒间隔；输出成功/失败汇总
    - 修改标签/备注不消耗地址创建配额，不影响邮件转发
#>
[CmdletBinding()]
param(
  [switch]$Template,
  [switch]$DryRun,
  [switch]$Apply,
  [switch]$Yes,
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
$caps = Get-HmeCapabilities

$csvPath = Join-Path $PSScriptRoot "retag.csv"

function Read-CsvSmart {
  param([string]$Path)
  $bytes = [System.IO.File]::ReadAllBytes($Path)
  if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    return [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
  }
  try {
    $strict = New-Object System.Text.UTF8Encoding $false, $true
    return $strict.GetString($bytes)
  }
  catch {
    return [System.Text.Encoding]::GetEncoding(936).GetString($bytes)
  }
}

# ── 无参数 → 交互菜单 ──
if (-not ($Template -or $DryRun -or $Apply)) {
  Write-Host ""
  Write-Host "批量改标签/备注，选择操作："
  Write-Host "  1. 生成/刷新模板 retag.csv（导出当前地址清单）"
  Write-Host "  2. 预览变更（按 retag.csv，不实际修改）"
  Write-Host "  3. 执行修改（按 retag.csv）"
  $choice = Read-Host "输入 1/2/3"
  switch ($choice) {
    "1" { $Template = $true }
    "2" { $DryRun = $true }
    "3" { $Apply = $true }
    default { Write-Host "无效选择"; exit 1 }
  }
}

# ── 生成模板 ──
if ($Template) {
  Write-Host "读取本地库地址..."
  $addrs = @(Get-LocalAddressRows)
  if ($addrs.Count -eq 0) {
    Write-Host "[ERR] 本地库没有地址（先跑一次 归档.bat 同步？）"
    exit 1
  }
  $rows = $addrs | ForEach-Object {
    [pscustomobject]@{
      "邮箱"     = $_.email
      "当前标签" = "$($_.label)"
      "当前备注" = "$($_.note)"
      "新标签"   = ""
      "新备注"   = ""
    }
  }
  $rows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
  Write-Host ""
  Write-Host "[OK] 已生成模板：$csvPath（共 $($rows.Count) 条）"
  Write-Host "     用 Excel 填写 新标签/新备注 列：留空=保持，文字=修改，单个减号 - = 清空"
  Write-Host "     填好后双击 改标签.bat，选 2 预览、选 3 执行"
  exit 0
}

# ── 预览 / 执行 ──
if (-not (Test-Path $csvPath)) {
  Write-Host "[ERR] 找不到 $csvPath，请先运行一次生成模板（菜单选 1）"
  exit 1
}

$csvText = Read-CsvSmart -Path $csvPath
$rows = @($csvText | ConvertFrom-Csv)
if ($rows.Count -eq 0) {
  Write-Host "[ERR] 模板没有数据行"
  exit 1
}

$plan = @()
foreach ($row in $rows) {
  $email = "$($row.'邮箱')".Trim()
  if (-not $email) { continue }

  $newLabelRaw = "$($row.'新标签')"
  $newNoteRaw = "$($row.'新备注')"

  $labelAction = $null
  $labelValue = $null
  if ($newLabelRaw.Trim() -eq "") {
    # 保持
  }
  elseif ($newLabelRaw.Trim() -eq "-") {
    $labelAction = "clear"; $labelValue = ""
  }
  else {
    # 填了内容就执行（以填写为准，不与快照对比）
    $labelAction = "set"; $labelValue = $newLabelRaw
  }

  $noteAction = $null
  $noteValue = $null
  if ($newNoteRaw.Trim() -eq "") {
    # 保持
  }
  elseif ($newNoteRaw.Trim() -eq "-") {
    $noteAction = "clear"; $noteValue = ""
  }
  else {
    # 填了内容就执行（以填写为准，不与快照对比）
    $noteAction = "set"; $noteValue = $newNoteRaw
  }

  if ($labelAction -or $noteAction) {
    $plan += [pscustomobject]@{
      Email       = $email
      LabelAction = $labelAction
      LabelValue  = $labelValue
      NoteAction  = $noteAction
      NoteValue   = $noteValue
    }
  }
}

if ($plan.Count -eq 0) {
  Write-Host "[OK] 没有需要修改的行（新标签/新备注 均为空）"
  exit 0
}

Write-Host ""
Write-Host "将执行以下 $($plan.Count) 条修改："
foreach ($p in $plan) {
  $ld = if ($p.LabelAction -eq "clear") { "清空" } elseif ($p.LabelAction -eq "set") { "改为「$($p.LabelValue)」" } else { "保持不变" }
  $nd = if ($p.NoteAction -eq "clear") { "清空" } elseif ($p.NoteAction -eq "set") { "改为「$($p.NoteValue)」" } else { "保持不变" }
  Write-Host ("  {0}`n      标签: {1}`n      备注: {2}" -f $p.Email, $ld, $nd)
}

if ($DryRun) {
  Write-Host ""
  Write-Host "[预览模式] 未做任何修改。确认无误后运行执行（菜单 3）。"
  exit 0
}

if (-not $Yes) {
  Write-Host ""
  $confirm = Read-Host "确认执行以上 $($plan.Count) 条修改？输入 y 继续"
  if ($confirm -ne "y") { Write-Host "已取消，未做任何修改。"; exit 0 }
}

$okCount = 0
$failCount = 0
foreach ($p in $plan) {
  $cmdArgs = @("update-metadata", $p.Email)
  if ($p.LabelAction) { $cmdArgs += "--label=$($p.LabelValue)" }
  if ($p.NoteAction) { $cmdArgs += "--note=$($p.NoteValue)" }
  $cmdArgs += @("--cookie-file", $cfg.cookie_file, "--region", $cfg.region)
  if ($caps.UpdateMetadataDb) { $cmdArgs += @("--db-file", $cfg.db_file) }

  Write-Host ""
  Write-Host "== $($p.Email) =="
  Invoke-Hme $cmdArgs
  if ($LASTEXITCODE -eq 0) {
    $okCount++
    Write-Host "[OK] 已更新"
  }
  else {
    $failCount++
    Write-Host "[FAIL] 更新失败（exit=$LASTEXITCODE）"
  }
  Start-Sleep -Milliseconds 1500
}

Write-Host ""
Write-Host "完成：成功 $okCount 条，失败 $failCount 条"
if ($failCount -gt 0) { exit 1 }
