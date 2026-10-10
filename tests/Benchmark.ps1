param(
    [Parameter(Mandatory=$true)][string]$Payload,
    [Parameter(Mandatory=$true)][ValidateSet('Legacy','Stream')][string]$Method,
    [Parameter(Mandatory=$true)][string]$WorkRoot
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
. (Join-Path $Payload 'RuntimeLauncher.Core.ps1')
Import-RuntimeTools $Payload
$boundary = [ChatGPTRuntimeLauncher.Files]::Full($WorkRoot)
$run = [ChatGPTRuntimeLauncher.Files]::Within($boundary, (Join-Path $boundary ($Method.Substring(0,1) + '-' + [Guid]::NewGuid().ToString('N').Substring(0,6))), $false)
[void][IO.Directory]::CreateDirectory($run)
$ctx = New-RuntimeContext -ToolRoot $run -RuntimeRoot $run
# 直接比较复制与全量校验流程，使用短目录避免 xcopy 的传统路径长度限制干扰。
$initial = Get-RuntimePackage
$sourceNodeRepl = Join-Path $initial.SourceRoot 'bin\node_repl.exe'
$sourceEncrypted = (([IO.File]::GetAttributes($sourceNodeRepl) -band [IO.FileAttributes]::Encrypted) -ne 0)
# Encrypted 属性不足以区分 Application Protected。只记录类型，不输出 cipher 的完整诊断。
$cipherDiagnostic = @(& "$env:SystemRoot\System32\cipher.exe" /c $sourceNodeRepl 2>&1) -join "`n"
$sourceProtection = if ($LASTEXITCODE -eq 0 -and $cipherDiagnostic -match '(?i)Application Protected|应用程序保护') { 'Application Protected' } elseif ($sourceEncrypted) { 'Encrypted (type unknown)' } else { 'Not encrypted' }
$timer = [Diagnostics.Stopwatch]::StartNew()
$module = [ChatGPTRuntimeLauncher.Algorithm]::VerifyAsar($initial.Asar)
$sourceTimer = [Diagnostics.Stopwatch]::StartNew()
$sourceEntries = [ChatGPTRuntimeLauncher.Files]::Inventory($initial.SourceRoot, $Method -eq 'Legacy')
$keys = [string[]]@(foreach ($name in @('manifest.json','bin/node.exe','bin/node_repl.exe')) {
    if ($Method -eq 'Legacy') { ($sourceEntries | Where-Object Path -ceq $name).Hash }
    else { [ChatGPTRuntimeLauncher.Files]::Hash((Join-Path $initial.SourceRoot $name)) }
})
$keyText = New-Object Text.StringBuilder
$names = @('manifest.json','bin/node.exe','bin/node_repl.exe')
for ($i = 0; $i -lt 3; $i++) { [void]$keyText.Append($names[$i]).Append([char]0).Append($keys[$i]).Append([char]0) }
$runtimeId = [ChatGPTRuntimeLauncher.Files]::HashText($keyText.ToString()).Substring(0,16)
$sourceInventoryMs = $sourceTimer.ElapsedMilliseconds
$entriesJson = ConvertTo-Json -InputObject @($sourceEntries) -Depth 5 -Compress
$copyAndVerifyTimer = [Diagnostics.Stopwatch]::StartNew()
$copyTimer = [Diagnostics.Stopwatch]::StartNew()
Write-Output ('开始复制：' + $Method)
if ($Method -eq 'Legacy') { $copy = & $ctx.XcopyAction $initial.SourceRoot $run $entriesJson $null }
else { $copy = & $ctx.CopyAction $initial.SourceRoot $run $entriesJson $null }
$copyMs = $copyTimer.ElapsedMilliseconds
if ($copy.ExitCode -ne 0) { throw ('复制失败：' + $copy.Output) }
Write-Output ('复制完成：' + $Method + '，' + $copyMs + ' ms')
$verifyTimer = [Diagnostics.Stopwatch]::StartNew()
if ($Method -eq 'Legacy') {
    $actual = [ChatGPTRuntimeLauncher.Files]::Inventory($run, $true)
} else {
    $sourceEntries = $copy.Entries
    $entriesJson = [ChatGPTRuntimeLauncher.Files]::ToJson($sourceEntries)
    $actual = @(Invoke-RuntimeHash $ctx $run '正在独立校验目标文件' 'TargetVerifyMs')
}
$errors = @([ChatGPTRuntimeLauncher.Files]::Compare($entriesJson, $actual))
if ($errors.Count -or -not [ChatGPTRuntimeLauncher.Files]::VerifyKeys($run, $keys)) { throw ('独立完整性校验失败：' + ($errors -join '；')) }
$verifyMs = $verifyTimer.ElapsedMilliseconds
$copyAndVerify = $copyAndVerifyTimer.ElapsedMilliseconds
$pipelineMs = $timer.ElapsedMilliseconds
$latest = Get-RuntimePackage
if ($latest.Identity -ne $initial.Identity) { throw '性能测试期间安装包发生变化，本次结果不能采用。' }
$targetFiles = @(Get-ChildItem -LiteralPath $run -Recurse -Force -File)
$encrypted = @($targetFiles | Where-Object { ($_.Attributes -band [IO.FileAttributes]::Encrypted) -ne 0 }).Count
$sourceFiles = @($sourceEntries | Where-Object { -not $_.Directory })
if ($sourceFiles.Count -ne $targetFiles.Count -or $encrypted -ne 0) { throw '性能测试的文件数或目标加密属性验收失败。' }
$report = [pscustomobject]@{
    Time = [DateTime]::UtcNow.ToString('o'); Method = $Method; PackageVersion = $initial.Version
    RuntimeId = $runtimeId; Run = $run; SourceEncrypted = $sourceEncrypted; SourceProtection = $sourceProtection; AlgorithmModule = $module
    Files = $sourceFiles.Count; Bytes = [long](($sourceFiles | Measure-Object Length -Sum).Sum)
    PipelineMs = $pipelineMs; SourceInventoryMs = $sourceInventoryMs; CopyMs = $copyMs; VerifyMs = $verifyMs; CopyAndVerifyMs = $copyAndVerify
    AllFilesSizeAndSha256Matched = $true; DestinationEncryptedFiles = $encrypted
    Notes = '单次独立测试；此脚本不核验磁盘类型、不清空系统缓存、不更改安全设置。窗口加载不计入。比较时请确认两个方法使用同一安装包和目标卷。'
}
if ($Method -eq 'Stream') {
    $report | Add-Member -NotePropertyName WorkerMetrics -NotePropertyValue ([pscustomobject]@{
        MaxActiveWorkers = $copy.MaxActiveWorkers; BufferBytes = $copy.BufferBytes
        CompletedFiles = $copy.CompletedFiles; TotalFiles = $copy.TotalFiles
        CompatibilityFallback = $false
    })
}
[void][IO.Directory]::CreateDirectory($boundary)
[IO.File]::WriteAllText((Join-Path $boundary ($Method + '-result.json')), ($report | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
$report | Select-Object Method,PackageVersion,RuntimeId,SourceEncrypted,SourceProtection,Files,Bytes,PipelineMs,SourceInventoryMs,CopyMs,VerifyMs,CopyAndVerifyMs,AllFilesSizeAndSha256Matched,DestinationEncryptedFiles,WorkerMetrics | ConvertTo-Json -Depth 4
