# Codex Windows runtime launcher

[中文](README.md) · [Recorded measurements](docs/实测与限制.md) · [Contributing](CONTRIBUTING.md)

An unofficial, per-user launcher for the Microsoft Store/MSIX version of Codex on Windows. It checks the `cua_node` runtime before activating the registered application and prepares a verified copy when the runtime is missing or damaged.

The motivating symptoms were background `ChatGPT.exe` processes, no usable window after an update, and incomplete runtime/staging directories. See [openai/codex#42412](https://github.com/openai/codex/issues/42412) and the [additional diagnostics](https://github.com/openai/codex/issues/42412#issuecomment-6092676008).

## Getting started

Tested on Windows 11 Home x64, Windows PowerShell 5.1, and MSIX package `OpenAI.Codex 26.1007.2314.0`. Compatibility with other versions requires verification.

1. Download a package from [Releases](https://github.com/yousizaitianqiong/codex-windows-runtime-launcher/releases) or the repository source ZIP.
2. Review the source. If Windows marks the ZIP as downloaded, unblock that specific ZIP through its Properties before extracting it. Keep the system execution policy.
3. Extract everything and double-click `安装.cmd` (install). A source-only download compiles its helper DLL locally with Windows PowerShell 5.1 and .NET Framework.
4. Use the desktop/start-menu **ChatGPT（自动修复）** shortcut for subsequent launches.

The installer preserves current sessions. If repair is blocked by an existing process, save your work, exit the app normally, and try again. The interface and progress window are currently in Chinese.

`检查.cmd` checks without making changes, `修复.cmd` repairs without activating the app, and `回滚.cmd` undoes the latest launcher installation while preserving verified runtime directories. The launcher lives under `%LOCALAPPDATA%\OpenAI\Codex\RuntimeLauncher`.

## How it works

- Discovers the registered package dynamically and checks the runtime ID algorithm by reading ASAR data.
- Copies through C# file streams with at most four workers and a 1 MiB buffer per worker, hashing the source while copying. Independently reads and verifies all destination file sizes and SHA-256 hashes before publishing the directory.
- Falls back to `xcopy /G` once only for source permission/encryption read compatibility errors. Destination errors, low disk space, failed validation, and package changes do not trigger this fallback.
- Reuses complete runtimes; a version-number change alone does not force copying. Unrecognized future internal algorithms stop with a diagnostic.
- Shows progress after two seconds; supports `Launch`, `Check`, `Repair`, and `-NoUi`.
- Cleans only eligible staging directories through the Recycle Bin after age, stability, and process checks. It never cleans formal runtime directories.

No scheduled tasks, background services, WindowsApps ownership/ACL changes, Defender changes, or global execution-policy changes. The official icon is read locally during installation; no official icon, MSIX, or runtime binaries are distributed here.

The normal fast check uses file metadata plus three key hashes. Non-key modifications that preserve size and timestamps may escape that fast check; preparation and publication use full verification.

## Measurements and limits

A single sequential comparison on 2026-10-10, using the same protected package and NVMe volume, recorded:

| Preparation method | Copy | Destination verification | Copy + verification interval |
| --- | ---: | ---: | ---: |
| Earlier `xcopy /G` pipeline | 113.924 s | 33.194 s | 147.120 s |
| Parallel stream pipeline | 10.908 s | 2.301 s | 13.210 s |

The measured interval decreased by **91.02%**. Both destinations matched all 2,365 source files by size and SHA-256 and had zero encrypted files. System caches were not cleared. These are workaround timings, not native application/window startup timings or a performance guarantee.

The tested app already contains a buffered read/write fallback. An unmodified cold-start failure was not independently reproduced on this package version; this project does not establish whether the native issue remains unresolved.

## Build and regression tests

From the repository directory:

```powershell
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File .\Build.ps1
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -STA -ExecutionPolicy RemoteSigned -File .\tests\Test.ps1 -SkipLive
```

`-SkipLive` runs isolated fixtures and skips the two tests requiring a real registered package/prepared runtime. GitHub Actions uses this mode and does not install Codex. Removing the switch requires the real package and a prepared runtime. Tests may briefly show a progress test window and never forcibly terminate the app.

The repository tracks source, not DLLs. Release DLLs are built solely from this project's source. Please submit issues/PRs with sanitized environment and timing data. Avoid raw logs, personal paths, account information, and official runtime files. Chinese and English reports are welcome.

Licensed under the [MIT License](LICENSE). Codex, ChatGPT, Windows, and their packages/assets remain the property of their respective owners.
