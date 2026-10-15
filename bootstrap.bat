@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "BASH_EXE="

if exist "C:\Program Files\Git\bin\bash.exe" set "BASH_EXE=C:\Program Files\Git\bin\bash.exe"
if exist "C:\Program Files\Git\usr\bin\bash.exe" set "BASH_EXE=C:\Program Files\Git\usr\bin\bash.exe"
if exist "C:\Program Files (x86)\Git\bin\bash.exe" set "BASH_EXE=C:\Program Files (x86)\Git\bin\bash.exe"
if exist "C:\Program Files (x86)\Git\usr\bin\bash.exe" set "BASH_EXE=C:\Program Files (x86)\Git\usr\bin\bash.exe"

if not defined BASH_EXE (
  where /q bash
  if %ERRORLEVEL%==0 (
    for /f "delims=" %%i in ('where bash') do (
      echo %%i | findstr /I "\\Windows\\System32\\bash.exe" >nul
      if errorlevel 1 (
        set "BASH_EXE=%%i"
        goto :run
      )
    )
  )
)

if not defined BASH_EXE (
  echo ERROR: bash not found. Install Git for Windows or add bash to PATH.
  exit /b 1
)

:run
"%BASH_EXE%" --login "%SCRIPT_DIR%bootstrap.sh" %*
endlocal
