@echo off
rem Installs or updates the RoNTAK mod into Ready or Not.
cd /d "%~dp0"
call :find_python
if not defined PY goto no_python
%PY% install.py %*
pause
exit /b

:find_python
set PY=
where py >nul 2>nul && set "PY=py -3" && exit /b
where python >nul 2>nul && set "PY=python"
exit /b

:no_python
echo Python 3 is not installed.
echo Install it from https://www.python.org/downloads/ and tick "Add python.exe to PATH",
echo then run this again.
start "" https://www.python.org/downloads/
pause
exit /b 1
