<#
  convert-cookies.ps1 — 把 Netscape 格式的 cookie 文件转成 hidemyemail 可读的格式

  适用场景：浏览器扩展导出的是 Netscape 文本（如部分 Get cookies.txt LOCALLY 版本），
            而 hidemyemail 需要单行 Cookie header 或 BASE64 格式。

  用法：
    powershell -File .\scripts\convert-cookies.ps1 -Source exported.txt -Out cookies.txt
    powershell -File .\scripts\convert-cookies.ps1 -Source exported.txt -Out cookies.txt -Base64

  说明：
    - 默认输出单行 Cookie header：name=value; name2=value2
    - -Base64 输出 HIDEMYEMAIL_COOKIE_BASE64=...（更稳，避免编码问题）
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Source,
  [string]$Out = "cookies.txt",
  [switch]$Base64
)

if (-not (Test-Path $Source)) { Write-Host "[ERR] 找不到源文件: $Source"; exit 1 }

$root = Split-Path $PSScriptRoot -Parent
if (-not [System.IO.Path]::IsPathRooted($Out)) { $Out = Join-Path $root $Out }

$pairs = @()
foreach ($line in (Get-Content $Source)) {
  if (-not $line -or $line.StartsWith("#")) { continue }
  $f = $line -split "`t"
  if ($f.Count -ge 7) {
    $name = $f[5].Trim()
    $value = $f[6].Trim()
    if ($name) { $pairs += "$name=$value" }
  }
}
if ($pairs.Count -eq 0) {
  Write-Host "[ERR] 未解析到 cookie（不是 Netscape 格式？）"
  exit 1
}

$header = $pairs -join "; "
if ($Base64) {
  $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($header))
  $content = "HIDEMYEMAIL_COOKIE_BASE64=$b64`n"
}
else {
  $content = $header + "`n"
}
[System.IO.File]::WriteAllText($Out, $content, (New-Object System.Text.UTF8Encoding $false))

Write-Host "[OK] 已写入 $Out（$($pairs.Count) 个 cookie）"
Write-Host "请确认包含：X-APPLE-WEBAUTH-TOKEN / X-APPLE-WEBAUTH-USER / X-APPLE-DS-WEB-SESSION-TOKEN"
