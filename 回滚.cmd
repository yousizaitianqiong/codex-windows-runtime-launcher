@echo off
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -STA -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File "%LOCALAPPDATA%\OpenAI\Codex\RuntimeLauncher\Rollback.ps1"
exit /b %errorlevel%
