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
::   1. Convert lgbm.onnx -> lgbm.surml          (existing close_prob model)
::   2. Convert 3 new models -> .surml            (consumer, interaction, product-quotation)
::   3. Import all 4 ML models into SurrealDB RocksDB
::   4. Define fn::score_lead() + all scoring functions + events
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
set ONNX_PATH=%SCRIPT_DIR%models\lgbm.onnx
set SURML_PATH=%SCRIPT_DIR%models\lgbm.surml
set SETUP_SQL=%SCRIPT_DIR%setup_ml.surql
set CONVERT_PY=%SCRIPT_DIR%convert_to_surml.py
set CONVERT_ALL_PY=%SCRIPT_DIR%convert_all_to_surml.py

:: New model ONNX paths
set CONSUMER_ONNX=%SCRIPT_DIR%models\consumer-model\lgbm.onnx
set INTERACTION_ONNX=%SCRIPT_DIR%models\interaction-model\lgbm.onnx
set PRODUCT_ONNX=%SCRIPT_DIR%models\product-quotation-model\lgbm.onnx

:: New model SURML output paths (each in its own subfolder)
set CONSUMER_SURML=%SCRIPT_DIR%models\consumer-model\consumer_score.surml
set INTERACTION_SURML=%SCRIPT_DIR%models\interaction-model\interaction_score.surml
set PRODUCT_SURML=%SCRIPT_DIR%models\product-quotation-model\product_quotation_score.surml

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
echo [1/7] Checking SurrealDB is reachable...
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

:: ── Step 2: Convert lgbm.onnx -> lgbm.surml ──────────────────
echo [2/7] Preparing close_prob model (lgbm)...
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

:: ── Step 3: Convert 3 new models via convert_all_to_surml.py ─
echo [3/7] Preparing 3 new scoring models...

:: consumer_score
if exist "%CONSUMER_SURML%" (
    echo  SKIP - consumer_score.surml already exists
) else if not exist "%CONSUMER_ONNX%" (
    echo  WARN - consumer_score.onnx not found, skipping consumer_score
) else (
    python "%CONVERT_ALL_PY%" consumer_score
    if errorlevel 1 ( echo  ERROR: consumer_score conversion failed. & exit /b 1 )
    echo  OK - consumer_score.surml created in models\costermer-model\
)

:: interaction_score
if exist "%INTERACTION_SURML%" (
    echo  SKIP - interaction_score.surml already exists
) else if not exist "%INTERACTION_ONNX%" (
    echo  WARN - interaction_score.onnx not found, skipping interaction_score
) else (
    python "%CONVERT_ALL_PY%" interaction_score
    if errorlevel 1 ( echo  ERROR: interaction_score conversion failed. & exit /b 1 )
    echo  OK - interaction_score.surml created in models\interaction-model\
)

:: product_quotation_score
if exist "%PRODUCT_SURML%" (
    echo  SKIP - product_quotation_score.surml already exists
) else if not exist "%PRODUCT_ONNX%" (
    echo  WARN - product_quotation_score.onnx not found, skipping product_quotation_score
) else (
    python "%CONVERT_ALL_PY%" product_quotation_score
    if errorlevel 1 ( echo  ERROR: product_quotation_score conversion failed. & exit /b 1 )
    echo  OK - product_quotation_score.surml created in models\product-quotation\
)
echo.

:: ── Step 4: Import close_prob model into RocksDB ─────────────
echo [4/7] Importing close_prob (lgbm) model...
curl -s -o %TEMP%\ml_import_result.txt -w "%%{http_code}" ^
    -X POST %ENDPOINT%/ml/import ^
    -H "surreal-ns: %NAMESPACE%" ^
    -H "surreal-db: %DATABASE%" ^
    -u "%USERNAME%:%PASSWORD%" ^
    --data-binary @"%SURML_PATH%" > %TEMP%\ml_import_code.txt 2>&1

set /p ML_CODE=<%TEMP%\ml_import_code.txt
if "%ML_CODE%"=="200" (
    echo  OK - close_prob model imported
) else (
    echo  ERROR: close_prob import failed  HTTP %ML_CODE%
    type %TEMP%\ml_import_result.txt
    exit /b 1
)
echo.

:: ── Step 5: Import 3 new models into RocksDB ─────────────────
echo [5/7] Importing 3 new scoring models...

if exist "%CONSUMER_SURML%" (
    curl -s -o %TEMP%\ml_consumer_result.txt -w "%%{http_code}" ^
        -X POST %ENDPOINT%/ml/import ^
        -H "surreal-ns: %NAMESPACE%" ^
        -H "surreal-db: %DATABASE%" ^
        -u "%USERNAME%:%PASSWORD%" ^
        --data-binary @"%CONSUMER_SURML%" > %TEMP%\ml_consumer_code.txt 2>&1
    set /p C_CODE=<%TEMP%\ml_consumer_code.txt
    if "!C_CODE!"=="200" (
        echo  OK - consumer_score model imported
    ) else (
        echo  ERROR: consumer_score import failed  HTTP !C_CODE!
        exit /b 1
    )
) else (
    echo  SKIP - consumer_score.surml not found
)

if exist "%INTERACTION_SURML%" (
    curl -s -o %TEMP%\ml_interaction_result.txt -w "%%{http_code}" ^
        -X POST %ENDPOINT%/ml/import ^
        -H "surreal-ns: %NAMESPACE%" ^
        -H "surreal-db: %DATABASE%" ^
        -u "%USERNAME%:%PASSWORD%" ^
        --data-binary @"%INTERACTION_SURML%" > %TEMP%\ml_interaction_code.txt 2>&1
    set /p I_CODE=<%TEMP%\ml_interaction_code.txt
    if "!I_CODE!"=="200" (
        echo  OK - interaction_score model imported
    ) else (
        echo  ERROR: interaction_score import failed  HTTP !I_CODE!
        exit /b 1
    )
) else (
    echo  SKIP - interaction_score.surml not found
)

if exist "%PRODUCT_SURML%" (
    curl -s -o %TEMP%\ml_product_result.txt -w "%%{http_code}" ^
        -X POST %ENDPOINT%/ml/import ^
        -H "surreal-ns: %NAMESPACE%" ^
        -H "surreal-db: %DATABASE%" ^
        -u "%USERNAME%:%PASSWORD%" ^
        --data-binary @"%PRODUCT_SURML%" > %TEMP%\ml_product_code.txt 2>&1
    set /p P_CODE=<%TEMP%\ml_product_code.txt
    if "!P_CODE!"=="200" (
        echo  OK - product_quotation_score model imported
    ) else (
        echo  ERROR: product_quotation_score import failed  HTTP !P_CODE!
        exit /b 1
    )
) else (
    echo  SKIP - product_quotation_score.surml not found ^(run train_models.py first^)
)
echo.
echo.

:: ── Step 6: Apply function + events ──────────────────────────
echo [6/7] Applying scoring functions + events...

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
    -d "REMOVE FUNCTION IF EXISTS fn::score_lead; REMOVE FUNCTION IF EXISTS fn::score_consumer; REMOVE FUNCTION IF EXISTS fn::score_interaction; REMOVE FUNCTION IF EXISTS fn::score_product_quotation; REMOVE EVENT IF EXISTS score_on_lead_change ON TABLE lead; REMOVE EVENT IF EXISTS score_on_conv_change ON TABLE conversation; REMOVE EVENT IF EXISTS score_consumer_on_lead_change ON TABLE lead; REMOVE EVENT IF EXISTS score_consumer_on_conv_change ON TABLE conversation; REMOVE EVENT IF EXISTS score_interaction_on_lead_change ON TABLE lead; REMOVE EVENT IF EXISTS score_interaction_on_conv_change ON TABLE conversation; REMOVE EVENT IF EXISTS score_product_quotation_on_lead_change ON TABLE lead; REMOVE EVENT IF EXISTS score_product_quotation_on_quotation_created ON TABLE generated_quotation;" > nul 2>&1

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
    echo  OK - All events defined
) else (
    echo  ERROR: Setup SQL failed  HTTP %SETUP_CODE%
    type %TEMP%\setup_result.txt
    exit /b 1
)
echo.

:: ── Step 7: Smoke tests ───────────────────────────────────────
echo [7/7] Running smoke tests...

curl -s -o %TEMP%\smoke_result.txt ^
    -X POST %ENDPOINT%/sql ^
    -H "surreal-ns: %NAMESPACE%" ^
    -H "surreal-db: %DATABASE%" ^
    -u "%USERNAME%:%PASSWORD%" ^
    -d "USE NS %NAMESPACE%; USE DB %DATABASE%; LET $lid = (SELECT VALUE id FROM lead LIMIT 1)[0]; IF $lid != NONE THEN RETURN { close_prob: fn::score_lead($lid), consumer: fn::score_consumer($lid), interaction: fn::score_interaction($lid), product_quotation: fn::score_product_quotation($lid) } ELSE RETURN 'No leads found in table' END;" 2>&1

set /p SMOKE=<%TEMP%\smoke_result.txt
echo  Scores for first lead: %SMOKE%
echo.

echo ============================================================
echo  Setup complete. All models stored in RocksDB.
echo ============================================================
echo.
echo  Model locations:
echo    models\lgbm.surml                                   (close_prob)
echo    models\costermer-model\consumer_score.surml         (consumer_score)
echo    models\interaction-model\interaction_score.surml    (interaction_score)
echo    models\product-quotation\product_quotation_score.surml (product_quotation_score)
echo.
echo  Everything survives server restarts - no re-setup needed.
echo.
echo  Test with:
echo    curl -X POST %ENDPOINT%/sql ^
echo      -H "surreal-ns: %NAMESPACE%" -H "surreal-db: %DATABASE%" ^
echo      -u "%USERNAME%:%PASSWORD%" ^
echo      -d "SELECT id, state, ai_confidence, consumer_score, interaction_score, product_quotation_score FROM lead LIMIT 5;"
echo.
endlocal

