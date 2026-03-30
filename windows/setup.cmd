@echo off
chcp 65001 > nul
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0setup.ps1" %*
