<#
  inbox.ps1 v2 — 一次性配置 IMAP 收件（含登录校验与重试）
  1) 输入完整 iCloud 邮箱（必须含 @，校验格式）
  2) 粘贴应用专用密码（Ctrl+V 粘贴，输入不回显）
  3) 校验 IMAP 登录（失败可重试，最多 3 轮）
  4) 保存 hidemyemail 配置（用于同步邮件和提取验证码）

  用法：双击 inbox.bat
#>
[CmdletBinding()]
param(
  [string]$Config = "",
  [string]$ICloudEmail = ""
)


$root = Split-Path $PSScriptRoot -Parent
if (-not $Config) { $Config = Join-Path $root "config.json" }

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
# 防止 CLI（Rich/emoji）在 GBK 环境下崩溃：强制 Python 使用 UTF-8
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

# ── 1. 邮箱 ──
while (-not $ICloudEmail -or $ICloudEmail -notmatch "@") {
  Write-Host "请输入完整的 iCloud 邮箱地址（形如 xxxx@icloud.com；不是 Apple ID / QQ 邮箱）"
  $entered = Read-Host "iCloud 邮箱"
  if ($entered -and $entered -match "@") { $ICloudEmail = $entered.Trim() }
  else { Write-Host "[WARN] 必须包含 @，请重新输入。" }
}
Write-Host "使用邮箱: $ICloudEmail"

# ── 2. 密码 + 登录校验（最多 3 轮） ──
$maxTries = 3
$ok = $false
for ($try = 1; $try -le $maxTries; $try++) {
  Write-Host ""
  Write-Host "请【粘贴】应用专用密码（Ctrl+V 粘贴；输入不显示，属正常）。"
  Write-Host "若还没有：appleid.apple.com → 登录与安全 → 应用专用密码 → 生成（格式 xxxx-xxxx-xxxx-xxxx）"
  $secure = Read-Host "应用专用密码" -AsSecureString
  $plain = [System.Net.NetworkCredential]::new("", $secure).Password
  if (-not $plain) { Write-Host "[WARN] 密码为空，重试"; continue }

  Invoke-Hme @("inbox", "setup",
    "--host", "imap.mail.me.com", "--port", "993",
    "--username", $ICloudEmail, "--password", $plain, "--folder", "INBOX",
    "--config-file", $cfg.inbox_config, "--db-file", $cfg.db_file)

  Write-Host "== 校验登录（试收一次） =="
  Invoke-Hme @("inbox", "sync",
    "--config-file", $cfg.inbox_config, "--db-file", $cfg.db_file,
    "--limit", "20", "--show-codes")

  if ($LASTEXITCODE -eq 0) { $ok = $true; Write-Host "[OK] IMAP 登录成功"; break }
  Write-Host "[WARN] 登录失败（第 $try/$maxTries 次）。可能原因："
  Write-Host "   - 密码粘贴不完整 / 不是这个账号的应用专用密码"
  Write-Host "   - 邮箱地址不是 @icloud.com 结尾（Apple 要求用 iCloud 邮箱登录 IMAP）"
  Write-Host "   - 账号未开通 iCloud 邮件（iPhone 设置 → iCloud → 邮件 里可开通）"
}

if ($ok) {
  Write-Host ""
  Write-Host "全部完成 ✅  收件配置已保存：$($cfg.inbox_config)"
  Write-Host "注意：应用专用密码只保存在本机，请勿分享该文件。"
} else {
  Write-Host ""
  Write-Host "[ERR] 3 次都未通过。可稍后重新运行本脚本；如确认邮箱无误且已开通 iCloud 邮件，请在 appleid.apple.com 重新生成一个应用专用密码再试。"
}
