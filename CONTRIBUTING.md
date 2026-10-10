# 参与改进

欢迎中文或英文 Issue 与 Pull Request。请先说明可以复现的触发条件，再给出环境、实际结果与预期结果。

## 提交问题

建议提供这些字段：

- Windows 版本、架构，以及 Windows PowerShell 版本。
- `Get-AppxPackage OpenAI.Codex` 的 `Version` 与 `Status`，不要把整个对象贴出；包版本与 About 对话框版本可能不同。
- 工具版本、执行模式、退出码，以及是否已有应用会话。
- 是否存在不完整 runtime/staging；`cipher /c` 是否明确显示 `Application Protected`，或仅能确认 `Encrypted` 属性。
- 脱敏后的阶段耗时、文件数量、完整性是否通过，以及是否使用兼容回退。

不要直接上传 `logs`、`state.json`、`installation.json`、`staging-observations.json`、测试的原始 JSON、账号配置或官方 runtime。它们可能包含个人路径、进程信息或未获许可的应用文件。先复制所需字段到新的文字说明，删除路径、用户名和账号信息。

## 修改与验证

脚本针对系统 Windows PowerShell 5.1，C# 使用系统 .NET Framework 自带编译器支持的语法。中文 PS1 保存为 UTF-8 BOM，确保系统 PowerShell 正确读取。源码注释与主要文档使用中文；面向英文上游的材料可以使用英文。

1. 在新的系统 PowerShell 进程中运行 `Build.ps1`。
2. 运行 `tests\Test.ps1 -SkipLive`，验证隔离用例。
3. 涉及真实加密文件、ASAR 或安装包兼容性的修改，在自己的注册包上额外验证；明确列出没有运行的真实测试。
4. 描述行为变化、测试证据及已知限制。DLL、官方应用文件、本机状态与原始报告均不要提交。

重点欢迎：未来包格式/算法的识别、源读取兼容错误的分类、复制与校验性能、进度可用性、保守清理及真实包复现。性能比较请使用同一包、目标卷和完整校验条件，报告单次还是多次测量、缓存与安全扫描状态。

保持以下约束：完整验证后才发布；更新期间最多重检测一次；兼容回退最多一次；正在使用的 runtime 不覆盖；不强制结束应用；清理不越界、不永久删除、不处理正式 runtime；不修改 WindowsApps 权限或安全配置。

提交贡献表示你愿意按仓库的 MIT 许可证提供相应代码。应用自身的问题也可向 [openai/codex](https://github.com/openai/codex/issues) 反馈，并链接可复现的证据。
