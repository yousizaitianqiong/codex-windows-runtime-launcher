Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-RuntimeLinkFolders {
    return @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'))
}

function Copy-VerifiedTree {
    param([string]$Source, [string]$Destination, [string]$DestinationBoundary)
    $expected = [ChatGPTRuntimeLauncher.Files]::Inventory($Source, $true)
    [void][ChatGPTRuntimeLauncher.Files]::Within($DestinationBoundary, $Destination, $false)
    if (Test-Path -LiteralPath $Destination) { Throw-RuntimeError ('备份目标已经存在：' + $Destination) }
    Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -ErrorAction Stop
    $actual = [ChatGPTRuntimeLauncher.Files]::Inventory($Destination, $true)
    $errors = @([ChatGPTRuntimeLauncher.Files]::Compare([ChatGPTRuntimeLauncher.Files]::ToJson($expected), $actual))
    if ($errors.Count) { Throw-RuntimeError ('备份或恢复后的文件校验失败：' + ($errors -join '；')) }
}

function Install-RuntimeFiles {
    param([string]$Payload, [string]$Root, [string[]]$LinkFolders, $Package)
    $parent = Split-Path -Parent $Root
    [ChatGPTRuntimeLauncher.Files]::NoReparse($Root)
    $backupRoot = Join-Path $parent 'RuntimeLauncher.backups'
    $backup = Join-Path $backupRoot ('install-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N'))
    [void][ChatGPTRuntimeLauncher.Files]::Within($parent, $backup, $false)
    [void][IO.Directory]::CreateDirectory($backup)
    $prior = Test-Path -LiteralPath $Root -PathType Container
    if ($prior) { Copy-VerifiedTree $Root (Join-Path $backup 'previous-root') $backupRoot }
    $planned = New-Object 'System.Collections.Generic.List[object]'
    $shell = New-Object -ComObject WScript.Shell
    $index = 0
    foreach ($folder in $LinkFolders) {
        foreach ($name in @('ChatGPT（自动修复）.lnk', 'ChatGPT（回滚自动修复）.lnk')) {
            if ($folder -eq $LinkFolders[0] -and $name -eq 'ChatGPT（回滚自动修复）.lnk') { continue }
            [ChatGPTRuntimeLauncher.Files]::NoReparse($folder)
            $path = Join-Path $folder $name
            [void][ChatGPTRuntimeLauncher.Files]::Within($folder, $path, $false)
            $oldFile = Join-Path $backup ('shortcut-original-{0}.lnk' -f $index)
            $exists = Test-Path -LiteralPath $path -PathType Leaf
            if ($exists) { Copy-Item -LiteralPath $path -Destination $oldFile -ErrorAction Stop }
            $draft = Join-Path $backup ('shortcut-new-{0}.lnk' -f $index)
            $link = $shell.CreateShortcut($draft)
            $link.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $script = if ($name -eq 'ChatGPT（自动修复）.lnk') { 'Launcher.ps1' } else { 'Rollback.ps1' }
            $link.Arguments = '-NoProfile -NonInteractive -STA -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File "' + (Join-Path $Root $script) + '"'
            $link.WorkingDirectory = $Root
            $link.IconLocation = (Join-Path $Root 'chatgpt.ico') + ',0'
            $link.Description = if ($script -eq 'Launcher.ps1') { '自动检查当前安装包运行时，必要时修复，然后打开 ChatGPT。' } else { '撤销自动修复启动器的安装，保留已验证的运行时缓存。' }
            $link.Save()
            $planned.Add([pscustomobject]@{ Path = $path; Existed = $exists; Original = $oldFile; Draft = $draft; InstalledHash = [ChatGPTRuntimeLauncher.Files]::Hash($draft) })
            $index++
        }
    }
    $manifest = [pscustomobject]@{
        Schema = 1; Product = 'ChatGPTRuntimeLauncher'; Version = '1.1.1'
        Root = $Root; Backup = $backup; PreviousRoot = $prior
        InstalledAt = [DateTime]::UtcNow.ToString('o'); Links = @($planned.ToArray())
    }
    [ChatGPTRuntimeLauncher.Files]::AtomicText($backupRoot, (Join-Path $backup 'installation.json'), ($manifest | ConvertTo-Json -Depth 7))
    try {
        [void][IO.Directory]::CreateDirectory($Root)
        $files = @('RuntimeTools.cs', 'TransferTools.cs', 'RuntimeTools.dll', 'RuntimeLauncher.Core.ps1', 'Launcher.ps1', 'Deployment.ps1', 'Rollback.ps1', '使用说明.md')
        foreach ($name in $files) {
            $source = Join-Path $Payload $name
            $destination = [ChatGPTRuntimeLauncher.Files]::Within($Root, (Join-Path $Root $name), $false)
            [ChatGPTRuntimeLauncher.Files]::NoReparse($source)
            Copy-Item -LiteralPath $source -Destination $destination -Force -ErrorAction Stop
            if ([ChatGPTRuntimeLauncher.Files]::Hash($source) -ne [ChatGPTRuntimeLauncher.Files]::Hash($destination)) { Throw-RuntimeError ('安装文件校验失败：' + $name) }
        }
        $iconSource = Join-Path (Split-Path -Parent $Package.Asar) 'icon-chatgpt.ico'
        $iconTarget = [ChatGPTRuntimeLauncher.Files]::Within($Root, (Join-Path $Root 'chatgpt.ico'), $false)
        [ChatGPTRuntimeLauncher.Files]::ReadSafe($iconSource)
        [IO.File]::WriteAllBytes($iconTarget, [IO.File]::ReadAllBytes($iconSource))
        [ChatGPTRuntimeLauncher.Files]::AtomicText($Root, (Join-Path $Root 'installation.json'), ($manifest | ConvertTo-Json -Depth 7))
        foreach ($record in $manifest.Links) {
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $record.Path))
            Copy-Item -LiteralPath $record.Draft -Destination $record.Path -Force -ErrorAction Stop
            if ([ChatGPTRuntimeLauncher.Files]::Hash($record.Path) -ne $record.InstalledHash) { Throw-RuntimeError ('快捷方式校验失败：' + $record.Path) }
        }
        return $manifest
    } catch {
        $originalError = $_
        try { [void](Undo-RuntimeInstall $Root $LinkFolders $manifest) }
        catch { [Console]::Error.WriteLine('安装回滚未完全成功，备份保留在：' + $backup + '。' + $_.Exception.Message) }
        throw $originalError
    }
}

function Undo-RuntimeInstall {
    param([string]$Root, [string[]]$AllowedLinkFolders, $ManifestOverride = $null)
    $parent = Split-Path -Parent $Root
    $backupRoot = Join-Path $parent 'RuntimeLauncher.backups'
    $manifest = $ManifestOverride
    if (-not $manifest) { $manifest = Read-RuntimeJson (Join-Path $Root 'installation.json') }
    if (-not $manifest -or $manifest.Product -ne 'ChatGPTRuntimeLauncher' -or $manifest.Schema -ne 1 -or $manifest.Root -ne $Root) {
        Throw-RuntimeError '安装记录不存在或无法验证，未执行回滚。'
    }
    $backup = [ChatGPTRuntimeLauncher.Files]::Within($backupRoot, $manifest.Backup, $false)
    $allowed = @()
    foreach ($folder in $AllowedLinkFolders) {
        $allowed += Join-Path $folder 'ChatGPT（自动修复）.lnk'
        $allowed += Join-Path $folder 'ChatGPT（回滚自动修复）.lnk'
    }
    foreach ($record in $manifest.Links) {
        if ($record.Path -notin $allowed) { Throw-RuntimeError '安装记录包含预期入口以外的路径，未执行回滚。' }
        [ChatGPTRuntimeLauncher.Files]::NoReparse($record.Path)
        if ($record.Existed) {
            [void][ChatGPTRuntimeLauncher.Files]::Within($backup, $record.Original, $false)
            if (-not (Test-Path -LiteralPath $record.Original -PathType Leaf)) { Throw-RuntimeError '原快捷方式备份缺失，未执行回滚。' }
        }
    }
    if ($manifest.PreviousRoot) { [void][ChatGPTRuntimeLauncher.Files]::Inventory((Join-Path $backup 'previous-root'), $false) }
    [void][ChatGPTRuntimeLauncher.Files]::Inventory($Root, $false)
    $archive = [ChatGPTRuntimeLauncher.Files]::Within($backupRoot, (Join-Path $backupRoot ('rollback-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N'))), $false)
    [void][IO.Directory]::CreateDirectory($archive)
    $conflicts = New-Object 'System.Collections.Generic.List[string]'
    $i = 0
    foreach ($record in $manifest.Links) {
        $canRestore = $true
        if (Test-Path -LiteralPath $record.Path -PathType Leaf) {
            if ([ChatGPTRuntimeLauncher.Files]::Hash($record.Path) -eq $record.InstalledHash) {
                $destination = [ChatGPTRuntimeLauncher.Files]::Within($archive, (Join-Path $archive ('removed-shortcut-{0}.lnk' -f $i)), $false)
                [ChatGPTRuntimeLauncher.Files]::NoReparse($record.Path)
                Move-Item -LiteralPath $record.Path -Destination $destination -ErrorAction Stop
            } else { $canRestore = $false; $conflicts.Add($record.Path) }
        }
        if ($canRestore -and $record.Existed) { Copy-Item -LiteralPath $record.Original -Destination $record.Path -ErrorAction Stop }
        $i++
    }
    [void][ChatGPTRuntimeLauncher.Files]::Within($parent, $Root, $false)
    $archivedRoot = [ChatGPTRuntimeLauncher.Files]::Within($archive, (Join-Path $archive 'RuntimeLauncher'), $false)
    Move-Item -LiteralPath $Root -Destination $archivedRoot -ErrorAction Stop
    if ($manifest.PreviousRoot) { Copy-VerifiedTree (Join-Path $backup 'previous-root') $Root $parent }
    $result = [pscustomobject]@{ RestoredPreviousInstallation = [bool]$manifest.PreviousRoot; Archive = $archive; RetainedModifiedShortcuts = @($conflicts.ToArray()); RuntimeCachePreserved = $true }
    [ChatGPTRuntimeLauncher.Files]::AtomicText($archive, (Join-Path $archive 'rollback-result.json'), ($result | ConvertTo-Json -Depth 5))
    return $result
}
