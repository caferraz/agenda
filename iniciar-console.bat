@echo off
title Agenda de Compromissos
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0servidor.ps1" -Porta 8085 -AbrirNavegador
pause
