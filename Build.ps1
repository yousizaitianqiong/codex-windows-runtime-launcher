param()
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -ne 5) { throw '请使用系统 Windows PowerShell 5.1 编译。' }
$sources = @('RuntimeTools.cs', 'TransferTools.cs' | ForEach-Object { Join-Path $PSScriptRoot $_ })
$output = Join-Path $PSScriptRoot 'RuntimeTools.dll'
if (Test-Path -LiteralPath $output) { Remove-Item -LiteralPath $output }
Add-Type -Path $sources -ReferencedAssemblies @('System.dll','System.Core.dll','System.Web.Extensions.dll','System.Windows.Forms.dll','System.Drawing.dll') -OutputAssembly $output
Get-FileHash -LiteralPath $output -Algorithm SHA256
