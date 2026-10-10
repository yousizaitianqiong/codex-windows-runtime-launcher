# Codex Windows 自动修复启动器

[English](README.en.md) · [完整使用说明](使用说明.md) · [实测与限制](docs/实测与限制.md) · [参与改进](CONTRIBUTING.md)

一个面向 Windows Microsoft Store/MSIX 版 Codex 的非官方启动器。在启动应用前检查 `cua_node` runtime，缺失或损坏时准备完整副本，再通过 Windows 注册的应用身份激活应用。它解决的是运行时准备问题。

适用于更新后出现后台 `ChatGPT.exe` 进程、没有可用窗口，并伴随不完整 runtime/staging 的情况。如果运行时检查已经通过而窗口仍不出现，应继续调查其他启动问题。

相关上游报告：[openai/codex#42412](https://github.com/openai/codex/issues/42412)、[#41540](https://github.com/openai/codex/issues/41540)、[#41523](https://github.com/openai/codex/issues/41523)。[补充诊断评论](https://github.com/openai/codex/issues/42412#issuecomment-6092676008)记录了故障、复制属性和测量边界。

## 安装与使用

实测环境为 Windows 11 Home x64、Windows PowerShell 5.1、MSIX `OpenAI.Codex 26.1007.2314.0`。其他版本需要重新验证；不兼容未来内部算法时，工具会停止并提示。

1. 从 [Releases](https://github.com/yousizaitianqiong/codex-windows-runtime-launcher/releases) 下载工具包，或下载本仓库源码 ZIP。
2. 审阅来源和代码。如果 Windows 标记 ZIP 来自网络，可在 ZIP 的“属性”中选择“解除锁定”，再完整解压。保留系统执行策略。
3. 双击 `安装.cmd`。仅安装到当前用户，不需要管理员权限；源码下载没有 DLL 时会先用系统工具编译。
4. 以后双击桌面或开始菜单里的 **ChatGPT（自动修复）**。

安装及修复不会强制关闭正在运行的应用。如果已有进程妨碍修复，保存工作、正常退出应用，再点击图标。已有完整 runtime 时，应用可直接激活现有会话。

| 文件 | 用途 |
| --- | --- |
| `安装.cmd` | 安装启动器、备份原入口并按需准备 runtime |
| `启动.cmd` | 检查后启动，等同于专用图标 |
| `检查.cmd` | 只读检查，不修复、不保存状态 |
| `修复.cmd` | 按需修复，不激活应用 |
| `回滚.cmd` | 撤销最近一次安装，恢复旧工具与入口，保留正式 runtime |
| `验证.cmd` | 运行回归测试；完整测试需要当前用户已注册的 Codex 包 |

工具安装在 `%LOCALAPPDATA%\OpenAI\Codex\RuntimeLauncher`。安装时从本机已安装应用读取原图标，仓库和下载包不分发官方图标或 runtime 文件。不增加计划任务或后台服务。

## 复制与校验方式

- 动态查询当前注册的安装包，只读核验 ASAR 中的 runtime ID 算法。
- C# 文件流读取受保护源文件，写入工具临时目录；最多 4 个任务，每任务 1 MiB 缓冲。复制时计算源 SHA-256，再独立读取全部目标文件核验大小与摘要。
- 完整校验后以目录重命名发布。同版本保留快速检查；版本变化但 runtime 内容相同且完整时直接复用。
- 仅源文件的权限或加密读取兼容错误触发一次 `xcopy /G` 回退。空间不足、目标写入失败、更新竞态和校验失败会停止相应操作。
- 超过 2 秒显示中文阶段、文件数量和耗时；`-NoUi` 可关闭窗口反馈。
- 旧 staging 清理要求超过 7 天、至少相隔 24 小时保持稳定、无相关进程，并在回收前再次核验。只送回收站，每次最多深入检查一个候选；正式 runtime 始终排除。

不修改 WindowsApps 所有权/ACL、Defender、加密策略或全局执行策略。对 Windows 管理的注册包根联接点仅允许只读访问，写入与清理拒绝重解析点。

快速检查是性能折中：保留大小和时间戳的非关键文件内容修改可能不会被发现。首次复制、换版深入校验和复制后的发布校验均读取全部文件。

## 已记录的性能

2026-10-10 在同一已安装受保护包、同一 NVMe 卷上顺序执行的单次对比：

| 流程 | 复制 | 完整目标校验 | 复制与校验区间 |
| --- | ---: | ---: | ---: |
| 原 `xcopy /G` 流程 | 113.924 s | 33.194 s | 147.120 s |
| 并行文件流流程 | 10.908 s | 2.301 s | 13.210 s |

复制与校验区间缩短 **91.02%**。两份副本均为 2,365 个文件、251,250,501 字节，逐文件大小及 SHA-256 一致，目标加密文件数为 0。同版本两次启动前检查约为 1.84 s、1.66 s。

这些数据来自外部启动器。未清空系统文件缓存，不是跨机器性能保证，也不包含原生冷启动窗口加载；当前包已包含读写回退，未独立复现该版本未经修复器的原生冷启动失败。详见[实测与限制](docs/实测与限制.md)。

## 从源码构建与测试

以下命令在仓库根目录的 PowerShell 中执行。编译和运行脚本必须使用系统 Windows PowerShell 5.1：

```powershell
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File .\Build.ps1
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -STA -ExecutionPolicy RemoteSigned -File .\tests\Test.ps1 -SkipLive
```

隔离回归使用伪造包与临时目录。`-SkipLive` 明确跳过两个依赖真实安装包/正式 runtime 的测试；GitHub Actions 使用这一模式，不安装 Codex。完整回归去掉该开关，先确认真实注册包和已准备的正式 runtime 存在。测试不会强制退出应用，进度测试会短暂显示测试窗口。

修改 C# 后，在新的 PowerShell 进程中重新运行 `Build.ps1`，再测试。Git 不追踪 DLL；Release 中的辅助 DLL 只由本仓库源码编译。

命令行接口：

```powershell
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy RemoteSigned -File .\Launcher.ps1 -Mode Check -NoUi
```

`-Mode` 支持 `Launch`、`Check`、`Repair`。退出码和回滚细节见[使用说明](使用说明.md)。性能复现见[基准说明](docs/实测与限制.md#复现基准)。

## 交流与许可

欢迎通过 [Issues](https://github.com/yousizaitianqiong/codex-windows-runtime-launcher/issues) 提交环境、脱敏结果和改进建议，或通过 Pull Request 修改代码。不要公开原始日志、个人路径、账号数据或官方 runtime 文件。

[MIT License](LICENSE)，Copyright 2026 yousizaitianqiong。许可适用于本仓库的工具代码；Codex、ChatGPT、Windows 及其安装包、图标和运行时属于各自权利人。
