param([string]$Payload, [string]$ToolRoot)
$ErrorActionPreference = 'Stop'
. (Join-Path $Payload 'RuntimeLauncher.Core.ps1')
Import-RuntimeTools $Payload
$context = New-RuntimeContext -ToolRoot $ToolRoot -RuntimeRoot (Join-Path (Split-Path -Parent $ToolRoot) 'runtimes\cua_node')
try {
    $mutex = Enter-RuntimeLock $context
    $mutex.ReleaseMutex(); $mutex.Dispose()
    exit 0
} catch { exit (Get-LauncherExitCode $_.Exception) }
