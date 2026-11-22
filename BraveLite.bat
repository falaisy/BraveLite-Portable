@echo off
rem Brave Lite Portable - entry point. Shows the main menu (handled by the PowerShell script).
setlocal
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
rem Keep only the built-in Windows PowerShell module paths so that an inherited
rem PSModulePath from PowerShell 7 cannot break module loading in Windows PowerShell.
set "PSModulePath=%ProgramFiles%\WindowsPowerShell\Modules;%SystemRoot%\system32\WindowsPowerShell\v1.0\Modules"
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0BraveLite.ps1" %*
endlocal
