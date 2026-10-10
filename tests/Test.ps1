param([string]$Payload, [switch]$SkipLive, [string]$WorkRoot, [string]$NamePattern = '*')
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
if (-not $Payload) { $Payload = Split-Path -Parent $PSScriptRoot }
. (Join-Path $Payload 'RuntimeLauncher.Core.ps1')
Import-RuntimeTools $Payload
. (Join-Path $Payload 'Deployment.ps1')
$script:Results = New-Object 'System.Collections.Generic.List[object]'
$reportRoot = if ($WorkRoot) { $WorkRoot } else { Join-Path ([IO.Path]::GetTempPath()) ('CgRt-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)) }
[void][IO.Directory]::CreateDirectory($reportRoot)
$script:RunRoot = Join-Path $reportRoot ('run-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
[void][IO.Directory]::CreateDirectory($script:RunRoot)

function Assert-True { param($Condition, [string]$Message) if (-not $Condition) { throw $Message } }
function Assert-Throws {
    param([scriptblock]$Action, [int]$Code)
    try { & $Action | Out-Null } catch {
        if ($Code -gt 0) { Assert-True ((Get-LauncherExitCode $_.Exception) -eq $Code) ('退出码错误：' + $_.Exception.Message) }
        return
    }
    throw '预期操作失败，但实际成功。'
}
function Test-Case {
    param([string]$Name, [scriptblock]$Action)
    if ($Name -notlike $NamePattern) { return }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    if ($SkipLive -and $Name -in @('当前 ASAR 算法与实际正式目录吻合', '受保护源文件 xcopy G 的真实隔离复制')) {
        $script:Results.Add([pscustomobject]@{ Name = $Name; Passed = $null; Skipped = $true; Reason = '显式指定 SkipLive；此运行不检查用户注册的真实 MSIX 和正式 runtime。' })
        Write-Output ('跳过真实安装包测试：' + $Name)
        return
    }
    try { & $Action; $script:Results.Add([pscustomobject]@{ Name = $Name; Passed = $true; Skipped = $false; Milliseconds = $timer.ElapsedMilliseconds }); Write-Output ('通过：' + $Name) }
    catch { $script:Results.Add([pscustomobject]@{ Name = $Name; Passed = $false; Skipped = $false; Milliseconds = $timer.ElapsedMilliseconds; Error = $_.Exception.Message; Position = $_.ScriptStackTrace }); Write-Output ('失败：' + $Name + '：' + $_.Exception.Message) }
}
function New-Fixture {
    $root = Join-Path $script:RunRoot ([Guid]::NewGuid().ToString('N').Substring(0, 12))
    $source = Join-Path $root 'source'
    foreach ($dir in @('bin\node_modules\module', 'bin\node_modules\empty')) { [void][IO.Directory]::CreateDirectory((Join-Path $source $dir)) }
    foreach ($item in @(@('manifest.json','{"version":"one"}'), @('bin\node.exe','测试 Node 内容'), @('bin\node_repl.exe','测试 REPL 内容'), @('bin\node_modules\module\index.js','module contents'))) {
        [IO.File]::WriteAllText((Join-Path $source $item[0]), $item[1], [Text.UTF8Encoding]::new($false))
    }
    $package = [pscustomobject]@{ Version = '1.0.0'; FullName = 'OpenAI.Codex_1.0.0_x64__test'; Family = 'OpenAI.Codex_test'; AppId = 'App'; Executable = (Join-Path $root 'ChatGPT.exe'); InstallLocation = $root; SourceRoot = $source; Asar = (Join-Path $root 'app.asar'); Identity = 'identity-one' }
    $ctx = New-RuntimeContext -ToolRoot (Join-Path $root 'RuntimeLauncher') -RuntimeRoot (Join-Path $root 'runtimes\cua_node')
    $box = [pscustomobject]@{ Root = $root; Context = $ctx; Package = $package; Copies = 0; Activations = 0; Recycled = 0; Resolves = 0; Now = [DateTime]::UtcNow; Processes = @() }
    $ctx.ResolvePackage = { $box.Resolves++; $box.Package }.GetNewClosure()
    $ctx.ProcessProbe = { param($a, $b) $box.Processes }.GetNewClosure()
    $copy = $ctx.CopyAction
    $ctx.CopyAction = { param($src, $dst, $entriesJson, $progress) $box.Copies++; & $copy $src $dst $entriesJson $progress }.GetNewClosure()
    $ctx.ActivateAction = { param($pkg) $box.Activations++; 123 }.GetNewClosure()
    $ctx.Clock = { $box.Now }.GetNewClosure()
    $ctx.FreeSpace = { param($path) [long]10GB }
    $ctx.VerifyAlgorithm = { param($pkg) '隔离测试：已知算法' }
    $ctx.RecycleAction = { param($path)
        [void][ChatGPTRuntimeLauncher.Files]::Within($box.Root, $path, $false)
        $target = Join-Path $box.Root ('recycled-' + [Guid]::NewGuid().ToString('N'))
        [void][ChatGPTRuntimeLauncher.Files]::Within($box.Root, $target, $false)
        Move-Item -LiteralPath $path -Destination $target -ErrorAction Stop
        $box.Recycled++
    }.GetNewClosure()
    return $box
}
function New-AgedStaging {
    param($Box, [string]$Suffix = 'old')
    $path = Join-Path $Box.Context.RuntimeRoot ('.staging-1234567890abcdef-' + $Suffix)
    [void][IO.Directory]::CreateDirectory($path)
    [IO.Directory]::SetCreationTimeUtc($path, $Box.Now.AddDays(-14))
    [IO.Directory]::SetLastWriteTimeUtc($path, $Box.Now.AddDays(-14))
    return $path
}

Test-Case '当前 ASAR 算法与实际正式目录吻合' {
    $pkg = Get-RuntimePackage
    $module = [ChatGPTRuntimeLauncher.Algorithm]::VerifyAsar($pkg.Asar)
    $rid = [ChatGPTRuntimeLauncher.Files]::RuntimeId($pkg.SourceRoot)
    Assert-True ($module.EndsWith('.js')) '未找到算法模块。'
    Assert-True (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA ('OpenAI\Codex\runtimes\cua_node\' + $rid))) '独立算法未匹配现有正式目录。'
}
Test-Case '只读检查不创建目录或状态' {
    $f = New-Fixture
    $result = Invoke-RuntimeEngine $f.Context 'Check'
    Assert-True (-not $result.Complete) '空目标应不完整。'
    Assert-True (-not (Test-Path -LiteralPath $f.Context.ToolRoot)) '只读检查产生了文件。'
    Assert-True ($f.Copies -eq 0 -and $f.Activations -eq 0) '只读检查执行了修复或启动。'
}
Test-Case '算法保护拒绝摘要、顺序、分隔符和截断变化' {
    $code = 'var a=[`manifest.json`,`bin/node.exe`,`bin/node_repl.exe`].map(e=>rec({destinationPath:n,executableName:e,sourcePath:(0,o.join)(t,e)})),s=combine(a).slice(0,16);function combine(e){let t=(0,h.createHash)(`sha256`);for(let n of e)t.update(n.executableName),t.update(`\0`),t.update(n.digest),t.update(`\0`);return t.digest(`hex`)}function rec(e){let r=(0,i.statSync)(e);return{digest:hash(e),sourcePath:e}}function hash(e){return(0,h.createHash)(`sha256`).update((0,i.readFileSync)(e)).digest(`hex`)}'
    Assert-True ([ChatGPTRuntimeLauncher.Algorithm]::VerifyCode($code)) '基准算法未识别。'
    foreach ($modified in @($code.Replace('sha256','sha512'), $code.Replace('bin/node.exe','bin/other.exe'), $code.Replace('\0','\n'), $code.Replace('.slice(0,16)','.slice(0,32)'))) {
        Assert-True (-not [ChatGPTRuntimeLauncher.Algorithm]::VerifyCode($modified)) '接受了变更的算法。'
    }
    Assert-True ([ChatGPTRuntimeLauncher.Algorithm]::VerifyCode($code.Replace('combine','newCombine').Replace('rec(','newRecord(').Replace('hash(','newHash('))) '构建变量改名导致误拒绝。'
}
Test-Case '跨进程互斥锁阻止第二个启动器' {
    $f = New-Fixture
    $mutex = Enter-RuntimeLock $f.Context
    try {
        & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'LockProbe.ps1') -Payload $Payload -ToolRoot $f.Context.ToolRoot | Out-Null
        Assert-True ($LASTEXITCODE -eq 11) '第二个进程获得了同一互斥锁。'
    } finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
}
Test-Case '首次修复后连续启动仅复制一次' {
    $f = New-Fixture
    $first = Invoke-RuntimeEngine $f.Context 'Launch'
    $second = Invoke-RuntimeEngine $f.Context 'Launch'
    Assert-True ($first.Copied -and $second.FastPath -and -not $second.Copied) '快速路径未生效。'
    Assert-True ($f.Copies -eq 1 -and $f.Activations -eq 2) '复制或启动次数错误。'
}
Test-Case '版本变化但 runtime ID 不变时复用' {
    $f = New-Fixture; $a = Invoke-RuntimeEngine $f.Context 'Repair'
    $f.Package.Version = '2.0.0'; $f.Package.Identity = 'identity-two'
    $b = Invoke-RuntimeEngine $f.Context 'Repair'
    Assert-True ($a.RuntimeId -eq $b.RuntimeId -and $f.Copies -eq 1 -and -not $b.Copied) '相同运行时发生多余复制。'
}
Test-Case 'manifest 内容变化使用新 hash，保留旧目录' {
    $f = New-Fixture; $a = Invoke-RuntimeEngine $f.Context 'Repair'
    [IO.File]::WriteAllText((Join-Path $f.Package.SourceRoot 'manifest.json'), '{"version":"two"}')
    $f.Package.Identity = 'identity-two'
    $b = Invoke-RuntimeEngine $f.Context 'Repair'
    Assert-True ($a.RuntimeId -ne $b.RuntimeId -and $f.Copies -eq 2) '更新未切换 runtime。'
    Assert-True (Test-Path -LiteralPath $a.Target) '工具删除了旧正式 runtime。'
}
Test-Case 'Node 二进制变化使用新 hash' {
    $f = New-Fixture; $a = Invoke-RuntimeEngine $f.Context 'Repair'
    [IO.File]::AppendAllText((Join-Path $f.Package.SourceRoot 'bin\node.exe'), '新版本')
    $f.Package.Identity = 'identity-two'; $b = Invoke-RuntimeEngine $f.Context 'Repair'
    Assert-True ($a.RuntimeId -ne $b.RuntimeId -and $f.Copies -eq 2) 'Node 更新未切换 hash。'
}
Test-Case 'node_repl 缺失时修复并备份损坏目录' {
    $f = New-Fixture; $a = Invoke-RuntimeEngine $f.Context 'Repair'
    $missing = [ChatGPTRuntimeLauncher.Files]::Within($f.Root, (Join-Path $a.Target 'bin\node_repl.exe'), $false)
    Remove-Item -LiteralPath $missing
    $b = Invoke-RuntimeEngine $f.Context 'Repair'
    Assert-True ($f.Copies -eq 2 -and (Test-Path -LiteralPath $missing)) '缺失文件未恢复。'
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $f.Context.ToolRoot 'runtime-backups') -Directory).Count -eq 1) '未备份损坏目录。'
}
Test-Case '普通模块缺失也能被检测' {
    $f = New-Fixture; $a = Invoke-RuntimeEngine $f.Context 'Repair'
    $missing = [ChatGPTRuntimeLauncher.Files]::Within($f.Root, (Join-Path $a.Target 'bin\node_modules\module\index.js'), $false)
    Remove-Item -LiteralPath $missing
    $b = Invoke-RuntimeEngine $f.Context 'Repair'
    Assert-True ($f.Copies -eq 2 -and (Test-Path -LiteralPath $missing)) '普通模块缺失被遗漏。'
}
Test-Case '关键文件同大小同时间戳篡改仍被识别' {
    $f = New-Fixture; $a = Invoke-RuntimeEngine $f.Context 'Repair'
    $file = Join-Path $a.Target 'bin\node_repl.exe'
    $ticks = [IO.File]::GetLastWriteTimeUtc($file)
    $bytes = [IO.File]::ReadAllBytes($file); $bytes[0] = $bytes[0] -bxor 1
    [IO.File]::WriteAllBytes($file, $bytes); [IO.File]::SetLastWriteTimeUtc($file, $ticks)
    [void](Invoke-RuntimeEngine $f.Context 'Repair')
    Assert-True ($f.Copies -eq 2) '关键摘要检查失效。'
}
Test-Case '损坏状态文件重新校验完整目标，不重复复制' {
    $f = New-Fixture; [void](Invoke-RuntimeEngine $f.Context 'Repair')
    [IO.File]::WriteAllText($f.Context.StateFile, '{损坏 JSON')
    $b = Invoke-RuntimeEngine $f.Context 'Repair'
    Assert-True ($b.Complete -and $f.Copies -eq 1) '状态损坏触发了无必要的复制。'
}
Test-Case '状态里的旧 hash 不能替代当前 runtime ID' {
    $f = New-Fixture; $a = Invoke-RuntimeEngine $f.Context 'Repair'
    $state = Read-RuntimeJson $f.Context.StateFile; $state.RuntimeId = '0000000000000000'
    Save-RuntimeJson $f.Context $f.Context.StateFile $state
    $b = Invoke-RuntimeEngine $f.Context 'Repair'
    Assert-True ($a.RuntimeId -eq $b.RuntimeId -and $f.Copies -eq 1) '误信了状态里的旧 hash。'
}
Test-Case '已有后台进程阻止修复，不结束或启动进程' {
    $f = New-Fixture; $f.Processes = @([pscustomobject]@{ Id = 999; Name = 'ChatGPT'; Path = '测试进程' })
    Assert-Throws { Invoke-RuntimeEngine $f.Context 'Launch' } 10
    Assert-True ($f.Copies -eq 0 -and $f.Activations -eq 0) '占用时进行了修复或启动。'
}
Test-Case '完整目标允许唤起已有实例' {
    $f = New-Fixture; [void](Invoke-RuntimeEngine $f.Context 'Repair')
    $f.Processes = @([pscustomobject]@{ Id = 999; Name = 'ChatGPT'; Path = '测试进程' })
    [void](Invoke-RuntimeEngine $f.Context 'Launch')
    Assert-True ($f.Copies -eq 1 -and $f.Activations -eq 1) '已有完整实例未激活。'
}
Test-Case '复制中出现应用进程时暂缓发布' {
    $f = New-Fixture
    $probe = @{ Count = 0 }
    $f.Context.ProcessProbe = { param($ctx, $pkg) $probe.Count++; if ($probe.Count -gt 1) { [pscustomobject]@{ Id = 888; Name = 'ChatGPT' } } }.GetNewClosure()
    Assert-Throws { Invoke-RuntimeEngine $f.Context 'Repair' } 10
    Assert-True ($f.Copies -eq 1 -and -not (Test-Path -LiteralPath $f.Context.StateFile)) '新进程出现后仍发布成功状态。'
    $target = Join-Path $f.Context.RuntimeRoot ([ChatGPTRuntimeLauncher.Files]::RuntimeId($f.Package.SourceRoot))
    Assert-True (-not (Test-Path -LiteralPath $target)) '新进程出现后仍替换了目标。'
}
Test-Case '空间不足在复制前停止' {
    $f = New-Fixture; $f.Context.FreeSpace = { param($path) [long]0 }
    Assert-Throws { Invoke-RuntimeEngine $f.Context 'Repair' } 21
    Assert-True ($f.Copies -eq 0 -and -not (Test-Path -LiteralPath $f.Context.StateFile)) '空间不足仍执行复制或记成功。'
}
Test-Case 'xcopy 非零退出不发布半成品' {
    $f = New-Fixture
    $f.Context.CopyAction = { param($src, $dst) [IO.File]::WriteAllText((Join-Path $dst 'partial.txt'), '部分内容'); [pscustomobject]@{ ExitCode = 5; Output = '模拟写入失败' } }
    Assert-Throws { Invoke-RuntimeEngine $f.Context 'Repair' } 21
    Assert-True (-not (Test-Path -LiteralPath $f.Context.StateFile)) '失败复制保存了成功状态。'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $f.Context.RuntimeRoot ([ChatGPTRuntimeLauncher.Files]::RuntimeId($f.Package.SourceRoot))))) '失败复制污染正式目录。'
    Assert-True ($f.Recycled -eq 1) '失败临时副本未进入回收策略。'
}
Test-Case '系统 xcopy 的实际错误也能收集退出码' {
    $f = New-Fixture
    $original = New-RuntimeContext -ToolRoot $f.Context.ToolRoot -RuntimeRoot $f.Context.RuntimeRoot
    $destination = Join-Path $f.Root 'empty'; [void][IO.Directory]::CreateDirectory($destination)
    $json = ConvertTo-Json -InputObject @([ChatGPTRuntimeLauncher.Files]::Inventory($f.Package.SourceRoot, $false)) -Depth 5 -Compress
    $result = & $original.XcopyAction (Join-Path $f.Root 'source-not-found') $destination $json $null
    Assert-True ($result.ExitCode -ne 0 -and -not [string]::IsNullOrEmpty($result.Output)) '原生命令错误未保留退出码和诊断。'
}
Test-Case 'xcopy 返回成功但内容不全仍拒绝发布' {
    $f = New-Fixture
    $f.Context.CopyAction = { param($src, $dst) [IO.File]::WriteAllText((Join-Path $dst 'partial.txt'), '部分内容'); [pscustomobject]@{ ExitCode = 0; Output = '' } }
    Assert-Throws { Invoke-RuntimeEngine $f.Context 'Repair' } 22
    Assert-True (-not (Test-Path -LiteralPath $f.Context.StateFile)) '不完整目标保存了成功状态。'
}
Test-Case '复制失败不移动已有损坏目录' {
    $f = New-Fixture; $a = Invoke-RuntimeEngine $f.Context 'Repair'
    $file = Join-Path $a.Target 'bin\node.exe'; [IO.File]::WriteAllText($file, '原有损坏内容')
    $before = [ChatGPTRuntimeLauncher.Files]::Hash($file)
    $f.Context.CopyAction = { param($src, $dst) [pscustomobject]@{ ExitCode = 5; Output = '模拟复制失败' } }
    Assert-Throws { Invoke-RuntimeEngine $f.Context 'Repair' } 21
    Assert-True (([ChatGPTRuntimeLauncher.Files]::Hash($file)) -eq $before) '复制失败改变了原目录。'
}
Test-Case '复制中换版仅重试一次并采用新包' {
    $f = New-Fixture
    $f.Context.ResolvePackage = { $f.Resolves++; if ($f.Resolves -ge 2) { $f.Package = $f.Package.PSObject.Copy(); $f.Package.Identity = 'identity-two'; $f.Package.Version = '2.0.0' }; $f.Package }.GetNewClosure()
    $result = Invoke-RuntimeEngine $f.Context 'Repair'
    Assert-True ($f.Copies -eq 2 -and $result.PackageVersion -eq '2.0.0') '换版重试未生效。'
}
Test-Case '持续换版有界退出，不发布旧目标' {
    $f = New-Fixture
    $f.Context.ResolvePackage = { $f.Resolves++; $f.Package = [pscustomobject]@{ Version = 'v' + $f.Resolves; Identity = 'id' + $f.Resolves; FullName = '包' + $f.Resolves; Family = 'test'; AppId = 'App'; Executable = 'test'; SourceRoot = $f.Package.SourceRoot; Asar = $f.Package.Asar }; $f.Package }.GetNewClosure()
    Assert-Throws { Invoke-RuntimeEngine $f.Context 'Launch' } 12
    Assert-True ($f.Copies -eq 2 -and $f.Activations -eq 0 -and -not (Test-Path -LiteralPath $f.Context.StateFile)) '换版重试失去边界。'
}
Test-Case '未知算法不会采用旧 staging' {
    $f = New-Fixture; [void](New-AgedStaging $f)
    $f.Context.VerifyAlgorithm = { param($pkg) throw '未知算法' }
    Assert-Throws { Invoke-RuntimeEngine $f.Context 'Launch' } 20
    Assert-True ($f.Copies -eq 0 -and $f.Activations -eq 0) '未知算法仍继续复制或启动。'
}
Test-Case '旧 staging 两次稳定观察后回收，正式目录保留' {
    $f = New-Fixture; $a = Invoke-RuntimeEngine $f.Context 'Repair'; $old = New-AgedStaging $f
    Invoke-ConservativeStagingCleanup $f.Context $f.Package
    Assert-True (Test-Path -LiteralPath $old) '首次观察即回收。'
    $f.Now = $f.Now.AddHours(25); Invoke-ConservativeStagingCleanup $f.Context $f.Package
    Assert-True (-not (Test-Path -LiteralPath $old) -and $f.Recycled -eq 1) '稳定旧目录未回收。'
    Assert-True (Test-Path -LiteralPath $a.Target) '正式目录被回收。'
}
Test-Case '近期、变化中和进程占用的 staging 均保留' {
    $f = New-Fixture; [void](Invoke-RuntimeEngine $f.Context 'Repair'); $old = New-AgedStaging $f
    Invoke-ConservativeStagingCleanup $f.Context $f.Package
    $f.Now = $f.Now.AddHours(25); $f.Processes = @([pscustomobject]@{ Id = 777 })
    Invoke-ConservativeStagingCleanup $f.Context $f.Package
    Assert-True (Test-Path -LiteralPath $old) '占用期间清理了目录。'
    $f.Processes = @(); [IO.File]::WriteAllText((Join-Path $old 'new.txt'), '变化')
    Invoke-ConservativeStagingCleanup $f.Context $f.Package
    Assert-True (Test-Path -LiteralPath $old) '变化中的目录被清理。'
    $recent = Join-Path $f.Context.RuntimeRoot '.staging-abcdef0123456789-recent'; [void][IO.Directory]::CreateDirectory($recent)
    Invoke-ConservativeStagingCleanup $f.Context $f.Package
    Assert-True (Test-Path -LiteralPath $recent) '近期目录被清理。'
}
Test-Case '重解析点和越界路径拒绝处理' {
    $f = New-Fixture; [void](Invoke-RuntimeEngine $f.Context 'Repair')
    $external = Join-Path $f.Root 'preserve'; [void][IO.Directory]::CreateDirectory($external)
    $file = Join-Path $external 'sentinel.txt'; [IO.File]::WriteAllText($file, '保留')
    $junction = Join-Path $f.Context.RuntimeRoot '.staging-1234567890abcdef-junction'
    [void](New-Item -ItemType Junction -Path $junction -Target $external)
    Assert-Throws { [ChatGPTRuntimeLauncher.Files]::Within($f.Context.RuntimeRoot, $junction, $false) } 0
    Assert-Throws { [ChatGPTRuntimeLauncher.Files]::Within($f.Context.RuntimeRoot, (Join-Path $f.Context.RuntimeRoot '..\outside'), $false) } 0
    Invoke-ConservativeStagingCleanup $f.Context $f.Package
    $f.Now = $f.Now.AddDays(30); Invoke-ConservativeStagingCleanup $f.Context $f.Package
    Assert-True ((Test-Path -LiteralPath $file) -and $f.Recycled -eq 0) '联接点目标受到影响。'
}
Test-Case '回收失败不降级为永久删除' {
    $f = New-Fixture; [void](Invoke-RuntimeEngine $f.Context 'Repair'); $old = New-AgedStaging $f
    Invoke-ConservativeStagingCleanup $f.Context $f.Package; $f.Now = $f.Now.AddHours(25)
    $f.Context.RecycleAction = { param($path) throw '回收站不可用' }
    Invoke-ConservativeStagingCleanup $f.Context $f.Package
    Assert-True (Test-Path -LiteralPath $old) '回收失败后目录丢失。'
}
Test-Case '安装及回滚恢复旧文件和旧快捷方式' {
    $f = New-Fixture; [void][IO.Directory]::CreateDirectory($f.Context.ToolRoot)
    $originalFile = Join-Path $f.Context.ToolRoot 'original.txt'; [IO.File]::WriteAllText($originalFile, '原有工具内容')
    $desktop = Join-Path $f.Root 'Desktop'; $programs = Join-Path $f.Root 'Programs'; [void][IO.Directory]::CreateDirectory($desktop)
    $originalLink = Join-Path $desktop 'ChatGPT（自动修复）.lnk'; [IO.File]::WriteAllText($originalLink, '原有快捷方式字节')
    $before = [ChatGPTRuntimeLauncher.Files]::Hash($originalLink)
    [IO.File]::WriteAllBytes((Join-Path $f.Root 'icon-chatgpt.ico'), [byte[]]@(1,2,3))
    $installed = Install-RuntimeFiles $Payload $f.Context.ToolRoot @($desktop, $programs) $f.Package
    Assert-True (Test-Path -LiteralPath (Join-Path $f.Context.ToolRoot 'Launcher.ps1')) '安装器未写入工具。'
    $rolled = Undo-RuntimeInstall $f.Context.ToolRoot @($desktop, $programs)
    Assert-True (([ChatGPTRuntimeLauncher.Files]::Hash($originalLink)) -eq $before -and (Test-Path -LiteralPath $originalFile)) '原文件或快捷方式未恢复。'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $f.Context.ToolRoot 'Launcher.ps1'))) '回滚仍留下新脚本。'
}
Test-Case '全新安装回滚保留运行时缓存及修改过的入口' {
    $f = New-Fixture
    $desktop = Join-Path $f.Root 'Desktop'; $programs = Join-Path $f.Root 'Programs'
    [IO.File]::WriteAllBytes((Join-Path $f.Root 'icon-chatgpt.ico'), [byte[]]@(1,2,3))
    [void](Install-RuntimeFiles $Payload $f.Context.ToolRoot @($desktop, $programs) $f.Package)
    $link = Join-Path $desktop 'ChatGPT（自动修复）.lnk'; [IO.File]::WriteAllText($link, '用户后来修改的入口')
    $cache = Join-Path $f.Context.RuntimeRoot '1234567890abcdef'; [void][IO.Directory]::CreateDirectory($cache)
    $result = Undo-RuntimeInstall $f.Context.ToolRoot @($desktop, $programs)
    Assert-True ((Test-Path -LiteralPath $cache) -and (Test-Path -LiteralPath $link) -and $result.RetainedModifiedShortcuts.Count -eq 1) '回滚覆盖了用户后续修改或缓存。'
}
Test-Case '受保护源文件 xcopy G 的真实隔离复制' {
    $pkg = Get-RuntimePackage
    $folder = Join-Path $script:RunRoot 'protected-copy'; [void][IO.Directory]::CreateDirectory($folder)
    $source = Join-Path $pkg.SourceRoot 'bin\node_repl.exe'
    $normal = Join-Path $folder 'ordinary-copy.exe'
    $ordinary = '成功'
    try { [IO.File]::Copy($source, $normal, $false) } catch { $ordinary = $_.Exception.ToString() }
    $destination = Join-Path $folder 'xcopy'; [void][IO.Directory]::CreateDirectory($destination)
    $output = & "$env:SystemRoot\System32\xcopy.exe" $source $destination /I /H /Y /G /Q 2>&1
    $code = $LASTEXITCODE
    $copied = Join-Path $destination 'node_repl.exe'
    Assert-True ($code -eq 0) ('xcopy 失败：' + ($output -join ' '))
    Assert-True (([ChatGPTRuntimeLauncher.Files]::Hash($source)) -eq ([ChatGPTRuntimeLauncher.Files]::Hash($copied))) '复制内容不同。'
    Assert-True (([IO.File]::GetAttributes($copied) -band [IO.FileAttributes]::Encrypted) -eq 0) '目标仍有加密标记。'
    [IO.File]::WriteAllText((Join-Path $script:RunRoot 'protected-copy-evidence.json'), ([pscustomobject]@{ OrdinaryCopy = $ordinary; XcopyExitCode = $code; HashMatched = $true; DestinationEncrypted = $false } | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
}

Test-Case '目标缺失时不预先全量计算源摘要' {
    $f = New-Fixture
    $a = Get-RuntimeAssessment $f.Context $f.Package
    try {
        Assert-True (-not $a.Complete -and -not $a.SourceHasHashes) '空目标仍提前全量哈希。'
        Assert-True (@($a.SourceEntries | Where-Object { $_.Hash }).Count -eq 0) '元数据清单带有预计算摘要。'
    } finally { if ($f.Context.Progress) { $f.Context.Progress.Dispose(); $f.Context.Progress = $null } }
}
Test-Case '文件流复制并发不超过四任务，每任务一 MiB 缓冲' {
    $f = New-Fixture
    $bytes = New-Object byte[] (2MB)
    for ($i = 0; $i -lt 12; $i++) { $bytes[0] = $i; [IO.File]::WriteAllBytes((Join-Path $f.Package.SourceRoot ('bin\node_modules\module\large-{0}.dat' -f $i)), $bytes) }
    $r = Invoke-RuntimeEngine $f.Context 'Repair'
    Assert-True ($r.CopyMetrics.MaxActiveWorkers -gt 1 -and $r.CopyMetrics.MaxActiveWorkers -le 4) '并发上限或并发执行无效。'
    Assert-True ($r.CopyMetrics.BufferBytes -eq 1MB -and $r.CopyMetrics.TotalFiles -eq 16) '缓冲或复制文件数错误。'
    $state = Read-RuntimeJson $f.Context.StateFile
    $actual = [ChatGPTRuntimeLauncher.Files]::Inventory($r.Target, $true)
    Assert-True (@([ChatGPTRuntimeLauncher.Files]::Compare((ConvertTo-Json -InputObject @($state.SourceEntries) -Depth 5 -Compress), $actual)).Count -eq 0) '并发复制内容不一致。'
}
Test-Case '仅权限和加密源读取错误属于兼容回退范围' {
    $access = New-Object UnauthorizedAccessException('模拟源权限失败')
    $encrypted = New-Object IO.IOException('模拟 EFS 错误', [Convert]::ToInt32('80071770',16))
    $disk = New-Object IO.IOException('模拟磁盘不足', [Convert]::ToInt32('80070070',16))
    $sharing = New-Object IO.IOException('模拟文件占用', [Convert]::ToInt32('80070020',16))
    Assert-True ([ChatGPTRuntimeLauncher.TransferJob]::IsReadCompatibilityError($access)) '遗漏源权限错误。'
    Assert-True ([ChatGPTRuntimeLauncher.TransferJob]::IsReadCompatibilityError($encrypted)) '遗漏源 EFS 错误。'
    Assert-True (-not [ChatGPTRuntimeLauncher.TransferJob]::IsReadCompatibilityError($disk)) '磁盘不足被错误归为兼容错误。'
    Assert-True (-not [ChatGPTRuntimeLauncher.TransferJob]::IsReadCompatibilityError($sharing)) '文件占用被错误归为兼容错误。'
}
Test-Case '真实源文件占用失败后全部流关闭，不触发兼容回退' {
    $f = New-Fixture
    $entries = [ChatGPTRuntimeLauncher.Files]::Inventory($f.Package.SourceRoot, $false)
    $dst = Join-Path $f.Root 'locked-source-copy'
    $src = Join-Path $f.Package.SourceRoot 'bin\node_modules\module\index.js'
    $lock = [IO.File]::Open($src, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    try {
        $job = [ChatGPTRuntimeLauncher.TransferJob]::Copy($f.Package.SourceRoot, $dst, (ConvertTo-Json -InputObject @($entries) -Depth 5 -Compress))
        $copy = $job.Finish()
        Assert-True ($copy.ExitCode -ne 0 -and $copy.FailureOrigin -eq 'SourceRead' -and -not $copy.CompatibilityFailure) '占用错误分类不正确。'
    } finally { $lock.Dispose() }
    foreach ($entry in $entries | Where-Object { -not $_.Directory }) {
        $stream = [IO.File]::Open((Join-Path $f.Package.SourceRoot $entry.Path), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
        $stream.Dispose()
    }
    [IO.Directory]::Move($dst, ($dst + '-joined'))
}
Test-Case '真实目标写入失败不会触发源读取回退' {
    $f = New-Fixture
    $dst = Join-Path $f.Root 'existing-target-copy'; [void][IO.Directory]::CreateDirectory($dst)
    $sentinel = Join-Path $dst 'manifest.json'; [IO.File]::WriteAllText($sentinel, '保留原文件')
    $before = [ChatGPTRuntimeLauncher.Files]::Hash($sentinel)
    $entries = [ChatGPTRuntimeLauncher.Files]::Inventory($f.Package.SourceRoot, $false)
    $copy = [ChatGPTRuntimeLauncher.TransferJob]::Copy($f.Package.SourceRoot, $dst, (ConvertTo-Json -InputObject @($entries) -Depth 5 -Compress)).Finish()
    Assert-True ($copy.ExitCode -ne 0 -and $copy.FailureOrigin -eq 'DestinationWrite' -and -not $copy.CompatibilityFailure) '目标写入错误被错误回退。'
    Assert-True ([ChatGPTRuntimeLauncher.Files]::Hash($sentinel) -eq $before) '目标原文件被覆盖。'
    [IO.Directory]::Move($dst, ($dst + '-joined'))
}
Test-Case '兼容源读取错误只回退一次并隔离失败副本' {
    $f = New-Fixture; $count = @{ Fallback = 0; Quarantined = $false }
    $f.Context.CopyAction = { param($src, $dst) [IO.File]::WriteAllText((Join-Path $dst 'partial.txt'), '失败副本'); [pscustomobject]@{ ExitCode = 1; Output = '模拟源读取权限失败'; FailureOrigin = 'SourceRead'; CompatibilityFailure = $true } }
    $legacy = $f.Context.XcopyAction
    $f.Context.XcopyAction = { param($src, $dst, $json, $progress)
        $count.Fallback++
        $count.Quarantined = @(Get-ChildItem -LiteralPath (Join-Path $f.Context.ToolRoot 'failed-copies') -Directory).Count -eq 1
        & $legacy $src $dst $json $progress
    }.GetNewClosure()
    $r = Invoke-RuntimeEngine $f.Context 'Repair'
    Assert-True ($r.Complete -and $r.CopyMethod -eq 'xcopy' -and $count.Fallback -eq 1 -and $count.Quarantined -and $f.Recycled -eq 1) '兼容回退次数、隔离或回收不正确。'
}
Test-Case '兼容回退再次失败后有界停止，两个失败副本均隔离回收' {
    $f = New-Fixture; $count = @{ Fallback = 0 }
    $f.Context.CopyAction = { param($src, $dst) [pscustomobject]@{ ExitCode = 1; Output = '源权限错误'; FailureOrigin = 'SourceRead'; CompatibilityFailure = $true } }
    $f.Context.XcopyAction = { param($src, $dst) $count.Fallback++; [pscustomobject]@{ ExitCode = 4; Output = '模拟兼容复制失败' } }.GetNewClosure()
    Assert-Throws { Invoke-RuntimeEngine $f.Context 'Launch' } 21
    Assert-True ($count.Fallback -eq 1 -and $f.Recycled -eq 2 -and $f.Activations -eq 0 -and -not (Test-Path -LiteralPath $f.Context.StateFile)) '回退失去边界或发布了半成品。'
}
Test-Case '换版重检后仍保持本次启动最多一次兼容回退' {
    $f = New-Fixture; $count = @{ Fallback = 0 }
    $f.Context.CopyAction = { param($src, $dst) [pscustomobject]@{ ExitCode = 1; Output = '模拟源权限失败'; FailureOrigin = 'SourceRead'; CompatibilityFailure = $true } }
    $legacy = $f.Context.XcopyAction
    $f.Context.XcopyAction = { param($src, $dst, $json, $progress) $count.Fallback++; & $legacy $src $dst $json $progress }.GetNewClosure()
    $f.Context.ResolvePackage = { $f.Resolves++; if ($f.Resolves -ge 2) { $f.Package = $f.Package.PSObject.Copy(); $f.Package.Identity = 'identity-two'; $f.Package.Version = '2.0.0' }; $f.Package }.GetNewClosure()
    Assert-Throws { Invoke-RuntimeEngine $f.Context 'Repair' } 21
    Assert-True ($count.Fallback -eq 1 -and -not (Test-Path -LiteralPath $f.Context.StateFile)) '换版后重复进行了兼容回退。'
}
Test-Case '磁盘、校验及包变化错误不触发兼容回退' {
    foreach ($kind in @('DestinationWrite','SourceChanged','Validation')) {
        $f = New-Fixture; $count = @{ Fallback = 0 }
        $f.Context.XcopyAction = { param($src, $dst) $count.Fallback++; throw '错误调用兼容回退' }.GetNewClosure()
        if ($kind -eq 'Validation') {
            $f.Context.CopyAction = { param($src, $dst) [IO.File]::WriteAllText((Join-Path $dst 'partial.txt'), '坏副本'); [pscustomobject]@{ ExitCode = 0; Output = '' } }
            $code = 22
        } else {
            $f.Context.CopyAction = { param($src, $dst) [pscustomobject]@{ ExitCode = 1; Output = '模拟失败'; FailureOrigin = $kind; CompatibilityFailure = $false } }.GetNewClosure()
            $code = if ($kind -eq 'SourceChanged') { 12 } else { 21 }
        }
        Assert-Throws { Invoke-RuntimeEngine $f.Context 'Repair' } $code
        Assert-True ($count.Fallback -eq 0 -and -not (Test-Path -LiteralPath $f.Context.StateFile)) '非兼容错误执行了回退或发布。'
    }
}
Test-Case '兼容回退前空间不足不调用 xcopy' {
    $f = New-Fixture; $count = @{ Space = 0; Fallback = 0 }
    $f.Context.FreeSpace = { param($path) $count.Space++; if ($count.Space -eq 1) { [long]10GB } else { [long]0 } }.GetNewClosure()
    $f.Context.CopyAction = { param($src, $dst) [pscustomobject]@{ ExitCode = 1; Output = '模拟源权限失败'; FailureOrigin = 'SourceRead'; CompatibilityFailure = $true } }
    $f.Context.XcopyAction = { $count.Fallback++; throw '不应运行' }.GetNewClosure()
    Assert-Throws { Invoke-RuntimeEngine $f.Context 'Repair' } 21
    Assert-True ($count.Fallback -eq 0 -and $f.Recycled -eq 1) '回退空间不足仍调用复制。'
}
Test-Case '恶意复制清单拒绝越界，不修改外部文件' {
    $f = New-Fixture; $dst = Join-Path $f.Root 'safe-destination'
    $bad = '[{"Path":"../outside.txt","Directory":false,"Length":0,"Modified":0,"Created":0}]'
    $copy = [ChatGPTRuntimeLauncher.TransferJob]::Copy($f.Package.SourceRoot, $dst, $bad).Finish()
    Assert-True ($copy.ExitCode -ne 0 -and -not $copy.CompatibilityFailure -and -not (Test-Path -LiteralPath (Join-Path $f.Root 'outside.txt'))) '越界路径被接受。'
}
Test-Case '中文进度显示阶段、文件数和耗时，NoUi 始终安静' {
    $progress = New-Object ChatGPTRuntimeLauncher.ProgressDisplay($true, 20)
    try {
        $progress.Update('正在独立校验目标文件', 12, 34)
        [Threading.Thread]::Sleep(80)
        Assert-True ($progress.ShowCount -eq 0 -and $progress.Caption().Contains('12 / 34') -and $progress.Caption().Contains('耗时')) 'NoUi 或中文进度格式失效。'
    } finally { $progress.Dispose() }
}
Test-Case '快速完成不显示进度，超过两秒显示一次并正常关闭' {
    $short = New-Object ChatGPTRuntimeLauncher.ProgressDisplay($false)
    [Threading.Thread]::Sleep(100); $short.Dispose()
    Assert-True ($short.ShowCount -eq 0) '短任务显示了进度窗口。'
    $slow = New-Object ChatGPTRuntimeLauncher.ProgressDisplay($false)
    try {
        $slow.Update('隔离测试：正在验证中文进度', 3, 4)
        [Threading.Thread]::Sleep(2600)
        Assert-True ($slow.ShowCount -eq 1 -and -not $slow.DisplayError) ('延迟进度显示失败：' + $slow.DisplayError)
    } finally { $slow.Dispose() }
}
Test-Case '每次仅深入观察一个 staging，并合并保留其他观察记录' {
    $f = New-Fixture; [void](Invoke-RuntimeEngine $f.Context 'Repair')
    $a = New-AgedStaging $f 'a'; $b = New-AgedStaging $f 'b'; $c = New-AgedStaging $f 'c'
    Invoke-ConservativeStagingCleanup $f.Context $f.Package
    $file = Join-Path $f.Context.ToolRoot 'staging-observations.json'
    $first = @(Read-RuntimeJson $file)
    Assert-True ($first.Count -eq 1) '首次深入检查多个候选。'
    $f.Now = $f.Now.AddHours(25)
    Invoke-ConservativeStagingCleanup $f.Context $f.Package
    $second = @(Read-RuntimeJson $file)
    Assert-True ($second.Count -eq 2 -and @($second | Where-Object Name -eq $first[0].Name)[0].StableSince -eq $first[0].StableSince) '未合并保留其他观察记录。'
    Invoke-ConservativeStagingCleanup $f.Context $f.Package
    Assert-True (@(Read-RuntimeJson $file).Count -eq 3 -and $f.Recycled -eq 0) '最久未观察的候选未优先处理。'
    Invoke-ConservativeStagingCleanup $f.Context $f.Package
    Assert-True ($f.Recycled -eq 1 -and @(Read-RuntimeJson $file).Count -eq 2 -and -not (Test-Path -LiteralPath $a)) '未按观察时间选择一个稳定候选。'
}
Test-Case '占用和近期 staging 在深入扫描前过滤' {
    $f = New-Fixture; [void](Invoke-RuntimeEngine $f.Context 'Repair')
    $old = New-AgedStaging $f 'busy'
    Invoke-ConservativeStagingCleanup $f.Context $f.Package
    $observations = Join-Path $f.Context.ToolRoot 'staging-observations.json'
    $before = [ChatGPTRuntimeLauncher.Files]::Hash($observations)
    $f.Processes = @([pscustomobject]@{ Id = 123 })
    $f.Now = $f.Now.AddDays(2)
    Invoke-ConservativeStagingCleanup $f.Context $f.Package
    Assert-True ([ChatGPTRuntimeLauncher.Files]::Hash($observations) -eq $before -and (Test-Path -LiteralPath $old)) '占用时深入处理了观察记录。'
    $f.Processes = @()
    $recent = Join-Path $f.Context.RuntimeRoot '.staging-1234567890abcdef-recent-filter'
    [void][IO.Directory]::CreateDirectory($recent)
    [IO.Directory]::SetCreationTimeUtc($recent, $f.Now)
    [IO.Directory]::SetLastWriteTimeUtc($recent, $f.Now)
    Invoke-ConservativeStagingCleanup $f.Context $f.Package
    Assert-True (@(Read-RuntimeJson $observations | Where-Object Name -eq (Split-Path -Leaf $recent)).Count -eq 0) '近期目录产生了深入观察记录。'
}
Test-Case '回收前出现占用仍保留 staging' {
    $f = New-Fixture; [void](Invoke-RuntimeEngine $f.Context 'Repair'); $old = New-AgedStaging $f
    Invoke-ConservativeStagingCleanup $f.Context $f.Package; $f.Now = $f.Now.AddHours(25)
    $probe = @{ Count = 0 }
    $f.Context.ProcessProbe = { param($ctx, $pkg) $probe.Count++; if ($probe.Count -ge 3) { [pscustomobject]@{ Id = 987 } } }.GetNewClosure()
    Invoke-ConservativeStagingCleanup $f.Context $f.Package
    Assert-True ((Test-Path -LiteralPath $old) -and $f.Recycled -eq 0) '回收前出现占用仍回收了目录。'
}

$report = [pscustomobject]@{ Time = [DateTime]::UtcNow.ToString('o'); PowerShell = $PSVersionTable.PSVersion.ToString(); Cases = @($script:Results.ToArray()); Passed = @($script:Results | Where-Object { $_.Passed -eq $true }).Count; Failed = @($script:Results | Where-Object { $_.Passed -eq $false -and -not $_.Skipped }).Count; Skipped = @($script:Results | Where-Object Skipped).Count; RunRoot = $script:RunRoot }
[IO.File]::WriteAllText((Join-Path $reportRoot 'latest-tests.json'), ($report | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
$report | Select-Object Passed,Failed,Skipped,RunRoot | ConvertTo-Json
if ($report.Failed) { exit 1 }
