@echo off
setlocal EnableExtensions EnableDelayedExpansion

REM Setup RTK, optional ICM or Mem0 memory, and optional QMD or Graphify.
REM Windows Command Prompt equivalent of setup.sh. Run from the project root.
REM
REM Optional env (set before calling, or pass as setup.bat VAR=value ...):
REM   AGENT=cursor|github-copilot|antigravity
REM   MEMORY_TOOL=icm|mem0|none
REM   DOCS_TOOL=qmd|graphify|none
REM   BUILD_GRAPHIFY=yes|no
REM   GRAPHIFY_MCP=yes|no        — graphifyy[mcp] vs CLI-only graphifyy
REM   AUTO_INSTALL_PREREQS=yes|no
REM   INSTALL_NODEJS=yes|no
REM   INSTALL_PYTHON=yes|no      — Python 3 via winget (required for Graphify)
REM   SKIP_AGENT_CHECK=yes|no
REM   MEM0_API_KEY=m0-...
REM Back-compat: ENABLE_ICM / ENABLE_MEM0 / ENABLE_GRAPHIFY

chcp 65001 >nul
cd /d "%CD%"

if /i "%~1"=="--help" goto :show_help
if /i "%~1"=="-h" goto :show_help
if /i "%~1"=="/?" goto :show_help

call :parse_args %*

set "LOCAL_BIN=%USERPROFILE%\.local\bin"
set "CURSOR_HOME=%USERPROFILE%\.cursor"
set "MCP_FILE=%CURSOR_HOME%\mcp.json"
if not defined XDG_CONFIG_HOME set "XDG_CONFIG_HOME=%USERPROFILE%\.config"

call :ensure_dir "%LOCAL_BIN%"
set "PATH=%LOCAL_BIN%;%PATH%"
call :ensure_dir "%XDG_CONFIG_HOME%\rtk"

echo AI Optimizer Setup (RTK + ICM/Mem0 + QMD/Graphify)
echo ====================================================

call :select_agent
if errorlevel 1 exit /b 1
call :map_rtk_flag
call :require_agent_installed
if errorlevel 1 exit /b 1
call :select_docs_tool
if errorlevel 1 exit /b 1
call :install_and_init_rtk
if errorlevel 1 exit /b 1
call :select_memory_tool
if errorlevel 1 exit /b 1
call :setup_memory
if errorlevel 1 exit /b 1
call :setup_docs
if errorlevel 1 exit /b 1
call :write_cursor_compression_rule
call :write_agents_file
call :print_summary
exit /b 0

:show_help
echo Usage: setup.bat
echo        set AGENT=cursor ^& set MEMORY_TOOL=icm ^& set DOCS_TOOL=qmd ^& setup.bat
echo.
echo Environment variables match setup.sh: AGENT, MEMORY_TOOL, DOCS_TOOL,
echo BUILD_GRAPHIFY, GRAPHIFY_MCP, AUTO_INSTALL_PREREQS, INSTALL_NODEJS, INSTALL_PYTHON,
echo SKIP_AGENT_CHECK, MEM0_API_KEY.
exit /b 0

:parse_args
:parse_args_loop
if "%~1"=="" goto :eof
echo %~1 | findstr /r /c:"^[A-Za-z_][A-Za-z0-9_]*=" >nul
if not errorlevel 1 (
  for /f "tokens=1* delims==" %%A in ("%~1") do set "%%A=%%B"
)
shift
goto :parse_args_loop

:is_yes
set "IS_YES=0"
if /i "%~1"=="yes" set "IS_YES=1"
if /i "%~1"=="y" set "IS_YES=1"
if "%~1"=="1" set "IS_YES=1"
if /i "%~1"=="true" set "IS_YES=1"
goto :eof

:is_no
set "IS_NO=0"
if /i "%~1"=="no" set "IS_NO=1"
if /i "%~1"=="n" set "IS_NO=1"
if "%~1"=="0" set "IS_NO=1"
if /i "%~1"=="false" set "IS_NO=1"
goto :eof

:ask_permission
REM %1 description  %2 optional env var name
set "ASK_ENV_VAL="
if not "%~2"=="" call set "ASK_ENV_VAL=%%%~2%%"
call :is_yes "%ASK_ENV_VAL%"
if "!IS_YES!"=="1" exit /b 0
call :is_no "%ASK_ENV_VAL%"
if "!IS_NO!"=="1" exit /b 1
call :is_yes "%AUTO_INSTALL_PREREQS%"
if "!IS_YES!"=="1" exit /b 0
call :is_no "%AUTO_INSTALL_PREREQS%"
if "!IS_NO!"=="1" exit /b 1
echo.
echo Permission required: %~1
set /p ASK_ANS=Proceed? [y/N]: 
call :is_yes "%ASK_ANS%"
if "!IS_YES!"=="1" exit /b 0
exit /b 1

:ensure_dir
if not exist "%~1" mkdir "%~1" >nul 2>&1
goto :eof

:command_exists
where "%~1" >nul 2>&1
exit /b %errorlevel%

:add_user_path
set "ADD_DIR=%~1"
echo !PATH! | findstr /i /c:"!ADD_DIR!" >nul
if errorlevel 1 set "PATH=!ADD_DIR!;!PATH!"
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$d = $env:ADD_DIR; if (-not $d) { $d = '%~1' }; $d = $d.TrimEnd('\'); $p = [Environment]::GetEnvironmentVariable('Path','User'); if ([string]::IsNullOrEmpty($p)) { [Environment]::SetEnvironmentVariable('Path', $d, 'User'); exit }; $parts = $p -split ';' | Where-Object { $_ -and $_.TrimEnd('\') -ne $d }; if ($p -notlike ('*'+$d+'*')) { [Environment]::SetEnvironmentVariable('Path', ($parts + $d) -join ';', 'User') }"
goto :eof

:refresh_path
set "PATH=%LOCAL_BIN%;%PATH%"
call :command_exists npm
if not errorlevel 1 (
  for /f "delims=" %%P in ('npm config get prefix 2^>nul') do (
    if exist "%%P" set "PATH=%%P;!PATH!"
  )
)
goto :eof

:find_python
set "PYTHON="
py -3 -c "import sys; print(sys.executable)" > "%TEMP%\aiopt_py.txt" 2>nul
if not errorlevel 1 (
  set /p PYTHON=<"%TEMP%\aiopt_py.txt"
  if exist "!PYTHON!" goto :eof
)
set "PYTHON="
python -c "import sys; print(sys.executable)" > "%TEMP%\aiopt_py.txt" 2>nul
if not errorlevel 1 (
  set /p PYTHON=<"%TEMP%\aiopt_py.txt"
  if exist "!PYTHON!" goto :eof
)
set "PYTHON="
python3 -c "import sys; print(sys.executable)" > "%TEMP%\aiopt_py.txt" 2>nul
if not errorlevel 1 (
  set /p PYTHON=<"%TEMP%\aiopt_py.txt"
  if exist "!PYTHON!" goto :eof
)
set "PYTHON="
for /d %%D in ("%LOCALAPPDATA%\Programs\Python\Python3*") do (
  if exist "%%D\python.exe" (
    "%%D\python.exe" -c "import sys" >nul 2>&1
    if not errorlevel 1 (
      set "PYTHON=%%D\python.exe"
      goto :eof
    )
  )
)
goto :eof

:python_ok
if not defined PYTHON exit /b 1
"%PYTHON%" -c "import sys" >nul 2>&1
exit /b %errorlevel%

:add_python_user_scripts
if not defined PYTHON goto :eof
"%PYTHON%" -c "import sysconfig; print(sysconfig.get_path('scripts'))" > "%TEMP%\aiopt_pyscripts.txt" 2>nul
set /p PY_SCRIPTS=<"%TEMP%\aiopt_pyscripts.txt"
if exist "!PY_SCRIPTS!" (
  set "PATH=!PY_SCRIPTS!;!PATH!"
  call :add_user_path "!PY_SCRIPTS!"
)
"%PYTHON%" -c "import sysconfig; print(sysconfig.get_path('scripts','nt_user'))" > "%TEMP%\aiopt_pyscripts.txt" 2>nul
set /p PY_USER_SCRIPTS=<"%TEMP%\aiopt_pyscripts.txt"
if exist "!PY_USER_SCRIPTS!" (
  set "PATH=!PY_USER_SCRIPTS!;!PATH!"
  call :add_user_path "!PY_USER_SCRIPTS!"
)
for /d %%D in ("%APPDATA%\Python\Python*") do (
  if exist "%%D\Scripts" (
    set "PATH=%%D\Scripts;!PATH!"
    call :add_user_path "%%D\Scripts"
  )
)
goto :eof

:ensure_python
call :find_python
call :python_ok
if not errorlevel 1 (
  echo Python found: !PYTHON!
  call :add_python_user_scripts
  exit /b 0
)
echo.
echo Python 3 is required for Graphify.
echo The Windows Store "python" shortcut does not count — install a real interpreter.
call :ask_permission "Install Python 3.12 with winget?" "INSTALL_PYTHON"
if errorlevel 1 (
  echo Install Python from https://www.python.org/downloads/ ^(check "Add python.exe to PATH"^)
  echo or: winget install -e --id Python.Python.3.12
  echo Then re-run setup.bat.
  exit /b 1
)
call :command_exists winget
if errorlevel 1 (
  echo winget not found. Install Python from https://www.python.org/downloads/
  exit /b 1
)
echo Installing Python 3.12 via winget...
winget install -e --id Python.Python.3.12 --scope user --accept-package-agreements --accept-source-agreements
call :refresh_path
for /d %%D in ("%LOCALAPPDATA%\Programs\Python\Python3*") do (
  if exist "%%D" set "PATH=%%D;%%D\Scripts;!PATH!"
)
call :find_python
call :python_ok
if errorlevel 1 (
  echo Python install did not land on PATH. Close this window, open a NEW Command Prompt, and re-run setup.bat.
  exit /b 1
)
echo Python found: !PYTHON!
call :add_python_user_scripts
goto :eof

:select_agent
if defined AGENT (
  echo Using AGENT=!AGENT! from environment.
) else (
  echo Which AI agent are you using?
  echo   1. github-copilot
  echo   2. cursor
  echo   3. antigravity
  set /p AGENT_N=Choose [1-3]: 
  if "!AGENT_N!"=="1" set "AGENT=github-copilot"
  if "!AGENT_N!"=="2" set "AGENT=cursor"
  if "!AGENT_N!"=="3" set "AGENT=antigravity"
)
if /i "!AGENT!"=="gemini" (
  echo Mapping AGENT=gemini -^> AGENT=antigravity
  set "AGENT=antigravity"
)
if /i not "!AGENT!"=="github-copilot" if /i not "!AGENT!"=="cursor" if /i not "!AGENT!"=="antigravity" (
  echo Unknown AGENT: !AGENT!
  exit /b 1
)
goto :eof

:map_rtk_flag
set "RTK_GLOBAL=-g"
if /i "!AGENT!"=="github-copilot" set "RTK_FLAG=--copilot"
if /i "!AGENT!"=="cursor" set "RTK_FLAG=--agent cursor"
if /i "!AGENT!"=="antigravity" (
  set "RTK_FLAG=--agent antigravity"
  set "RTK_GLOBAL="
)
call :ensure_dir "%LOCAL_BIN%"
if /i "!AGENT!"=="cursor" call :ensure_dir "%CURSOR_HOME%\rules"
if /i "!AGENT!"=="github-copilot" call :ensure_dir "%CURSOR_HOME%\rules"
if /i "!AGENT!"=="cursor" call :ensure_dir "%USERPROFILE%\.claude"
if /i "!AGENT!"=="github-copilot" call :ensure_dir "%USERPROFILE%\.claude"
if /i "!AGENT!"=="antigravity" call :ensure_dir "%USERPROFILE%\.gemini"
goto :eof

:require_agent_installed
call :is_yes "%SKIP_AGENT_CHECK%"
if "!IS_YES!"=="1" (
  echo Skipping agent install check ^(SKIP_AGENT_CHECK=yes^).
  exit /b 0
)
if /i "!AGENT!"=="cursor" goto :check_cursor
if /i "!AGENT!"=="github-copilot" goto :check_copilot
if /i "!AGENT!"=="antigravity" goto :check_antigravity
exit /b 1

:check_cursor
call :command_exists cursor
if not errorlevel 1 (
  echo Cursor detected.
  exit /b 0
)
call :command_exists agent
if not errorlevel 1 (
  echo Cursor CLI detected.
  exit /b 0
)
if exist "%CURSOR_HOME%\cli-config.json" (
  echo Cursor detected ^(%CURSOR_HOME%^).
  exit /b 0
)
if exist "%LOCALAPPDATA%\Programs\cursor\Cursor.exe" (
  echo Cursor detected.
  exit /b 0
)
echo Cursor is not installed ^(or not detectable on this machine^).
echo Install Cursor first, then re-run this script:
echo   Cursor IDE — https://cursor.com/download
exit /b 1

:check_copilot
call :command_exists code
if not errorlevel 1 (
  echo VS Code detected.
  exit /b 0
)
call :command_exists copilot
if not errorlevel 1 (
  echo GitHub Copilot CLI detected.
  exit /b 0
)
if exist "%APPDATA%\Code\User" (
  echo VS Code / Copilot config detected.
  exit /b 0
)
echo GitHub Copilot environment is not installed ^(or not detectable^).
exit /b 1

:check_antigravity
call :command_exists agy
if not errorlevel 1 (
  echo Antigravity CLI detected.
  exit /b 0
)
if exist "%USERPROFILE%\.gemini\antigravity-cli" (
  echo Antigravity CLI detected.
  exit /b 0
)
echo Antigravity CLI ^(agy^) is not installed.
exit /b 1

:select_docs_tool
if not defined DOCS_TOOL if defined ENABLE_GRAPHIFY (
  call :is_yes "%ENABLE_GRAPHIFY%"
  if "!IS_YES!"=="1" (
    set "DOCS_TOOL=graphify"
    echo Mapping ENABLE_GRAPHIFY=yes -^> DOCS_TOOL=graphify
    call :select_graphify_mcp
    goto :eof
  )
)
if defined DOCS_TOOL (
  if /i "!DOCS_TOOL!"=="qmd" goto :docs_ok
  if /i "!DOCS_TOOL!"=="graphify" goto :docs_ok
  if /i "!DOCS_TOOL!"=="none" goto :docs_ok
  echo Unknown DOCS_TOOL: !DOCS_TOOL! ^(use qmd, graphify, or none^)
  exit /b 1
)
echo.
echo Choose a documentation/codebase context tool ^(pick one^):
echo   1. qmd       — semantic search over docs\**\*.md
echo   2. graphify  — knowledge graph + Cursor MCP
echo   3. none      — skip both
set /p DOCS_N=Choose [1-3]: 
if "!DOCS_N!"=="1" set "DOCS_TOOL=qmd"
if "!DOCS_N!"=="2" set "DOCS_TOOL=graphify"
if "!DOCS_N!"=="3" set "DOCS_TOOL=none"
if /i not "!DOCS_TOOL!"=="qmd" if /i not "!DOCS_TOOL!"=="graphify" if /i not "!DOCS_TOOL!"=="none" (
  echo Unknown DOCS_TOOL: !DOCS_TOOL!
  exit /b 1
)
:docs_ok
if defined DOCS_TOOL echo Using DOCS_TOOL=!DOCS_TOOL!
if /i "!DOCS_TOOL!"=="graphify" call :select_graphify_mcp
goto :eof

:select_graphify_mcp
if defined GRAPHIFY_MCP (
  call :is_yes "%GRAPHIFY_MCP%"
  if "!IS_YES!"=="1" set "GRAPHIFY_MCP=yes"
  call :is_no "%GRAPHIFY_MCP%"
  if "!IS_NO!"=="1" set "GRAPHIFY_MCP=no"
  if /i "!GRAPHIFY_MCP!"=="yes" goto :gfm_ok
  if /i "!GRAPHIFY_MCP!"=="no" goto :gfm_ok
  echo Unknown GRAPHIFY_MCP: !GRAPHIFY_MCP! ^(use yes or no^)
  exit /b 1
)
echo.
echo Install Graphify with MCP extra? ^(needed for Cursor query_graph / get_neighbors^)
echo   1. yes  — graphifyy[mcp]  ^(Cursor MCP tools^)
echo   2. no   — graphifyy only  ^(CLI: graphify query / graphify path^)
set /p GFM_N=Choose [1-2] (default 1): 
if "!GFM_N!"=="" set "GFM_N=1"
if "!GFM_N!"=="1" set "GRAPHIFY_MCP=yes"
if /i "!GFM_N!"=="y" set "GRAPHIFY_MCP=yes"
if /i "!GFM_N!"=="yes" set "GRAPHIFY_MCP=yes"
if "!GFM_N!"=="2" set "GRAPHIFY_MCP=no"
if /i "!GFM_N!"=="n" set "GRAPHIFY_MCP=no"
if /i "!GFM_N!"=="no" set "GRAPHIFY_MCP=no"
if /i not "!GRAPHIFY_MCP!"=="yes" if /i not "!GRAPHIFY_MCP!"=="no" set "GRAPHIFY_MCP=yes"
:gfm_ok
echo Using GRAPHIFY_MCP=!GRAPHIFY_MCP!
goto :eof

:install_and_init_rtk
call :command_exists rtk
if errorlevel 1 (
  echo Installing RTK ^(Windows binary^)...
  call :install_rtk_windows
  if errorlevel 1 exit /b 1
) else (
  echo RTK already installed.
)
call :refresh_path
call :command_exists rtk
if errorlevel 1 (
  echo rtk not found on PATH. It was installed to "%LOCAL_BIN%".
  echo Open a new Command Prompt, or run: set PATH=%LOCAL_BIN%;%%PATH%%
  if exist "%LOCAL_BIN%\rtk.exe" set "PATH=%LOCAL_BIN%;%PATH%"
)
call :command_exists rtk
if errorlevel 1 (
  echo RTK install failed.
  exit /b 1
)
echo Configuring RTK for !AGENT!...
rtk init --auto-patch !RTK_GLOBAL! !RTK_FLAG!
if errorlevel 1 (
  echo rtk init failed.
  exit /b 1
)
goto :eof

:install_rtk_windows
set "RTK_ZIP=%TEMP%\rtk-windows.zip"
set "RTK_EXTRACT=%TEMP%\rtk-windows-extract"
if exist "%RTK_EXTRACT%" rmdir /s /q "%RTK_EXTRACT%"
mkdir "%RTK_EXTRACT%" >nul 2>&1
curl.exe -fsSL -L -o "%RTK_ZIP%" "https://github.com/rtk-ai/rtk/releases/latest/download/rtk-x86_64-pc-windows-msvc.zip"
if errorlevel 1 (
  echo Failed to download RTK. Install manually:
  echo   https://github.com/rtk-ai/rtk/releases
  exit /b 1
)
tar -xf "%RTK_ZIP%" -C "%RTK_EXTRACT%"
if errorlevel 1 (
  powershell -NoProfile -Command "Expand-Archive -LiteralPath '%RTK_ZIP%' -DestinationPath '%RTK_EXTRACT%' -Force"
)
if exist "%RTK_EXTRACT%\rtk.exe" (
  copy /y "%RTK_EXTRACT%\rtk.exe" "%LOCAL_BIN%\rtk.exe" >nul
) else (
  for /r "%RTK_EXTRACT%" %%F in (rtk.exe) do copy /y "%%F" "%LOCAL_BIN%\rtk.exe" >nul
)
if not exist "%LOCAL_BIN%\rtk.exe" (
  echo Could not find rtk.exe in the downloaded archive.
  exit /b 1
)
call :add_user_path "%LOCAL_BIN%"
echo RTK installed to "%LOCAL_BIN%\rtk.exe"
goto :eof

:install_icm_windows
set "ICM_BIN_DIR=%LOCALAPPDATA%\icm\bin"
set "ICM_ZIP=%TEMP%\icm-windows.zip"
set "ICM_EXTRACT=%TEMP%\icm-windows-extract"
call :ensure_dir "%ICM_BIN_DIR%"
if exist "%ICM_EXTRACT%" rmdir /s /q "%ICM_EXTRACT%"
mkdir "%ICM_EXTRACT%" >nul 2>&1

if /i "%PROCESSOR_ARCHITECTURE%"=="ARM64" (
  echo ARM64 Windows is not pre-built by ICM. See https://github.com/rtk-ai/icm
  exit /b 1
)
if /i "%PROCESSOR_ARCHITECTURE%"=="x86" if /i not "%PROCESSOR_ARCHITEW6432%"=="AMD64" (
  echo 32-bit Windows is not supported by ICM.
  exit /b 1
)

echo Downloading icm-x86_64-pc-windows-msvc.zip...
curl.exe -fsSL -L -o "%ICM_ZIP%" "https://github.com/rtk-ai/icm/releases/latest/download/icm-x86_64-pc-windows-msvc.zip"
if errorlevel 1 (
  echo Failed to download ICM. Install manually:
  echo   https://github.com/rtk-ai/icm/releases
  exit /b 1
)
tar -xf "%ICM_ZIP%" -C "%ICM_EXTRACT%"
if errorlevel 1 (
  powershell -NoProfile -Command "Expand-Archive -LiteralPath '%ICM_ZIP%' -DestinationPath '%ICM_EXTRACT%' -Force"
)
if exist "%ICM_EXTRACT%\icm.exe" (
  copy /y "%ICM_EXTRACT%\icm.exe" "%ICM_BIN_DIR%\icm.exe" >nul
  if exist "%ICM_EXTRACT%\*.dll" copy /y "%ICM_EXTRACT%\*.dll" "%ICM_BIN_DIR%\" >nul
) else (
  for /r "%ICM_EXTRACT%" %%F in (icm.exe) do (
    copy /y "%%F" "%ICM_BIN_DIR%\icm.exe" >nul
    copy /y "%%~dpF*.dll" "%ICM_BIN_DIR%\" >nul 2>&1
  )
)
if not exist "%ICM_BIN_DIR%\icm.exe" (
  echo Could not find icm.exe in the downloaded archive.
  echo Download it from https://github.com/rtk-ai/icm/releases and copy icm.exe to:
  echo   %ICM_BIN_DIR%
  exit /b 1
)
call :add_user_path "%ICM_BIN_DIR%"
set "PATH=%ICM_BIN_DIR%;%PATH%"
echo ICM installed to "%ICM_BIN_DIR%\icm.exe"
goto :eof

:select_memory_tool
if defined MEMORY_TOOL (
  if /i "!MEMORY_TOOL!"=="icm" goto :mem_ok
  if /i "!MEMORY_TOOL!"=="mem0" goto :mem_ok
  if /i "!MEMORY_TOOL!"=="none" goto :mem_ok
  echo Unknown MEMORY_TOOL: !MEMORY_TOOL! ^(use icm, mem0, or none^)
  exit /b 1
)
if defined ENABLE_ICM (
  call :is_yes "%ENABLE_ICM%"
  if "!IS_YES!"=="1" (
    set "MEMORY_TOOL=icm"
    echo Mapping ENABLE_ICM=yes -^> MEMORY_TOOL=icm
    goto :mem_ok
  )
  call :is_no "%ENABLE_ICM%"
  if "!IS_NO!"=="1" (
    set "MEMORY_TOOL=none"
    echo Mapping ENABLE_ICM=no -^> MEMORY_TOOL=none
    goto :mem_ok
  )
)
if defined ENABLE_MEM0 (
  call :is_yes "%ENABLE_MEM0%"
  if "!IS_YES!"=="1" (
    set "MEMORY_TOOL=mem0"
    echo Mapping ENABLE_MEM0=yes -^> MEMORY_TOOL=mem0
    goto :mem_ok
  )
  call :is_no "%ENABLE_MEM0%"
  if "!IS_NO!"=="1" (
    set "MEMORY_TOOL=none"
    echo Mapping ENABLE_MEM0=no -^> MEMORY_TOOL=none
    goto :mem_ok
  )
)
echo.
echo Choose a memory tool ^(pick one^):
echo   1. icm   — local SQLite memory, no account
echo   2. mem0  — cloud memory, requires API key
echo   3. none  — skip memory
set /p MEM_N=Choose [1-3]: 
if "!MEM_N!"=="1" set "MEMORY_TOOL=icm"
if "!MEM_N!"=="2" set "MEMORY_TOOL=mem0"
if "!MEM_N!"=="3" set "MEMORY_TOOL=none"
if /i not "!MEMORY_TOOL!"=="icm" if /i not "!MEMORY_TOOL!"=="mem0" if /i not "!MEMORY_TOOL!"=="none" (
  echo Unknown MEMORY_TOOL: !MEMORY_TOOL!
  exit /b 1
)
:mem_ok
if defined MEMORY_TOOL echo Using MEMORY_TOOL=!MEMORY_TOOL!
goto :eof

:setup_memory
if /i "!MEMORY_TOOL!"=="icm" (
  call :setup_icm
  if errorlevel 1 exit /b 1
  goto :eof
)
if /i "!MEMORY_TOOL!"=="mem0" (
  call :setup_mem0
  if errorlevel 1 exit /b 1
  goto :eof
)
echo Skipping memory tool initialization.
goto :eof

:setup_icm
set "ICM_BIN_DIR=%LOCALAPPDATA%\icm\bin"
call :command_exists icm
if errorlevel 1 (
  echo Installing ICM ^(Windows binary from GitHub releases^)...
  call :install_icm_windows
  if errorlevel 1 exit /b 1
) else (
  echo ICM already installed.
)
if exist "%ICM_BIN_DIR%" set "PATH=%ICM_BIN_DIR%;%PATH%"
call :command_exists icm
if errorlevel 1 (
  echo icm not found on PATH after install. Open a new Command Prompt and re-run.
  exit /b 1
)
for /f "delims=" %%I in ('where icm 2^>nul') do (
  if not defined ICM_BIN set "ICM_BIN=%%I"
)
if not defined ICM_BIN set "ICM_BIN=icm"

set "ICM_FORCE="
icm init --help 2>&1 | findstr /c:"--force" >nul
if not errorlevel 1 set "ICM_FORCE=--force"

if /i "!AGENT!"=="cursor" (
  echo ICM for Cursor: MCP ^(%MCP_FILE%^) + rule ^(%CURSOR_HOME%\rules\icm.mdc^)...
  icm init --mode mcp !ICM_FORCE!
  icm init --mode skill !ICM_FORCE!
  echo Registering ICM MCP in %MCP_FILE%
  echo   command: !ICM_BIN! serve
  call :merge_mcp_command icm "!ICM_BIN!" serve
  call :write_icm_rule
  echo Restart Cursor / Cursor CLI after MCP config changes.
) else (
  echo ICM for !AGENT!: MCP + CLI instructions...
  icm init --mode mcp !ICM_FORCE!
  icm init --mode cli !ICM_FORCE!
)
goto :eof

:write_icm_rule
if /i not "!AGENT!"=="cursor" goto :eof
call :ensure_dir "%CURSOR_HOME%\rules"
if exist "%CURSOR_HOME%\rules\icm.mdc" (
  echo ICM Cursor rule already present: %CURSOR_HOME%\rules\icm.mdc
  goto :eof
)
(
  echo ---
  echo description: ICM persistent local memory for AI agents
  echo alwaysApply: true
  echo ---
  echo.
  echo Use ICM MCP tools proactively to maintain long-term memory across sessions.
  echo.
  echo RECALL ^(icm_memory_recall^): At the start of a task, search for relevant past context.
  echo.
  echo STORE ^(icm_memory_store^): Store errors resolved, architecture decisions, user preferences, and completed tasks.
  echo.
  echo CLI fallback: icm recall / icm store. Same SQLite DB as MCP.
  echo.
  echo Do NOT store trivial details, ephemeral state, or information already in project docs.
  echo Restart Cursor after MCP config changes. Verify: icm_memory_recall for project setup.
) > "%CURSOR_HOME%\rules\icm.mdc"
echo ICM Cursor rule installed.
goto :eof

:setup_mem0
if not defined MEM0_API_KEY (
  echo.
  echo Mem0 requires an API key from https://app.mem0.ai
  set /p MEM0_API_KEY=Enter MEM0_API_KEY (starts with m0-): 
)
if not defined MEM0_API_KEY (
  echo Set MEM0_API_KEY and re-run.
  exit /b 1
)
echo MEM0_API_KEY is set.
if /i "!AGENT!"=="cursor" (
  echo Mem0 for Cursor: MCP + rule...
  call :merge_mcp_mem0
  call :write_mem0_rule
  echo Restart Cursor / Cursor CLI after MCP config changes.
  echo Verify: search_memories for "project setup"
) else (
  echo Mem0 MCP for !AGENT!...
  call :command_exists npx
  if not errorlevel 1 (
    npx -y mcp-add --name mem0-mcp --type http --url "https://mcp.mem0.ai/mcp/" --clients cursor
  ) else (
    echo npx not found. Add Mem0 MCP manually: https://docs.mem0.ai/integrations/cursor
  )
)
goto :eof

:write_mem0_rule
if /i not "!AGENT!"=="cursor" goto :eof
call :ensure_dir "%CURSOR_HOME%\rules"
(
  echo ---
  echo description: Mem0 persistent memory for AI agents
  echo alwaysApply: true
  echo ---
  echo.
  echo Use Mem0 MCP tools proactively to maintain long-term memory across sessions.
  echo.
  echo RECALL ^(search_memories^): At the start of a task, search for relevant past context.
  echo.
  echo STORE ^(add_memory^): Store errors resolved, architecture decisions, user preferences, and completed tasks.
  echo.
  echo Do NOT store trivial details, ephemeral state, or information already in project docs.
  echo Restart Cursor after MCP config changes. Verify: search_memories for project setup.
) > "%CURSOR_HOME%\rules\mem0.mdc"
echo Mem0 Cursor rule installed.
goto :eof

:merge_mcp_command
REM %1 name  %2 command  %3 arg
set "MCP_NAME=%~1"
set "MCP_CMD=%~2"
set "MCP_ARG=%~3"
call :ensure_dir "%CURSOR_HOME%"
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$f = Join-Path $env:USERPROFILE '.cursor\mcp.json'; $dir = Split-Path $f; New-Item -ItemType Directory -Force -Path $dir | Out-Null; $data = @{ mcpServers = @{} }; if (Test-Path $f) { try { $data = Get-Content -Raw -LiteralPath $f | ConvertFrom-Json } catch {} }; if (-not $data.mcpServers) { $data | Add-Member mcpServers (@{}) -Force }; $entry = @{ command = $env:MCP_CMD; args = @($env:MCP_ARG); env = @{} }; $data.mcpServers | Add-Member -NotePropertyName $env:MCP_NAME -NotePropertyValue $entry -Force; ($data | ConvertTo-Json -Depth 10) + [Environment]::NewLine | Set-Content -Encoding utf8 -LiteralPath $f"
goto :eof

:merge_mcp_mem0
call :ensure_dir "%CURSOR_HOME%"
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$f = Join-Path $env:USERPROFILE '.cursor\mcp.json'; $dir = Split-Path $f; New-Item -ItemType Directory -Force -Path $dir | Out-Null; $data = @{ mcpServers = @{} }; if (Test-Path $f) { try { $data = Get-Content -Raw -LiteralPath $f | ConvertFrom-Json } catch {} }; if (-not $data.mcpServers) { $data | Add-Member mcpServers (@{}) -Force }; $entry = @{ url = 'https://mcp.mem0.ai/mcp/'; headers = @{ Authorization = 'Token ${env:MEM0_API_KEY}' } }; $data.mcpServers | Add-Member -NotePropertyName 'mem0' -NotePropertyValue $entry -Force; ($data | ConvertTo-Json -Depth 10) + [Environment]::NewLine | Set-Content -Encoding utf8 -LiteralPath $f"
goto :eof

:merge_mcp_graphify
set "GPY_CMD=%~1"
set "GRAPH_JSON=%~2"
call :ensure_dir "%CURSOR_HOME%"
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$f = Join-Path $env:USERPROFILE '.cursor\mcp.json'; $dir = Split-Path $f; New-Item -ItemType Directory -Force -Path $dir | Out-Null; $data = @{ mcpServers = @{} }; if (Test-Path $f) { try { $data = Get-Content -Raw -LiteralPath $f | ConvertFrom-Json } catch {} }; if (-not $data.mcpServers) { $data | Add-Member mcpServers (@{}) -Force }; $entry = @{ command = $env:GPY_CMD; args = @('-m','graphify.serve', $env:GRAPH_JSON) }; $data.mcpServers | Add-Member -NotePropertyName 'graphify' -NotePropertyValue $entry -Force; ($data | ConvertTo-Json -Depth 10) + [Environment]::NewLine | Set-Content -Encoding utf8 -LiteralPath $f"
goto :eof

:setup_docs
if /i "!DOCS_TOOL!"=="qmd" (
  echo.
  echo Setting up QMD...
  call :setup_qmd
  if errorlevel 1 exit /b 1
  goto :eof
)
if /i "!DOCS_TOOL!"=="graphify" (
  echo.
  echo Setting up Graphify...
  call :setup_graphify
  if errorlevel 1 exit /b 1
  goto :eof
)
echo.
echo Skipping QMD and Graphify.
goto :eof

:node_major
set "NODE_MAJOR=0"
call :command_exists node
if errorlevel 1 goto :eof
for /f "delims=" %%V in ('node -p "process.versions.node.split(\".\")[0]" 2^>nul') do set "NODE_MAJOR=%%V"
goto :eof

:ensure_node
call :node_major
if !NODE_MAJOR! GEQ 22 (
  call :command_exists npm
  if not errorlevel 1 exit /b 0
)
echo Node.js/npm 22+ is required for QMD ^(found major=!NODE_MAJOR!^).
call :ask_permission "Install Node.js 22+ with winget?" "INSTALL_NODEJS"
if errorlevel 1 (
  echo Install Node.js 22+ manually, then re-run.
  exit /b 1
)
call :command_exists winget
if errorlevel 1 (
  echo winget not found. Install Node.js from https://nodejs.org then re-run.
  exit /b 1
)
echo Installing Node.js via winget...
winget install -e --id OpenJS.NodeJS.LTS --accept-package-agreements --accept-source-agreements
call :refresh_path
call :node_major
if !NODE_MAJOR! LSS 22 (
  echo Node.js 22+ installation did not complete. Open a new Command Prompt and re-run.
  exit /b 1
)
goto :eof

:setup_qmd
call :ensure_node
if errorlevel 1 exit /b 1
call :refresh_path
call :command_exists qmd
if errorlevel 1 (
  echo Installing QMD globally...
  npm install -g @tobilu/qmd
  if errorlevel 1 (
    echo Failed to install @tobilu/qmd
    exit /b 1
  )
) else (
  echo QMD already installed.
)
powershell -NoProfile -Command "$s = (Split-Path -Leaf (Get-Location)).ToLower() -replace '[^a-z0-9]+','-'; $s = $s.Trim('-'); if (-not $s) { $s = 'project' }; Write-Output $s" > "%TEMP%\aiopt_slug.txt"
set /p PROJECT_SLUG=<"%TEMP%\aiopt_slug.txt"
set "QMD_COLLECTION=!PROJECT_SLUG!-docs"

if not exist "docs" (
  echo No docs\ directory found. Create one?
  set /p YN=Create docs\? [y/N]: 
  call :is_yes "!YN!"
  if "!IS_YES!"=="1" (
    mkdir docs
    echo Created docs\ directory.
  )
)
if exist "docs" (
  qmd collection list 2>nul | findstr /i /c:"!QMD_COLLECTION!" >nul
  if errorlevel 1 (
    echo Adding docs\ as QMD collection '!QMD_COLLECTION!'...
    qmd collection add ./docs --name "!QMD_COLLECTION!" --mask "**/*.md"
    qmd context add "qmd://!QMD_COLLECTION!" "Project documentation and notes"
  ) else (
    echo QMD collection '!QMD_COLLECTION!' already exists.
  )
  dir /s /b docs\*.md >nul 2>&1
  if not errorlevel 1 (
    echo Updating '!QMD_COLLECTION!' for semantic search...
    qmd update
    qmd embed
  ) else (
    echo No markdown under docs\ yet. Skipping embed.
    echo When docs exist, run: qmd update ^&^& qmd embed
  )
)
if exist ".git" (
  echo Setting up Git hook for QMD re-embedding...
  call :ensure_dir ".git\hooks"
  (
    echo #!/bin/sh
    echo # Auto re-embed docs with QMD after each commit ^(!QMD_COLLECTION!^)
    echo if command -v qmd ^>/dev/null 2^>^&1; then
    echo   if [ -d "docs" ]; then
    echo     echo "Updating QMD collection '!QMD_COLLECTION!' and embeddings..."
    echo     qmd update
    echo     qmd embed
    echo   fi
    echo fi
  ) > ".git\hooks\post-commit"
  echo Git hook installed: .git\hooks\post-commit
) else (
  echo No .git directory found. Skipping Git hook setup.
)
goto :eof

:setup_graphify
set "GRAPHIFY_READY=no"
call :ensure_python
if errorlevel 1 (
  echo Skipping Graphify until Python 3 is installed.
  exit /b 0
)
call :install_graphify_cli
if errorlevel 1 (
  echo Skipping Graphify.
  exit /b 0
)
call :refresh_path
call :add_python_user_scripts
call :command_exists graphify
if errorlevel 1 (
  echo graphify not on PATH after install.
  echo Open a NEW Command Prompt and re-run setup.bat, or add Python Scripts to PATH.
  exit /b 0
)
set "GRAPHIFY_READY=yes"
echo Running: graphify install
graphify install
if exist ".git" (
  echo Setting up Git hook for Graphify graph rebuild...
  graphify hook install
) else (
  echo No .git directory found. Skipping Graphify git hook setup.
)
set "GRAPH_JSON=%CD%\graphify-out\graph.json"
if not exist "%GRAPH_JSON%" (
  echo.
  echo No graphify-out\graph.json yet. Build knowledge graph now?
  if defined BUILD_GRAPHIFY (
    echo Using BUILD_GRAPHIFY=!BUILD_GRAPHIFY! from environment.
  ) else (
    set /p BG=Build now? [y/N]: 
    call :is_yes "!BG!"
    if "!IS_YES!"=="1" (set "BUILD_GRAPHIFY=yes") else (set "BUILD_GRAPHIFY=no")
  )
  call :is_yes "!BUILD_GRAPHIFY!"
  if "!IS_YES!"=="1" (
    echo Running: graphify .
    graphify .
  ) else (
    echo Skipping graph build. Later: graphify .
  )
) else (
  echo Found existing graph: !GRAPH_JSON!
)
if /i not "!AGENT!"=="cursor" goto :eof
echo Configuring Cursor integration: graphify cursor install
graphify cursor install
call :write_graphify_rule
call :is_yes "!GRAPHIFY_MCP!"
if not "!IS_YES!"=="1" (
  echo Skipping Graphify MCP registration ^(GRAPHIFY_MCP=no^). Use CLI: graphify query / graphify path
  goto :eof
)
call :resolve_graphify_python
echo Registering Graphify MCP in %MCP_FILE%
echo   python: !GPY!
echo   graph:  !GRAPH_JSON!
set "GPY_CMD=!GPY!"
call :merge_mcp_graphify "!GPY!" "!GRAPH_JSON!"
if not exist "!GRAPH_JSON!" echo MCP is registered but graph.json is missing until you run: graphify .
goto :eof

:install_graphify_cli
call :command_exists graphify
if not errorlevel 1 (
  echo Graphify already present.
  exit /b 0
)
call :is_yes "!GRAPHIFY_MCP!"
if "!IS_YES!"=="1" (set "GPKG=graphifyy[mcp]") else (set "GPKG=graphifyy")
call :command_exists pipx
if not errorlevel 1 (
  echo Installing Graphify via pipx ^(!GPKG!^)...
  pipx install "!GPKG!"
  if not errorlevel 1 exit /b 0
)
echo Installing Graphify via pip --user ^(!GPKG!^)...
"%PYTHON%" -m pip install --user --upgrade "!GPKG!"
if errorlevel 1 (
  echo Failed to install !GPKG!.
  echo If pip is missing: "%PYTHON%" -m ensurepip --upgrade
  echo Then: "%PYTHON%" -m pip install --user "!GPKG!"
  exit /b 1
)
call :add_python_user_scripts
goto :eof

:resolve_graphify_python
set "GPY="
if exist "%USERPROFILE%\.local\pipx\venvs\graphifyy\Scripts\python.exe" set "GPY=%USERPROFILE%\.local\pipx\venvs\graphifyy\Scripts\python.exe"
if exist "%LOCALAPPDATA%\pipx\venvs\graphifyy\Scripts\python.exe" set "GPY=%LOCALAPPDATA%\pipx\venvs\graphifyy\Scripts\python.exe"
if defined GPY goto :eof
call :find_python
set "GPY=!PYTHON!"
goto :eof

:write_graphify_rule
if /i not "!AGENT!"=="cursor" goto :eof
call :ensure_dir "%CURSOR_HOME%\rules"
(
  echo ---
  echo description: Graphify knowledge graph + MCP tools
  echo alwaysApply: true
  echo ---
  echo.
  echo ## Graphify ^(knowledge graph^)
  echo.
  echo - Build once per codebase: graphify .  -^>  graphify-out/graph.json ^(required before MCP works^).
  echo - Prefer MCP tools when available: query_graph, get_node, get_neighbors, shortest_path.
  echo - CLI fallback: graphify query / graphify path / graphify explain
  echo.
  echo When asked how modules/files/definitions relate, prefer Graphify over ad-hoc grepping.
) > "%CURSOR_HOME%\rules\graphify.mdc"
echo Graphify Cursor rule installed.
goto :eof

:write_cursor_compression_rule
if /i not "!AGENT!"=="cursor" goto :eof
call :ensure_dir "%CURSOR_HOME%\rules"
set "DOCS_LINE="
set "MEMORY_LINE="
if /i "!DOCS_TOOL!"=="qmd" set "DOCS_LINE=- Project documentation: prefer qmd search / qmd query before reading many .md files."
if /i "!DOCS_TOOL!"=="graphify" if /i "!GRAPHIFY_READY!"=="yes" set "DOCS_LINE=- Codebase relationships: prefer Graphify MCP (query_graph, get_neighbors, shortest_path) or CLI (graphify query / graphify path)."
if /i "!MEMORY_TOOL!"=="icm" set "MEMORY_LINE=- Cross-session memory: use ICM MCP tools (icm_memory_recall, icm_memory_store) or CLI (icm recall, icm store)."
if /i "!MEMORY_TOOL!"=="mem0" set "MEMORY_LINE=- Cross-session memory: use Mem0 MCP tools (search_memories, add_memory, get_memories)."
powershell -NoProfile -ExecutionPolicy Bypass -Command "$p = Join-Path $env:USERPROFILE '.cursor\rules\compression.mdc'; $docs = $env:DOCS_LINE; $mem = $env:MEMORY_LINE; $lines = @('---','description: Token optimization defaults (RTK, memory, docs)','alwaysApply: true','---','','## Optimization defaults','','- Large shell file reads: prefer rtk read over cat / head when using Shell.'); if ($docs) { $lines += $docs }; if ($mem) { $lines += $mem }; $lines += '- Do not stack redundant compression (RTK already compresses Shell output via hooks).'; Set-Content -Encoding utf8 -Path $p -Value $lines"
echo Cursor optimizer rule installed.
goto :eof

:write_agents_file
set "RULE_FILE=AGENTS.md"
if exist "GEMINI.md" set "RULE_FILE=GEMINI.md"
if /i "!AGENT!"=="antigravity" if not exist "AGENTS.md" set "RULE_FILE=GEMINI.md"
if not exist "!RULE_FILE!" (
  echo Creating !RULE_FILE!...
  echo # !RULE_FILE!> "!RULE_FILE!"
  echo.>> "!RULE_FILE!"
  call :append_opt_section "!RULE_FILE!"
  goto :eof
)
findstr /c:"## Optimization Utilities" "!RULE_FILE!" >nul 2>&1
if not errorlevel 1 (
  echo !RULE_FILE! already has an Optimization Utilities section.
  goto :eof
)
findstr /c:"## Compression Utilities" "!RULE_FILE!" >nul 2>&1
if not errorlevel 1 (
  echo !RULE_FILE! already has a Compression Utilities section.
  goto :eof
)
echo Appending optimization section to !RULE_FILE!...
call :append_opt_section "!RULE_FILE!"
goto :eof

:append_opt_section
set "TARGET=%~1"
>> "%TARGET%" echo.
>> "%TARGET%" echo ## Optimization Utilities
>> "%TARGET%" echo.
>> "%TARGET%" echo The following utilities are available in this environment. Agents should consider them core tools and utilize them when possible to optimize context, memory, and token usage.
>> "%TARGET%" echo.
>> "%TARGET%" echo - **RTK**
>> "%TARGET%" echo   Global utility for compressing CLI outputs before they reach the agent.
if /i "!MEMORY_TOOL!"=="icm" (
  >> "%TARGET%" echo - **ICM**
  >> "%TARGET%" echo   Local cross-session memory ^(SQLite^). Use icm_memory_recall / icm_memory_store or icm recall / icm store.
)
if /i "!MEMORY_TOOL!"=="mem0" (
  >> "%TARGET%" echo - **Mem0**
  >> "%TARGET%" echo   Cloud cross-session memory via MCP. Use search_memories / add_memory.
)
if /i "!DOCS_TOOL!"=="qmd" (
  >> "%TARGET%" echo - **QMD**
  >> "%TARGET%" echo   Semantic search over docs\. Collection: !QMD_COLLECTION! -^> qmd://!QMD_COLLECTION!
)
if /i "!DOCS_TOOL!"=="graphify" if /i "!GRAPHIFY_READY!"=="yes" (
  >> "%TARGET%" echo - **Graphify**
  >> "%TARGET%" echo   Local knowledge graph. Build once with graphify . -^> graphify-out\graph.json. Prefer query_graph / get_neighbors / shortest_path.
)
>> "%TARGET%" echo ---
goto :eof

:print_summary
echo.
echo Setup complete for agent: !AGENT!
echo    Memory tool: !MEMORY_TOOL!
echo    Docs tool: !DOCS_TOOL!
if /i "!DOCS_TOOL!"=="qmd" echo    QMD collection: !QMD_COLLECTION! ^(qmd://!QMD_COLLECTION!^)
if /i "!DOCS_TOOL!"=="graphify" if /i "!GRAPHIFY_READY!"=="yes" echo    Graphify MCP: !GRAPHIFY_MCP!
if /i "!DOCS_TOOL!"=="graphify" if /i not "!GRAPHIFY_READY!"=="yes" echo    Graphify: NOT installed ^(install Python 3, then re-run setup.bat^)
echo.
if /i "!AGENT!"=="cursor" (
  echo Next steps for Cursor / Cursor CLI:
  echo   1. Restart Cursor so MCP picks up %MCP_FILE%.
  echo   2. Open a NEW Command Prompt so PATH includes "%LOCAL_BIN%".
  if /i "!MEMORY_TOOL!"=="icm" echo   3. Verify ICM: icm recall "project setup"
  if /i "!MEMORY_TOOL!"=="mem0" echo   3. Verify Mem0: search_memories for "project setup"
  if /i "!DOCS_TOOL!"=="qmd" echo   4. Verify QMD: qmd search "topic" -c !QMD_COLLECTION!
  if /i "!DOCS_TOOL!"=="graphify" if /i not "!GRAPHIFY_READY!"=="yes" (
    echo   4. Install Python 3: winget install -e --id Python.Python.3.12
    echo      Tick "Add python.exe to PATH", open a NEW Command Prompt, re-run setup.bat
  )
  if /i "!DOCS_TOOL!"=="graphify" if /i "!GRAPHIFY_READY!"=="yes" if /i "!GRAPHIFY_MCP!"=="yes" (
    echo   4. Build graph if needed: graphify .
    echo      Restart Cursor, then verify MCP tool query_graph
  )
  if /i "!DOCS_TOOL!"=="graphify" if /i "!GRAPHIFY_READY!"=="yes" if /i not "!GRAPHIFY_MCP!"=="yes" (
    echo   4. Build graph if needed: graphify .
    echo      Verify CLI: graphify query "how is X related to Y"
  )
)
goto :eof
