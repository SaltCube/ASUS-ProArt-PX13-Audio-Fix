@echo off
pushd "%~dp0%"
Install.bat
echo ERRORLEVEL %ERRORLEVEL%
exit /b %ERRORLEVEL%
