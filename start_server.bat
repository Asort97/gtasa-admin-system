@echo off
cd /d "%~dp0"
start "open.mp server" /D "%~dp0" cmd /K "omp-server.exe"
