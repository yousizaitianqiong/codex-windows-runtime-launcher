param([switch]$NoUi)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$mutex = $null
try {
    if ($PSVersionTable.PSVersion.Major -ne 5) { throw '请使用安装.cmd，以系统 PowerShell 5.1 安装。' }
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'RuntimeTools.dll') -PathType Leaf)) {
        # 源码下载不携带 DLL；用独立的系统 PowerShell 编译，避免程序集加载冲突。
        & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File (Join-Path $PSScriptRoot 'Build.ps1') | Out-Null
        if ($LASTEXITCODE -ne 0) { throw '辅助 DLL 编译失败，安装尚未开始。请查看 Build.ps1 的错误。' }
    }
    . (Join-Path $PSScriptRoot 'RuntimeLauncher.Core.ps1')
    Import-RuntimeTools $PSScriptRoot
    . (Join-Path $PSScriptRoot 'Deployment.ps1')
    $context = New-RuntimeContext
    $context.NoUi = [bool]$NoUi
    $mutex = Enter-RuntimeLock $context
    $package = Get-RuntimePackage
    $manifest = Install-RuntimeFiles $PSScriptRoot $context.ToolRoot (Get-RuntimeLinkFolders) $package
    $preparation = $null
    $warning = $null
    try { $preparation = Invoke-RuntimeEngine $context 'Repair' }
    catch { $warning = $_.Exception.Message; Write-RuntimeLog $context 'installed_preparation_deferred' @{ Message = $warning } }
    [pscustomobject]@{ Installed = $true; Root = $context.ToolRoot; Shortcuts = @($manifest.Links.Path); Preparation = $preparation; Warning = $warning; Backup = $manifest.Backup } | ConvertTo-Json -Depth 6
    if (-not $NoUi) {
        $message = '已安装。以后点击桌面的“ChatGPT（自动修复）”即可。当前会话没有被结束。'
        if ($warning) { $message += "`r`n`r`n" + $warning }
        Show-RuntimeMessage $message
    }
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    if (-not $NoUi) { try { Show-RuntimeMessage $_.Exception.Message -ErrorMessage } catch { } }
    exit 1
} finally { if ($mutex) { try { $mutex.ReleaseMutex() } finally { $mutex.Dispose() } } }
