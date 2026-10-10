Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Import-RuntimeTools {
    param([string]$Directory = $PSScriptRoot)
    if (-not ('ChatGPTRuntimeLauncher.Files' -as [type])) {
        Add-Type -AssemblyName System.Web.Extensions
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        # 从字节加载，回滚时不会因程序集文件被锁定而失败。
        [void][Reflection.Assembly]::Load([IO.File]::ReadAllBytes((Join-Path $Directory 'RuntimeTools.dll')))
    }
}

function Throw-RuntimeError {
    param([string]$Message, [int]$Code = 1)
    $exception = New-Object System.InvalidOperationException($Message)
    $exception.Data['LauncherExitCode'] = $Code
    throw $exception
}

function Get-LauncherExitCode {
    param($Exception)
    while ($Exception) {
        if ($Exception.Data.Contains('LauncherExitCode')) { return [int]$Exception.Data['LauncherExitCode'] }
        $Exception = $Exception.InnerException
    }
    return 1
}

function Get-RuntimePackage {
    $packages = @(Get-AppxPackage OpenAI.Codex -ErrorAction Stop | Where-Object { -not $_.IsResourcePackage })
    if ($packages.Count -ne 1) { Throw-RuntimeError '未找到唯一的当前用户 OpenAI.Codex 安装包。' }
    $package = $packages[0]
    $manifest = Get-AppxPackageManifest -Package $package.PackageFullName -ErrorAction Stop
    $apps = @($manifest.SelectNodes('//*[local-name()="Application"]') | Where-Object {
        $_.GetAttribute('Executable') -match '(?i)(^|[/\\])(ChatGPT|Codex)\.exe$'
    })
    if ($apps.Count -ne 1) { Throw-RuntimeError '当前包清单中的主应用入口无法唯一识别。' }
    $install = [ChatGPTRuntimeLauncher.Files]::Full($package.InstallLocation)
    [ChatGPTRuntimeLauncher.Files]::SetPackageReadRoot($install)
    $executable = [ChatGPTRuntimeLauncher.Files]::ReadWithin($install, (Join-Path $install $apps[0].GetAttribute('Executable')))
    $resources = Join-Path (Split-Path -Parent $executable) 'resources'
    $source = [ChatGPTRuntimeLauncher.Files]::ReadWithin($install, (Join-Path $resources 'cua_node'))
    $asar = [ChatGPTRuntimeLauncher.Files]::ReadWithin($install, (Join-Path $resources 'app.asar'))
    if (-not (Test-Path -LiteralPath $source -PathType Container)) { Throw-RuntimeError '当前安装包不存在预期的 cua_node 目录；已停止修复。' 20 }
    $identityParts = @($package.PackageFullName, $install)
    foreach ($file in @($asar, (Join-Path $source 'manifest.json'), (Join-Path $source 'bin\node.exe'), (Join-Path $source 'bin\node_repl.exe'))) {
        $info = Get-Item -LiteralPath $file -ErrorAction Stop
        $identityParts += ('{0}|{1}|{2}' -f $info.FullName, $info.Length, $info.LastWriteTimeUtc.Ticks)
    }
    return [pscustomobject]@{
        Version = $package.Version.ToString(); FullName = $package.PackageFullName
        Family = $package.PackageFamilyName; InstallLocation = $install
        AppId = $apps[0].GetAttribute('Id'); Executable = $executable
        SourceRoot = $source; Asar = $asar
        Identity = [ChatGPTRuntimeLauncher.Files]::HashText(($identityParts -join "`n"))
    }
}

function Get-RelatedRuntimeProcesses {
    param($Context, $Package)
    $found = New-Object 'System.Collections.Generic.List[object]'
    foreach ($process in @(Get-Process -ErrorAction Stop)) {
        if ($process.Id -eq $PID) { continue }
        $path = $null
        try { $path = $process.Path } catch { }
        $relevant = $false
        if ($path) {
            $relevant = $path.StartsWith($Context.RuntimeRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or
                ($path -match '(?i)\\WindowsApps\\OpenAI\.Codex_[^\\]+\\app\\ChatGPT\.exe$')
            if ($Package -and $path -eq $Package.Executable) { $relevant = $true }
        }
        elseif ($process.ProcessName -in @('ChatGPT', 'node_repl')) {
            # 路径不可读时保守处理，不能据此认定没有占用。
            $relevant = $true
        }
        if ($relevant) { $found.Add([pscustomobject]@{ Id = $process.Id; Name = $process.ProcessName; Path = $path }) }
    }
    return $found.ToArray()
}

function New-RuntimeContext {
    param([string]$ToolRoot, [string]$RuntimeRoot)
    if (-not $ToolRoot) { $ToolRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\RuntimeLauncher' }
    if (-not $RuntimeRoot) { $RuntimeRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\runtimes\cua_node' }
    $context = [pscustomobject]@{
        ToolRoot = [ChatGPTRuntimeLauncher.Files]::Full($ToolRoot)
        RuntimeRoot = [ChatGPTRuntimeLauncher.Files]::Full($RuntimeRoot)
        StateFile = Join-Path $ToolRoot 'state.json'
        ReadOnly = $false
        NoUi = $true
        Progress = $null
        Timings = @{}
        CopyMethod = $null
        CopyMetrics = $null
        FallbackUsed = $false
        ResolvePackage = { Get-RuntimePackage }
        ProcessProbe = { param($ctx, $pkg) Get-RelatedRuntimeProcesses $ctx $pkg }
        CopyAction = { param($src, $dst, $entriesJson, $progress)
            $job = [ChatGPTRuntimeLauncher.TransferJob]::Copy($src, $dst, $entriesJson)
            while (-not $job.Wait(100)) {
                if ($progress) { $progress.Update('正在复制并计算源摘要', $job.CompletedFiles, $job.TotalFiles) }
            }
            $job.Finish()
        }
        XcopyAction = { param($src, $dst, $entriesJson, $progress)
            $entries = [ChatGPTRuntimeLauncher.Files]::Serializer().DeserializeObject($entriesJson)
            $total = @($entries | Where-Object { -not $_.Directory }).Count
            [ChatGPTRuntimeLauncher.LegacyCopy]::Run($src, $dst, $progress, $total)
        }
        ActivateAction = { param($pkg) [ChatGPTRuntimeLauncher.Activation]::Start(($pkg.Family + '!' + $pkg.AppId)) }
        RecycleAction = { param($path)
            Add-Type -AssemblyName Microsoft.VisualBasic
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($path,
                [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin,
                [Microsoft.VisualBasic.FileIO.UICancelOption]::ThrowException)
        }
        FreeSpace = { param($path) [ChatGPTRuntimeLauncher.Files]::AvailableBytes($path) }
        Clock = { [DateTime]::UtcNow }
        VerifyAlgorithm = { param($pkg) [ChatGPTRuntimeLauncher.Algorithm]::VerifyAsar($pkg.Asar) }
    }
    return $context
}

function Add-RuntimeTiming {
    param($Context, [string]$Phase, [long]$Milliseconds)
    if (-not $Context.Timings.ContainsKey($Phase)) { $Context.Timings[$Phase] = [long]0 }
    $Context.Timings[$Phase] += $Milliseconds
}

function Update-RuntimeProgress {
    param($Context, [string]$Phase, [int]$Completed = 0, [int]$Total = 0)
    if ($Context.Progress) { $Context.Progress.Update($Phase, $Completed, $Total) }
}

function Start-RuntimeProgress {
    param($Context)
    if (-not $Context.ReadOnly -and -not $Context.Progress) {
        $Context.Progress = New-Object ChatGPTRuntimeLauncher.ProgressDisplay([bool]$Context.NoUi)
    }
}

function Invoke-RuntimeHash {
    param($Context, [string]$Root, [string]$Phase, [string]$TimingName)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    Update-RuntimeProgress $Context $Phase
    $job = [ChatGPTRuntimeLauncher.TransferJob]::HashTree($Root)
    while (-not $job.Wait(100)) { Update-RuntimeProgress $Context $Phase $job.CompletedFiles $job.TotalFiles }
    $result = $job.Finish()
    Add-RuntimeTiming $Context $TimingName $timer.ElapsedMilliseconds
    if ($result.ExitCode -ne 0) { Throw-RuntimeError ($Phase + '失败：' + $result.Output) 22 }
    Update-RuntimeProgress $Context $Phase $result.CompletedFiles $result.TotalFiles
    return $result.Entries
}

function Get-RuntimeKeys {
    param($Entries)
    foreach ($name in @('manifest.json', 'bin/node.exe', 'bin/node_repl.exe')) {
        $entry = @($Entries | Where-Object { $_.Path -ceq $name })
        if ($entry.Count -ne 1 -or $entry[0].Directory -or $entry[0].Hash -cnotmatch '^[0-9a-f]{64}$') {
            Throw-RuntimeError ('源运行时缺少有效关键文件：' + $name) 22
        }
        $entry[0].Hash
    }
}

function Get-RuntimeIdFromKeys {
    param([string[]]$Keys)
    $text = New-Object Text.StringBuilder
    $names = @('manifest.json', 'bin/node.exe', 'bin/node_repl.exe')
    for ($i = 0; $i -lt 3; $i++) { [void]$text.Append($names[$i]).Append([char]0).Append($Keys[$i]).Append([char]0) }
    return [ChatGPTRuntimeLauncher.Files]::HashText($text.ToString()).Substring(0, 16)
}

function Write-RuntimeLog {
    param($Context, [string]$Event, $Details)
    if ($Context.ReadOnly) { return }
    $now = & $Context.Clock
    $log = Join-Path $Context.ToolRoot ('logs\launcher-{0}.jsonl' -f $now.ToString('yyyy-MM-dd'))
    $record = [pscustomobject]@{ Time = $now.ToString('o'); Event = $Event; Details = $Details }
    [ChatGPTRuntimeLauncher.Files]::Append($Context.ToolRoot, $log, ($record | ConvertTo-Json -Compress -Depth 8))
}

function Read-RuntimeJson {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        [ChatGPTRuntimeLauncher.Files]::NoReparse($Path)
        $parsed = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        # PowerShell 5.1 的 ConvertFrom-Json 会保留根数组；显式返回变量以展开观察记录。
        return $parsed
    } catch { return $null }
}

function Save-RuntimeJson {
    param($Context, [string]$Path, $Value)
    if ($Context.ReadOnly) { Throw-RuntimeError '只读检查模式不能写入状态。' }
    [ChatGPTRuntimeLauncher.Files]::AtomicText($Context.ToolRoot, $Path, (ConvertTo-Json -InputObject $Value -Depth 12 -Compress))
}

function Test-RuntimeCache {
    param($State, $Package)
    if (-not $State) { return $false }
    try {
        if (@($State.Keys).Count -ne 3 -or [string]::IsNullOrEmpty($State.AlgorithmModule)) { return $false }
        $names = @('manifest.json', 'bin/node.exe', 'bin/node_repl.exe')
        $keyText = New-Object Text.StringBuilder
        for ($i = 0; $i -lt 3; $i++) {
            if ($State.Keys[$i] -cnotmatch '^[0-9a-f]{64}$') { return $false }
            [void]$keyText.Append($names[$i]).Append([char]0).Append($State.Keys[$i]).Append([char]0)
        }
        if ($State.RuntimeId -cne [ChatGPTRuntimeLauncher.Files]::HashText($keyText.ToString()).Substring(0, 16)) { return $false }
        return $State.Schema -eq 1 -and $State.Algorithm -eq [ChatGPTRuntimeLauncher.Algorithm]::Id -and
            $State.PackageIdentity -eq $Package.Identity -and $State.RuntimeId -match '^[0-9a-f]{16}$' -and
            @($State.Keys).Count -eq 3 -and @($State.SourceEntries).Count -gt 3 -and
            -not [string]::IsNullOrEmpty($State.TargetFingerprint)
    } catch { return $false }
}

function Get-RuntimeAssessment {
    param($Context, $Package)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $state = Read-RuntimeJson $Context.StateFile
    $cacheValid = Test-RuntimeCache $state $Package
    if ($cacheValid) {
        $runtimeId = $state.RuntimeId
        $sourceEntries = $state.SourceEntries
        $keys = [string[]]@($state.Keys)
        $module = $state.AlgorithmModule
        $sourceHasHashes = $true
    } else {
        Start-RuntimeProgress $Context
        Update-RuntimeProgress $Context '正在检查新版安装包'
        try { $module = & $Context.VerifyAlgorithm $Package }
        catch { Throw-RuntimeError ('无法确认当前包的 runtime ID 算法。' + $_.Exception.Message) 20 }
        $sourceEntries = [ChatGPTRuntimeLauncher.Files]::Inventory($Package.SourceRoot, $false)
        $sourceHasHashes = $false
        $keys = [string[]]@('manifest.json', 'bin/node.exe', 'bin/node_repl.exe' | ForEach-Object {
            $name = $_
            $entry = @($sourceEntries | Where-Object { $_.Path -ceq $name })
            if ($entry.Count -ne 1 -or $entry[0].Directory) { Throw-RuntimeError ('源运行时缺少关键文件：' + $name) }
            [ChatGPTRuntimeLauncher.Files]::Hash((Join-Path $Package.SourceRoot $name))
        })
        $runtimeId = Get-RuntimeIdFromKeys $keys
    }
    $target = [ChatGPTRuntimeLauncher.Files]::Within($Context.RuntimeRoot, (Join-Path $Context.RuntimeRoot $runtimeId), $false)
    $complete = $false; $fast = $false; $fingerprint = ''; $errors = @('正式运行时不存在。')
    if (Test-Path -LiteralPath $target -PathType Container) {
        $inventory = [ChatGPTRuntimeLauncher.Files]::Inventory($target, $false)
        $fingerprint = [ChatGPTRuntimeLauncher.Files]::Fingerprint($inventory)
        if ($cacheValid -and $fingerprint -eq $state.TargetFingerprint -and [ChatGPTRuntimeLauncher.Files]::VerifyKeys($target, $keys)) {
            $complete = $true; $fast = $true; $errors = @()
        } else {
            Start-RuntimeProgress $Context
            # 只有已有目标需要完整比对时，才额外全量读取源；缺失目标由复制同步取得摘要。
            if (-not $sourceHasHashes) {
                $sourceEntries = @(Invoke-RuntimeHash $Context $Package.SourceRoot '正在核验安装包' 'AssessmentSourceHashMs')
                $sourceHasHashes = $true
                if ((Get-RuntimeIdFromKeys (Get-RuntimeKeys $sourceEntries)) -ne $runtimeId) { Throw-RuntimeError '检查期间源关键文件发生变化。' 12 }
            }
            $inventory = @(Invoke-RuntimeHash $Context $target '正在核验已有运行时' 'AssessmentTargetHashMs')
            $expectedJson = ConvertTo-Json -InputObject @($sourceEntries) -Depth 5 -Compress
            $errors = @([ChatGPTRuntimeLauncher.Files]::Compare($expectedJson, $inventory))
            $complete = $errors.Count -eq 0
            $fingerprint = [ChatGPTRuntimeLauncher.Files]::Fingerprint($inventory)
        }
    }
    Add-RuntimeTiming $Context 'AssessmentMs' $timer.ElapsedMilliseconds
    return [pscustomobject]@{
        RuntimeId = $runtimeId; Target = $target; Complete = $complete; Fast = $fast
        SourceEntries = @($sourceEntries); Keys = $keys; Fingerprint = $fingerprint
        AlgorithmModule = $module; Errors = $errors
        SourceHasHashes = $sourceHasHashes
    }
}

function Save-RuntimeAssessment {
    param($Context, $Package, $Assessment)
    if (-not $Assessment.Complete) { Throw-RuntimeError '拒绝为不完整的运行时保存成功状态。' }
    $state = [pscustomobject]@{
        Schema = 1; Algorithm = [ChatGPTRuntimeLauncher.Algorithm]::Id
        AlgorithmModule = $Assessment.AlgorithmModule
        PackageIdentity = $Package.Identity; PackageFullName = $Package.FullName
        PackageVersion = $Package.Version; RuntimeId = $Assessment.RuntimeId
        Keys = $Assessment.Keys; SourceEntries = $Assessment.SourceEntries
        TargetFingerprint = $Assessment.Fingerprint; VerifiedAt = (& $Context.Clock).ToString('o')
    }
    Save-RuntimeJson $Context $Context.StateFile $state
}

function Assert-NoRuntimeProcesses {
    param($Context, $Package)
    $processes = @(& $Context.ProcessProbe $Context $Package)
    if ($processes.Count) {
        Throw-RuntimeError ('需要修复运行时，但检测到已有 ChatGPT 或运行时进程。请保存工作并正常退出应用，再点击“ChatGPT（自动修复）”。本工具不会强制结束会话。进程：' + (($processes | ForEach-Object { $_.Id }) -join ', ')) 10
    }
}

function Invoke-RuntimeRepair {
    param($Context, $Package, $Assessment)
    Assert-NoRuntimeProcesses $Context $Package
    Start-RuntimeProgress $Context
    $required = [long]0
    foreach ($entry in $Assessment.SourceEntries) { if (-not $entry.Directory) { $required += [long]$entry.Length } }
    $available = [long](& $Context.FreeSpace $Context.ToolRoot)
    if ($available -lt ($required + 64MB)) { Throw-RuntimeError '可用磁盘空间不足，复制尚未开始。请至少腾出运行时大小加 64 MB 的空间。' 21 }
    $stage = Join-Path $Context.ToolRoot ('pending\' + [Guid]::NewGuid().ToString('N'))
    [void][ChatGPTRuntimeLauncher.Files]::Within($Context.ToolRoot, $stage, $false)
    [void][IO.Directory]::CreateDirectory($stage)
    $published = $false; $backup = $null
    $failedCopies = New-Object 'System.Collections.Generic.List[string]'
    $repairTimer = [Diagnostics.Stopwatch]::StartNew()
    try {
        Write-RuntimeLog $Context 'copy_started' @{ Package = $Package.FullName; RuntimeId = $Assessment.RuntimeId; Staging = $stage; Bytes = $required }
        Update-RuntimeProgress $Context '正在复制并计算源摘要' 0 (@($Assessment.SourceEntries | Where-Object { -not $_.Directory }).Count)
        $entriesJson = ConvertTo-Json -InputObject @($Assessment.SourceEntries) -Depth 5 -Compress
        $copyTimer = [Diagnostics.Stopwatch]::StartNew()
        $copy = & $Context.CopyAction $Package.SourceRoot $stage $entriesJson $Context.Progress
        Add-RuntimeTiming $Context 'StreamCopyMs' $copyTimer.ElapsedMilliseconds
        if ($copy.ExitCode -ne 0) {
            $compatibilityFailure = $copy.PSObject.Properties['CompatibilityFailure'] -and $copy.CompatibilityFailure
            $origin = if ($copy.PSObject.Properties['FailureOrigin']) { $copy.FailureOrigin } else { 'Unknown' }
            if ($origin -eq 'SourceChanged') { Throw-RuntimeError ('复制期间源包发生变化：' + $copy.Output) 12 }
            if (-not $compatibilityFailure -or $origin -ne 'SourceRead') {
                Throw-RuntimeError ('文件流复制失败（' + $origin + '）：' + $copy.Output) 21
            }
            if ($Context.FallbackUsed) { Throw-RuntimeError '本次启动已执行过一次兼容回退，未再次启动 xcopy。' 21 }
            $Context.FallbackUsed = $true
            # CopyAction 返回前已经等待全部工作任务结束。将失败副本隔离，回退只执行一次。
            $quarantine = Join-Path $Context.ToolRoot ('failed-copies\' + [Guid]::NewGuid().ToString('N'))
            [void][ChatGPTRuntimeLauncher.Files]::Within($Context.ToolRoot, $quarantine, $false)
            [void][ChatGPTRuntimeLauncher.Files]::Inventory($stage, $false)
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $quarantine))
            [IO.Directory]::Move($stage, $quarantine)
            $failedCopies.Add($quarantine)
            Write-RuntimeLog $Context 'stream_read_fallback' @{ Origin = $copy.FailureOrigin; Error = $copy.Output; Quarantined = $quarantine }
            if ([long](& $Context.FreeSpace $Context.ToolRoot) -lt ($required + 64MB)) {
                Throw-RuntimeError '兼容回退前磁盘空间不足，未启动 xcopy。' 21
            }
            $stage = Join-Path $Context.ToolRoot ('pending\' + [Guid]::NewGuid().ToString('N'))
            [void][ChatGPTRuntimeLauncher.Files]::Within($Context.ToolRoot, $stage, $false)
            [void][IO.Directory]::CreateDirectory($stage)
            if (-not $Assessment.SourceHasHashes) {
                $Assessment.SourceEntries = @(Invoke-RuntimeHash $Context $Package.SourceRoot '正在核验兼容复制的源文件' 'FallbackSourceHashMs')
                $Assessment.SourceHasHashes = $true
            }
            if ((Get-RuntimeIdFromKeys (Get-RuntimeKeys $Assessment.SourceEntries)) -ne $Assessment.RuntimeId) {
                Throw-RuntimeError '兼容回退前源关键文件发生变化。' 12
            }
            $entriesJson = ConvertTo-Json -InputObject @($Assessment.SourceEntries) -Depth 5 -Compress
            $copyTimer.Restart()
            $copy = & $Context.XcopyAction $Package.SourceRoot $stage $entriesJson $Context.Progress
            Add-RuntimeTiming $Context 'FallbackCopyMs' $copyTimer.ElapsedMilliseconds
            if ($copy.ExitCode -ne 0) { Throw-RuntimeError ('兼容 xcopy 复制失败，退出码 ' + $copy.ExitCode + '。' + $copy.Output) 21 }
        }
        $Context.CopyMethod = if ($copy.PSObject.Properties['Method']) { $copy.Method } else { 'custom' }
        $Context.CopyMetrics = [pscustomobject]@{ Method = $Context.CopyMethod }
        if ($copy.PSObject.Properties['MaxActiveWorkers']) {
            $Context.CopyMetrics = [pscustomobject]@{ Method = $Context.CopyMethod; MaxActiveWorkers = $copy.MaxActiveWorkers; BufferBytes = $copy.BufferBytes; TotalFiles = $copy.TotalFiles }
        }
        if ($copy.PSObject.Properties['Entries'] -and @($copy.Entries).Count -gt 3) {
            if ($Assessment.SourceHasHashes -and @([ChatGPTRuntimeLauncher.Files]::Compare($entriesJson, $copy.Entries)).Count) {
                Throw-RuntimeError '复制源摘要与先前源清单不一致。' 12
            }
            $Assessment.SourceEntries = @($copy.Entries)
            $Assessment.SourceHasHashes = $true
        } elseif (-not $Assessment.SourceHasHashes) {
            $Assessment.SourceEntries = @(Invoke-RuntimeHash $Context $Package.SourceRoot '正在核验复制源文件' 'FallbackSourceHashMs')
            $Assessment.SourceHasHashes = $true
        }
        if ((Get-RuntimeIdFromKeys (Get-RuntimeKeys $Assessment.SourceEntries)) -ne $Assessment.RuntimeId) {
            Throw-RuntimeError '复制期间源关键文件摘要发生变化。' 12
        }
        Write-RuntimeLog $Context 'copy_finished' @{ RuntimeId = $Assessment.RuntimeId; Metrics = $Context.CopyMetrics; Timings = $Context.Timings }
        $copied = @(Invoke-RuntimeHash $Context $stage '正在独立校验目标文件' 'TargetVerifyMs')
        $expectedJson = ConvertTo-Json -InputObject @($Assessment.SourceEntries) -Depth 5 -Compress
        $errors = @([ChatGPTRuntimeLauncher.Files]::Compare($expectedJson, $copied))
        if ($errors.Count) {
            Throw-RuntimeError ('复制后的完整性校验失败：' + ($errors -join '；')) 22
        }
        $latest = & $Context.ResolvePackage
        if ($latest.Identity -ne $Package.Identity) { Throw-RuntimeError '复制期间安装包发生变化，将重新检测。' 12 }
        Assert-NoRuntimeProcesses $Context $Package
        Update-RuntimeProgress $Context '正在发布已验证的运行时' $copied.Count $copied.Count
        $publishTimer = [Diagnostics.Stopwatch]::StartNew()
        [void][ChatGPTRuntimeLauncher.Files]::Within($Context.RuntimeRoot, $Assessment.Target, $false)
        [void][ChatGPTRuntimeLauncher.Files]::Within($Context.ToolRoot, $stage, $false)
        [void][IO.Directory]::CreateDirectory($Context.RuntimeRoot)
        if (Test-Path -LiteralPath $Assessment.Target) {
            # 发布前再次完整检查；同时完成的有效目标直接复用。
            $existing = @(Invoke-RuntimeHash $Context $Assessment.Target '正在复核同时出现的目标' 'ConcurrentTargetVerifyMs')
            if (@([ChatGPTRuntimeLauncher.Files]::Compare($expectedJson, $existing)).Count -eq 0) {
                $Assessment.Complete = $true
                $Assessment.Fingerprint = [ChatGPTRuntimeLauncher.Files]::Fingerprint($existing)
                Add-RuntimeTiming $Context 'PublishMs' $publishTimer.ElapsedMilliseconds
                return
            }
            $backup = Join-Path $Context.ToolRoot ('runtime-backups\' + $Assessment.RuntimeId + '-' + [Guid]::NewGuid().ToString('N'))
            [void][ChatGPTRuntimeLauncher.Files]::Within($Context.ToolRoot, $backup, $false)
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $backup))
            Write-RuntimeLog $Context 'runtime_backup' @{ Original = $Assessment.Target; Backup = $backup }
            [IO.Directory]::Move($Assessment.Target, $backup)
        }
        try {
            # 源和目标都在当前用户 LOCALAPPDATA 的同一卷，目录发布采用重命名。
            [IO.Directory]::Move($stage, $Assessment.Target)
            $published = $true
        } catch {
            if ($backup -and -not (Test-Path -LiteralPath $Assessment.Target)) {
                [void][ChatGPTRuntimeLauncher.Files]::Within($Context.ToolRoot, $backup, $false)
                [void][ChatGPTRuntimeLauncher.Files]::Within($Context.RuntimeRoot, $Assessment.Target, $false)
                [IO.Directory]::Move($backup, $Assessment.Target)
            }
            throw
        }
        $Assessment.Complete = $true
        $Assessment.Fingerprint = [ChatGPTRuntimeLauncher.Files]::Fingerprint([ChatGPTRuntimeLauncher.Files]::Inventory($Assessment.Target, $false))
        Add-RuntimeTiming $Context 'PublishMs' $publishTimer.ElapsedMilliseconds
        Write-RuntimeLog $Context 'copy_verified' @{ RuntimeId = $Assessment.RuntimeId; Target = $Assessment.Target; Backup = $backup; Timings = $Context.Timings; CopyAndVerifyMs = $repairTimer.ElapsedMilliseconds }
    } finally {
        if (-not $published -and (Test-Path -LiteralPath $stage -PathType Container)) { $failedCopies.Add($stage) }
        foreach ($failed in $failedCopies) {
            # 失败副本不是正式 runtime。仍只送回收站，不永久删除。
            try {
                [void][ChatGPTRuntimeLauncher.Files]::Within($Context.ToolRoot, $failed, $false)
                [void][ChatGPTRuntimeLauncher.Files]::Inventory($failed, $false)
                & $Context.RecycleAction $failed
                Write-RuntimeLog $Context 'temporary_copy_recycled' @{ Path = $failed }
            } catch { Write-RuntimeLog $Context 'temporary_copy_retained' @{ Path = $failed; Error = $_.Exception.Message } }
        }
        Add-RuntimeTiming $Context 'RepairMs' $repairTimer.ElapsedMilliseconds
    }
}

function Invoke-ConservativeStagingCleanup {
    param($Context, $Package)
    if ($Context.ReadOnly -or -not (Test-Path -LiteralPath $Context.RuntimeRoot -PathType Container)) { return }
    # 运行中的应用可能继续写 staging；占用时不深入读取目录，也不改写观察记录。
    if (@(& $Context.ProcessProbe $Context $Package).Count) { return }
    $observationPath = Join-Path $Context.ToolRoot 'staging-observations.json'
    $old = Read-RuntimeJson $observationPath
    $previous = @{}
    if ($old) { foreach ($row in @($old)) { if ($row.Name -cmatch '^\.staging-[0-9a-f]{16}-[A-Za-z0-9_-]+$') { $previous[$row.Name] = $row } } }
    $now = & $Context.Clock
    $directories = @(Get-ChildItem -LiteralPath $Context.RuntimeRoot -Directory -Force | Where-Object { $_.Name -cmatch '^\.staging-[0-9a-f]{16}-[A-Za-z0-9_-]+$' })
    $present = @{}
    $candidates = @(foreach ($directory in $directories) {
        $present[$directory.Name] = $true
        if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        $recent = [Math]::Max($directory.CreationTimeUtc.Ticks, $directory.LastWriteTimeUtc.Ticks)
        if (($now.Ticks - $recent) -lt [TimeSpan]::FromDays(7).Ticks) { continue }
        $observed = [DateTime]::MinValue
        if ($previous.ContainsKey($directory.Name)) {
            try { $observed = [DateTime]::Parse($previous[$directory.Name].ObservedAt).ToUniversalTime() } catch { }
        }
        [pscustomobject]@{ Directory = $directory; ObservedAt = $observed }
    })
    foreach ($name in @($previous.Keys)) { if (-not $present.ContainsKey($name)) { $previous.Remove($name) } }
    $candidate = @($candidates | Sort-Object ObservedAt, @{ Expression = { $_.Directory.Name } } | Select-Object -First 1)
    if ($candidate.Count) {
        $directory = $candidate[0].Directory
        try {
            $path = [ChatGPTRuntimeLauncher.Files]::Within($Context.RuntimeRoot, $directory.FullName, $false)
            if ((Split-Path -Parent $path) -ne $Context.RuntimeRoot) { throw '候选不在 runtime 根的直接子目录内。' }
            $inventory = [ChatGPTRuntimeLauncher.Files]::Inventory($path, $false)
            $fingerprint = [ChatGPTRuntimeLauncher.Files]::Fingerprint($inventory)
            $latestTicks = [Math]::Max($directory.CreationTimeUtc.Ticks, $directory.LastWriteTimeUtc.Ticks)
            foreach ($entry in $inventory) { $latestTicks = [Math]::Max($latestTicks, [Math]::Max($entry.Created, $entry.Modified)) }
            $seen = $now
            if ($previous.ContainsKey($directory.Name) -and $previous[$directory.Name].Fingerprint -eq $fingerprint) {
                $seen = [DateTime]::Parse($previous[$directory.Name].StableSince).ToUniversalTime()
            }
            $eligible = ($now.Ticks - $latestTicks) -ge [TimeSpan]::FromDays(7).Ticks -and ($now - $seen).TotalHours -ge 24
            if ($eligible -and @(& $Context.ProcessProbe $Context $Package).Count -eq 0) {
                # 回收前再拍一次快照，出现新文件或占用则留待下次。
                $again = [ChatGPTRuntimeLauncher.Files]::Inventory($path, $false)
                if ([ChatGPTRuntimeLauncher.Files]::Fingerprint($again) -eq $fingerprint -and @(& $Context.ProcessProbe $Context $Package).Count -eq 0) {
                    [void][ChatGPTRuntimeLauncher.Files]::Within($Context.RuntimeRoot, $path, $false)
                    Write-RuntimeLog $Context 'staging_recycle_requested' @{ Path = $path; Fingerprint = $fingerprint }
                    & $Context.RecycleAction $path
                    Write-RuntimeLog $Context 'staging_recycled' @{ OriginalPath = $path }
                    $previous.Remove($directory.Name)
                    $directory = $null
                }
            }
            if ($directory) {
                $previous[$directory.Name] = [pscustomobject]@{ Name = $directory.Name; Fingerprint = $fingerprint; StableSince = $seen.ToString('o'); ObservedAt = $now.ToString('o') }
            }
        } catch {
            # 扫描失败仍更新时间，避免同一坏目录长期阻塞其他候选。
            $name = $candidate[0].Directory.Name
            $retained = if ($previous.ContainsKey($name)) { $previous[$name] } else { [pscustomobject]@{ Name = $name; Fingerprint = ''; StableSince = $now.ToString('o'); ObservedAt = $now.ToString('o') } }
            $retained.ObservedAt = $now.ToString('o')
            $previous[$name] = $retained
            Write-RuntimeLog $Context 'staging_skipped' @{ Name = $name; Error = $_.Exception.Message }
        }
    }
    $records = @($previous.Values | Sort-Object Name)
    $before = ConvertTo-Json -InputObject @($old) -Depth 5 -Compress
    $after = ConvertTo-Json -InputObject $records -Depth 5 -Compress
    if ($before -ne $after) { Save-RuntimeJson $Context $observationPath $records }
}

function Invoke-RuntimeEngine {
    param($Context, [ValidateSet('Launch', 'Check', 'Repair')][string]$Mode = 'Launch')
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $Context.ReadOnly = $Mode -eq 'Check'
    $Context.Timings = @{}
    $Context.CopyMethod = $null
    $Context.CopyMetrics = $null
    $Context.FallbackUsed = $false
    [ChatGPTRuntimeLauncher.Files]::NoReparse($Context.ToolRoot)
    [ChatGPTRuntimeLauncher.Files]::NoReparse($Context.RuntimeRoot)
    $copied = $false
    try {
      for ($attempt = 0; $attempt -lt 2; $attempt++) {
        try {
        $resolveTimer = [Diagnostics.Stopwatch]::StartNew()
        $package = & $Context.ResolvePackage
        Add-RuntimeTiming $Context 'ResolvePackageMs' $resolveTimer.ElapsedMilliseconds
        $assessment = Get-RuntimeAssessment $Context $package
        if ($Mode -eq 'Check') {
            return [pscustomobject]@{ Mode = $Mode; Complete = $assessment.Complete; PackageVersion = $package.Version; RuntimeId = $assessment.RuntimeId; Target = $assessment.Target; FastPath = $assessment.Fast; Copied = $false; Errors = $assessment.Errors; ElapsedMs = $timer.ElapsedMilliseconds; Timings = $Context.Timings }
        }
            if (-not $assessment.Complete) { Invoke-RuntimeRepair $Context $package $assessment; $copied = $true }
            $resolveTimer.Restart()
            $latest = & $Context.ResolvePackage
            Add-RuntimeTiming $Context 'ResolvePackageMs' $resolveTimer.ElapsedMilliseconds
            if ($latest.Identity -ne $package.Identity) { Throw-RuntimeError '发布前后安装包发生变化。' 12 }
            if (-not $assessment.Fast -or $copied) { Save-RuntimeAssessment $Context $package $assessment }
            break
        } catch {
            if ((Get-LauncherExitCode $_.Exception) -eq 12 -and $attempt -eq 0) {
                Write-RuntimeLog $Context 'package_changed_retry' @{ Message = $_.Exception.Message }
                continue
            }
            throw
        }
      }
    $cleanupTimer = [Diagnostics.Stopwatch]::StartNew()
    try { Invoke-ConservativeStagingCleanup $Context $package }
    catch { Write-RuntimeLog $Context 'cleanup_deferred' @{ Error = $_.Exception.Message } }
    Add-RuntimeTiming $Context 'CleanupMs' $cleanupTimer.ElapsedMilliseconds
    $preflightMs = $timer.ElapsedMilliseconds
    $activatedPid = $null
    Update-RuntimeProgress $Context '正在打开应用'
    $activationTimer = [Diagnostics.Stopwatch]::StartNew()
    if ($Mode -eq 'Launch') { $activatedPid = & $Context.ActivateAction $package }
    Add-RuntimeTiming $Context 'ActivationMs' $activationTimer.ElapsedMilliseconds
    $result = [pscustomobject]@{
        Mode = $Mode; Complete = $assessment.Complete; PackageVersion = $package.Version
        RuntimeId = $assessment.RuntimeId; Target = $assessment.Target; FastPath = $assessment.Fast
        Copied = $copied; ActivatedProcessId = $activatedPid; PreflightMs = $preflightMs; ElapsedMs = $timer.ElapsedMilliseconds
        CopyMethod = $Context.CopyMethod; CopyMetrics = $Context.CopyMetrics; Timings = $Context.Timings
    }
    Write-RuntimeLog $Context 'completed' $result
    return $result
    } finally {
        if ($Context.Progress) { $Context.Progress.Dispose(); $Context.Progress = $null }
    }
}

function Enter-RuntimeLock {
    param($Context)
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $name = 'Local\ChatGPT.RuntimeLauncher.' + $sid + '.' + [ChatGPTRuntimeLauncher.Files]::HashText($Context.ToolRoot).Substring(0, 16)
    $mutex = New-Object Threading.Mutex($false, $name)
    try {
        try { $entered = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $entered = $true }
        if (-not $entered) { Throw-RuntimeError '另一个启动器正在检查或修复，请等待它完成。没有启动第二次复制。' 11 }
        return $mutex
    } catch { $mutex.Dispose(); throw }
}

function Show-RuntimeMessage {
    param([string]$Message, [string]$Title = 'ChatGPT 自动修复启动器', [switch]$ErrorMessage)
    Add-Type -AssemblyName System.Windows.Forms
    $icon = if ($ErrorMessage) { [Windows.Forms.MessageBoxIcon]::Warning } else { [Windows.Forms.MessageBoxIcon]::Information }
    [void][Windows.Forms.MessageBox]::Show($Message, $Title, [Windows.Forms.MessageBoxButtons]::OK, $icon)
}
