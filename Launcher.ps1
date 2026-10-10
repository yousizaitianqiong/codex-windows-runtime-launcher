param(
    [ValidateSet('Launch', 'Check', 'Repair')][string]$Mode = 'Launch',
    [switch]$NoUi
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$mutex = $null
$context = $null
$exitCode = 0
try {
    . (Join-Path $PSScriptRoot 'RuntimeLauncher.Core.ps1')
    Import-RuntimeTools $PSScriptRoot
    $context = New-RuntimeContext -ToolRoot $PSScriptRoot
    $context.NoUi = [bool]$NoUi
    $context.ReadOnly = $Mode -eq 'Check'
    $mutex = Enter-RuntimeLock $context
    $result = Invoke-RuntimeEngine $context $Mode
    $result | ConvertTo-Json -Depth 5
    if ($Mode -eq 'Check' -and -not $result.Complete) { $exitCode = 22 }
    if (-not $NoUi -and $Mode -ne 'Launch') {
        $status = if ($result.Complete) { '运行时完整。' } else { '运行时需要修复。' }
        Show-RuntimeMessage ($status + "`r`n版本：" + $result.PackageVersion + "`r`nRuntime ID：" + $result.RuntimeId + "`r`n本次复制：" + $result.Copied)
    }
} catch {
    $message = $_.Exception.Message
    $exitCode = 1
    if (Get-Command Get-LauncherExitCode -ErrorAction SilentlyContinue) { $exitCode = Get-LauncherExitCode $_.Exception }
    if ($context -and -not $context.ReadOnly -and $mutex) {
        try { Write-RuntimeLog $context 'failed' @{ Message = $message; ExitCode = $exitCode } } catch { }
    }
    [Console]::Error.WriteLine($message)
    if (-not $NoUi) {
        try { Show-RuntimeMessage ($message + "`r`n`r`n诊断目录：" + (Join-Path $PSScriptRoot 'logs')) -ErrorMessage } catch { }
    }
} finally {
    if ($mutex) { try { $mutex.ReleaseMutex() } finally { $mutex.Dispose() } }
}
exit $exitCode
