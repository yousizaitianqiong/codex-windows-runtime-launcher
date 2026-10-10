param([switch]$NoUi)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$mutex = $null
try {
    . (Join-Path $PSScriptRoot 'RuntimeLauncher.Core.ps1')
    Import-RuntimeTools $PSScriptRoot
    . (Join-Path $PSScriptRoot 'Deployment.ps1')
    $context = New-RuntimeContext -ToolRoot $PSScriptRoot
    $mutex = Enter-RuntimeLock $context
    $result = Undo-RuntimeInstall $context.ToolRoot (Get-RuntimeLinkFolders)
    $result | ConvertTo-Json -Depth 5
    if (-not $NoUi) {
        $message = '启动器入口和文件已回滚。正式运行时缓存及当前 ChatGPT 会话均保留。' + "`r`n备份：" + $result.Archive
        if ($result.RetainedModifiedShortcuts.Count) { $message += "`r`n以下入口安装后被修改，已保留，请按需处理：" + ($result.RetainedModifiedShortcuts -join '；') }
        Show-RuntimeMessage $message
    }
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    if (-not $NoUi) { try { Show-RuntimeMessage $_.Exception.Message -ErrorMessage } catch { } }
    exit 1
} finally { if ($mutex) { try { $mutex.ReleaseMutex() } finally { $mutex.Dispose() } } }
