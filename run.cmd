@echo off
setlocal
set "ROOT=%~dp0"
set "JAVA_CHECKERS_QUALITY_ROOT=%ROOT%"
if exist "%ROOT%java-checkers.exe" (
  set "BIN=%ROOT%java-checkers.exe"
) else if exist "%ROOT%target\release\java-checkers.exe" (
  set "BIN=%ROOT%target\release\java-checkers.exe"
) else if exist "%ROOT%target\debug\java-checkers.exe" (
  set "BIN=%ROOT%target\debug\java-checkers.exe"
) else (
  echo java-checkers binary is missing. From the checker checkout run: cargo build --release 1>&2
  exit /b 1
)
"%BIN%" run %*
exit /b %ERRORLEVEL%
