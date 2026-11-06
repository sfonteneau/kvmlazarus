@echo off
setlocal
rem Requires Python 3, Lazarus/FPC x64 and a matching MinGW-w64 toolchain.
where py >nul 2>nul
if not errorlevel 1 (
  py -3 "%~dp0build\build_standalone.py" %*
) else (
  python "%~dp0build\build_standalone.py" %*
)
exit /b %ERRORLEVEL%
