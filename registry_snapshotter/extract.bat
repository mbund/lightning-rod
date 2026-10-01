@echo off
setlocal
set "version=%~1"
set "api=%~2"
set "output=%~3"
for %%I in ("%output%") do set "work=%%~dpI"
if not exist "%work%" mkdir "%work%"
if not "%api%"=="" (
    call gradlew.bat --no-daemon --project-cache-dir "%work%gradle-project-cache" registrySnapshot "-Pminecraft_version=%version%" "-Pregistry_api=%api%" "-PsnapshotOutput=%output%" "-PbuildRoot=%work%gradle-build" >"%work%gradle.log" 2>&1
) else (
    call gradlew.bat --no-daemon --project-cache-dir "%work%gradle-project-cache" registrySnapshot "-Pminecraft_version=%version%" "-PsnapshotOutput=%output%" "-PbuildRoot=%work%gradle-build" >"%work%gradle.log" 2>&1
)
set "result=%errorlevel%"
if not %result%==0 type "%work%gradle.log"
exit /b %result%
