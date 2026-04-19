@echo off
setlocal enabledelayedexpansion

:: ============================================================
:: replicate_ml_setup.bat
:: ============================================================
:: Run this on any machine that has:
::   - SurrealDB v3.x running with RocksDB
::   - vitasalesbackup[1].surql already imported
::
:: This script will:
::   1. Convert lgbm.onnx -> lgbm.surml  (skipped if already exists)
::   2. Import the ML model into SurrealDB RocksDB
::   3. Define fn::score_lead() function
::   4. Define events on lead + conversation tables
::
:: After this runs, every new/updated lead is auto-scored
:: and the close_probability is written to lead.ai_confidence
::
:: Usage:
::   replicate_ml_setup.bat
::   replicate_ml_setup.bat http://your-server:8000 root root vitasales vitasales
:: ============================================================

:: ── Configuration (override via command line args) ──────────
set ENDPOINT=%~1
set USERNAME=%~2
set PASSWORD=%~3
set NAMESPACE=%~4
set DATABASE=%~5

if "%ENDPOINT%"==""  set ENDPOINT=http://localhost:8000
if "%USERNAME%"==""  set USERNAME=root
if "%PASSWORD%"==""  set PASSWORD=root
if "%NAMESPACE%"=="" set NAMESPACE=vitasales
if "%DATABASE%"==""  set DATABASE=vitasales

:: ── Paths ────────────────────────────────────────────────────
set SCRIPT_DIR=%~dp0
set ONNX_PATH=%SCRIPT_DIR%models\lgbm.onnx
set SURML_PATH=%SCRIPT_DIR%models\lgbm.surml
set SETUP_SQL=%SCRIPT_DIR%setup_ml.surql
set CONVERT_PY=%SCRIPT_DIR%convert_to_surml.py

echo.
echo ============================================================
echo  Vitasales ML Scoring Setup
echo ============================================================
echo  Endpoint  : %ENDPOINT%
echo  Namespace : %NAMESPACE%
echo  Database  : %DATABASE%
echo ============================================================
echo.

:: ── Step 1: Check SurrealDB is reachable ─────────────────────
echo [1/4] Checking SurrealDB is reachable...
curl -s -o nul -w "%%{http_code}" %ENDPOINT%/health > %TEMP%\surreal_health.txt 2>&1
set /p HEALTH_CODE=<%TEMP%\surreal_health.txt
if not "%HEALTH_CODE%"=="200" (
    echo.
    echo  ERROR: SurrealDB not reachable at %ENDPOINT%
    echo  Make sure the server is running:
    echo    surreal start --user root --pass root --bind 0.0.0.0:8000 "rocksdb:///path/to/data"
    echo.
    exit /b 1
)
echo  OK - SurrealDB is up at %ENDPOINT%
echo.

:: ── Step 2: Convert ONNX to SURML ────────────────────────────
echo [2/4] Preparing ML model...
if exist "%SURML_PATH%" (
    echo  SKIP - lgbm.surml already exists
) else (
    if not exist "%ONNX_PATH%" (
        echo  ERROR: lgbm.onnx not found at %ONNX_PATH%
        exit /b 1
    )
    echo  Converting lgbm.onnx to lgbm.surml...
    python "%CONVERT_PY%"
    if errorlevel 1 (
        echo  ERROR: Conversion failed. Make sure Python is installed.
        exit /b 1
    )
    echo  OK - lgbm.surml created
)
echo.

:: ── Step 3: Import ML model into RocksDB ─────────────────────
echo [3/4] Importing ML model into SurrealDB RocksDB...
curl -s -o %TEMP%\ml_import_result.txt -w "%%{http_code}" ^
    -X POST %ENDPOINT%/ml/import ^
    -H "surreal-ns: %NAMESPACE%" ^
    -H "surreal-db: %DATABASE%" ^
    -u "%USERNAME%:%PASSWORD%" ^
    --data-binary @"%SURML_PATH%" > %TEMP%\ml_import_code.txt 2>&1

set /p ML_CODE=<%TEMP%\ml_import_code.txt
set /p ML_RESULT=<%TEMP%\ml_import_result.txt

if "%ML_CODE%"=="200" (
    echo  OK - Model imported and stored in RocksDB
) else (
    echo  ERROR: Model import failed  HTTP %ML_CODE%
    echo  Response: %ML_RESULT%
    exit /b 1
)
echo.

:: ── Step 4: Apply function + events ──────────────────────────
echo [4/4] Applying fn::score_lead + events...

if not exist "%SETUP_SQL%" (
    echo  ERROR: setup_ml.surql not found at %SETUP_SQL%
    exit /b 1
)

:: Remove existing definitions first (idempotent re-run)
curl -s -o nul ^
    -X POST %ENDPOINT%/sql ^
    -H "surreal-ns: %NAMESPACE%" ^
    -H "surreal-db: %DATABASE%" ^
    -u "%USERNAME%:%PASSWORD%" ^
    -d "REMOVE FUNCTION IF EXISTS fn::score_lead; REMOVE EVENT IF EXISTS score_on_lead_change ON TABLE lead; REMOVE EVENT IF EXISTS score_on_conv_change ON TABLE conversation;" > nul 2>&1

:: Apply setup
curl -s -o %TEMP%\setup_result.txt -w "%%{http_code}" ^
    -X POST %ENDPOINT%/sql ^
    -H "surreal-ns: %NAMESPACE%" ^
    -H "surreal-db: %DATABASE%" ^
    -u "%USERNAME%:%PASSWORD%" ^
    --data-binary @"%SETUP_SQL%" > %TEMP%\setup_code.txt 2>&1

set /p SETUP_CODE=<%TEMP%\setup_code.txt

if "%SETUP_CODE%"=="200" (
    echo  OK - fn::score_lead defined
    echo  OK - score_on_lead_change event defined
    echo  OK - score_on_conv_change event defined
) else (
    echo  ERROR: Setup SQL failed  HTTP %SETUP_CODE%
    type %TEMP%\setup_result.txt
    exit /b 1
)
echo.

:: ── Smoke test ───────────────────────────────────────────────
echo [VERIFY] Running smoke test...
curl -s -o %TEMP%\smoke_result.txt ^
    -X POST %ENDPOINT%/sql ^
    -H "surreal-ns: %NAMESPACE%" ^
    -H "surreal-db: %DATABASE%" ^
    -u "%USERNAME%:%PASSWORD%" ^
    -d "LET $lid = (SELECT id FROM lead LIMIT 1)[0].id; RETURN fn::score_lead($lid);" 2>&1

set /p SMOKE=<%TEMP%\smoke_result.txt
echo  Score for first lead: %SMOKE%
echo.

echo ============================================================
echo  Setup complete. All components stored in RocksDB.
echo ============================================================
echo.
echo  Everything survives server restarts - no re-setup needed.
echo.
echo  Test with:
echo    curl -X POST %ENDPOINT%/sql ^
echo      -H "surreal-ns: %NAMESPACE%" -H "surreal-db: %DATABASE%" ^
echo      -u "%USERNAME%:%PASSWORD%" ^
echo      -d "SELECT id, state, ai_confidence FROM lead LIMIT 5;"
echo.
endlocal
