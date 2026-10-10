@echo off
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -STA -ExecutionPolicy RemoteSigned -File "%~dp0tests\Test.ps1"
pause
