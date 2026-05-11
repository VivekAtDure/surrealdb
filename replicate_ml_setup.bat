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
::   1. Convert all 5 ONNX models -> .surml  (via convert_all_to_surml.py)
::   2. Import / update all 5 ML models into SurrealDB RocksDB
::      (models already loaded are automatically updated/replaced)
::   3. Define fn::score_lead() + all scoring functions + events
::
:: After this runs, every new/updated lead is auto-scored.
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
set SETUP_SQL=%SCRIPT_DIR%setup_ml.surql
set CONVERT_ALL_PY=%SCRIPT_DIR%convert_all_to_surml.py

:: ONNX source files
set DEAL_RISK_ONNX=%SCRIPT_DIR%models\Deal-Risk\close_prob_lgbm.onnx
set CONSUMER_ONNX=%SCRIPT_DIR%models\Consumer\consumer_score_lgbm.onnx
set INTERACTION_ONNX=%SCRIPT_DIR%models\Interaction\interaction_score_lgbm.onnx
set LEAD_QUAL_ONNX=%SCRIPT_DIR%models\Lead-Qualification\lead_qualification_lgbm.onnx
set PRODUCT_ONNX=%SCRIPT_DIR%models\Product-Quotation\product_quotation_lgbm.onnx

:: SURML output files
set DEAL_RISK_SURML=%SCRIPT_DIR%models\Deal-Risk\close_prob.surml
set CONSUMER_SURML=%SCRIPT_DIR%models\Consumer\consumer_score.surml
set INTERACTION_SURML=%SCRIPT_DIR%models\Interaction\interaction_score.surml
set LEAD_QUAL_SURML=%SCRIPT_DIR%models\Lead-Qualification\lead_qualification.surml
set PRODUCT_SURML=%SCRIPT_DIR%models\Product-Quotation\product_quotation_score.surml

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
echo [1/5] Checking SurrealDB is reachable...
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

:: ── Step 2: Convert all 5 ONNX models -> .surml ──────────────
echo [2/5] Converting all 5 models (ONNX -> SURML)...

:: Verify all 5 ONNX files exist before converting
set MISSING=0
if not exist "%DEAL_RISK_ONNX%"   ( echo  ERROR: Not found: %DEAL_RISK_ONNX%   & set MISSING=1 )
if not exist "%CONSUMER_ONNX%"    ( echo  ERROR: Not found: %CONSUMER_ONNX%    & set MISSING=1 )
if not exist "%INTERACTION_ONNX%" ( echo  ERROR: Not found: %INTERACTION_ONNX% & set MISSING=1 )
if not exist "%LEAD_QUAL_ONNX%"   ( echo  ERROR: Not found: %LEAD_QUAL_ONNX%   & set MISSING=1 )
if not exist "%PRODUCT_ONNX%"     ( echo  ERROR: Not found: %PRODUCT_ONNX%     & set MISSING=1 )
if "%MISSING%"=="1" (
    echo.
    echo  One or more ONNX files are missing. Aborting.
    exit /b 1
)

python "%CONVERT_ALL_PY%"
if errorlevel 1 (
    echo  ERROR: Model conversion failed. Make sure Python is installed.
    exit /b 1
)
echo  OK - All 5 .surml files created
echo.

:: ── Step 3: Import / update all 5 models into RocksDB ────────
echo [3/5] Importing / updating all 5 models in SurrealDB RocksDB...
echo  (existing models will be replaced automatically)
echo.

:: close_prob
set _HTTP_CODE=000
curl -s -o "%TEMP%\ml_import_body.txt" -w "%%{http_code}" 2>nul ^
    -X POST %ENDPOINT%/ml/import ^
    -H "surreal-ns: %NAMESPACE%" ^
    -H "surreal-db: %DATABASE%" ^
    -u "%USERNAME%:%PASSWORD%" ^
    --data-binary @"%DEAL_RISK_SURML%" > "%TEMP%\ml_import_code.txt"
set /p _HTTP_CODE=<"%TEMP%\ml_import_code.txt"
if "!_HTTP_CODE!"=="200" ( echo  OK - close_prob imported/updated ) else (
    echo  ERROR: close_prob import failed  HTTP !_HTTP_CODE!
    type "%TEMP%\ml_import_body.txt"
    exit /b 1
)

:: consumer_score
set _HTTP_CODE=000
curl -s -o "%TEMP%\ml_import_body.txt" -w "%%{http_code}" 2>nul ^
    -X POST %ENDPOINT%/ml/import ^
    -H "surreal-ns: %NAMESPACE%" ^
    -H "surreal-db: %DATABASE%" ^
    -u "%USERNAME%:%PASSWORD%" ^
    --data-binary @"%CONSUMER_SURML%" > "%TEMP%\ml_import_code.txt"
set /p _HTTP_CODE=<"%TEMP%\ml_import_code.txt"
if "!_HTTP_CODE!"=="200" ( echo  OK - consumer_score imported/updated ) else (
    echo  ERROR: consumer_score import failed  HTTP !_HTTP_CODE!
    type "%TEMP%\ml_import_body.txt"
    exit /b 1
)

:: interaction_score
set _HTTP_CODE=000
curl -s -o "%TEMP%\ml_import_body.txt" -w "%%{http_code}" 2>nul ^
    -X POST %ENDPOINT%/ml/import ^
    -H "surreal-ns: %NAMESPACE%" ^
    -H "surreal-db: %DATABASE%" ^
    -u "%USERNAME%:%PASSWORD%" ^
    --data-binary @"%INTERACTION_SURML%" > "%TEMP%\ml_import_code.txt"
set /p _HTTP_CODE=<"%TEMP%\ml_import_code.txt"
if "!_HTTP_CODE!"=="200" ( echo  OK - interaction_score imported/updated ) else (
    echo  ERROR: interaction_score import failed  HTTP !_HTTP_CODE!
    type "%TEMP%\ml_import_body.txt"
    exit /b 1
)

:: lead_qualification
set _HTTP_CODE=000
curl -s -o "%TEMP%\ml_import_body.txt" -w "%%{http_code}" 2>nul ^
    -X POST %ENDPOINT%/ml/import ^
    -H "surreal-ns: %NAMESPACE%" ^
    -H "surreal-db: %DATABASE%" ^
    -u "%USERNAME%:%PASSWORD%" ^
    --data-binary @"%LEAD_QUAL_SURML%" > "%TEMP%\ml_import_code.txt"
set /p _HTTP_CODE=<"%TEMP%\ml_import_code.txt"
if "!_HTTP_CODE!"=="200" ( echo  OK - lead_qualification imported/updated ) else (
    echo  ERROR: lead_qualification import failed  HTTP !_HTTP_CODE!
    type "%TEMP%\ml_import_body.txt"
    exit /b 1
)

:: product_quotation_score
set _HTTP_CODE=000
curl -s -o "%TEMP%\ml_import_body.txt" -w "%%{http_code}" 2>nul ^
    -X POST %ENDPOINT%/ml/import ^
    -H "surreal-ns: %NAMESPACE%" ^
    -H "surreal-db: %DATABASE%" ^
    -u "%USERNAME%:%PASSWORD%" ^
    --data-binary @"%PRODUCT_SURML%" > "%TEMP%\ml_import_code.txt"
set /p _HTTP_CODE=<"%TEMP%\ml_import_code.txt"
if "!_HTTP_CODE!"=="200" ( echo  OK - product_quotation_score imported/updated ) else (
    echo  ERROR: product_quotation_score import failed  HTTP !_HTTP_CODE!
    type "%TEMP%\ml_import_body.txt"
    exit /b 1
)

echo.

:: ── Step 4: Apply functions + events ─────────────────────────
echo [4/5] Applying scoring functions + events...

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
    -d "REMOVE FUNCTION IF EXISTS fn::score_lead; REMOVE FUNCTION IF EXISTS fn::score_consumer; REMOVE FUNCTION IF EXISTS fn::score_interaction; REMOVE FUNCTION IF EXISTS fn::score_product_quotation; REMOVE FUNCTION IF EXISTS fn::score_lead_qualification; REMOVE EVENT IF EXISTS score_on_lead_change ON TABLE lead; REMOVE EVENT IF EXISTS score_on_conv_change ON TABLE conversation; REMOVE EVENT IF EXISTS score_consumer_on_lead_change ON TABLE lead; REMOVE EVENT IF EXISTS score_consumer_on_conv_change ON TABLE conversation; REMOVE EVENT IF EXISTS score_interaction_on_lead_change ON TABLE lead; REMOVE EVENT IF EXISTS score_interaction_on_conv_change ON TABLE conversation; REMOVE EVENT IF EXISTS score_product_quotation_on_lead_change ON TABLE lead; REMOVE EVENT IF EXISTS score_product_quotation_on_quotation_created ON TABLE generated_quotation; REMOVE EVENT IF EXISTS score_lead_qualification_on_lead_change ON TABLE lead;" > nul 2>&1

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
    echo  OK - fn::score_consumer defined
    echo  OK - fn::score_interaction defined
    echo  OK - fn::score_product_quotation defined
    echo  OK - fn::score_lead_qualification defined
    echo  OK - All events defined
) else (
    echo  ERROR: Setup SQL failed  HTTP %SETUP_CODE%
    type %TEMP%\setup_result.txt
    exit /b 1
)
echo.

:: ── Step 5: Smoke tests ───────────────────────────────────────
echo [5/5] Running smoke tests...

curl -s -o %TEMP%\smoke_result.txt ^
    -X POST %ENDPOINT%/sql ^
    -H "surreal-ns: %NAMESPACE%" ^
    -H "surreal-db: %DATABASE%" ^
    -u "%USERNAME%:%PASSWORD%" ^
    -d "USE NS %NAMESPACE%; USE DB %DATABASE%; LET $lid = (SELECT VALUE id FROM lead LIMIT 1)[0]; IF $lid != NONE THEN RETURN { close_prob: fn::score_lead($lid), consumer: fn::score_consumer($lid), interaction: fn::score_interaction($lid), product_quotation: fn::score_product_quotation($lid), lead_qualification: fn::score_lead_qualification($lid) } ELSE RETURN 'No leads found in table' END;" 2>&1

set /p SMOKE=<%TEMP%\smoke_result.txt
echo  Scores for first lead: %SMOKE%
echo.

echo ============================================================
echo  Setup complete. All 5 models stored in RocksDB.
echo ============================================================
echo.
echo  Model locations:
echo    models\Deal-Risk\close_prob.surml                            (close_prob)
echo    models\Consumer\consumer_score.surml                         (consumer_score)
echo    models\Interaction\interaction_score.surml                   (interaction_score)
echo    models\Lead-Qualification\lead_qualification.surml           (lead_qualification)
echo    models\Product-Quotation\product_quotation_score.surml       (product_quotation_score)
echo.
echo  Everything survives server restarts - no re-setup needed.
echo  Re-run this script anytime to update models in RocksDB.
echo.
echo  Test with:
echo    curl -X POST %ENDPOINT%/sql ^
echo      -H "surreal-ns: %NAMESPACE%" -H "surreal-db: %DATABASE%" ^
echo      -u "%USERNAME%:%PASSWORD%" ^
echo      -d "SELECT id, state, ai_confidence, consumer_score, interaction_score, product_quotation_score FROM lead LIMIT 5;"
echo.
endlocal
exit /b 0
