@echo off
set "JAVA_CHECKERS_QUALITY_ROOT=%~dp0"
"%~dp0java-checkers.exe" setup %*
exit /b %ERRORLEVEL%
