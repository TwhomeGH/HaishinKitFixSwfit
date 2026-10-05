@echo off
setlocal
set SCRIPT=%~dp0change_log.py
where python >nul 2>nul
if %errorlevel%==0 (
  python "%SCRIPT%" %*
) else (
  py "%SCRIPT%" %*
)
