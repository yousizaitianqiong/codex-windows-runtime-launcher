param([string]$WorkRoot)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $WorkRoot) {
    $temporaryRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
    $WorkRoot = Join-Path $temporaryRoot 'CgRt-tests'
}
# 中文命令放在 UTF-8 BOM 文件中，避免 CI 生成的无 BOM 临时脚本被系统 PowerShell 误解码。
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -STA -ExecutionPolicy RemoteSigned -File (Join-Path $repoRoot 'tests\Test.ps1') -Payload $repoRoot -SkipLive -WorkRoot $WorkRoot
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$report = [IO.File]::ReadAllText((Join-Path $WorkRoot 'latest-tests.json')) | ConvertFrom-Json
if ($report.Passed -ne 45 -or $report.Failed -ne 0 -or $report.Skipped -ne 2) { throw '回归数量或结果不符合预期。' }
$summary = @('## Windows PowerShell 5.1 回归', '', ('通过：' + $report.Passed + '；失败：' + $report.Failed + '；跳过真实安装包用例：' + $report.Skipped), '', '未安装或启动 Codex；未执行真实包复制或冷启动测试。')
if ($env:GITHUB_STEP_SUMMARY) { $summary | Out-File -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append }
$global:LASTEXITCODE = 0
