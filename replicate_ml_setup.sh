#!/bin/bash
# ============================================================
# replicate_ml_setup.sh
# ============================================================
# Run this on any Ubuntu/Linux machine that has:
#   - SurrealDB v3.x running with RocksDB
#   - vitasalesbackup.surql already imported
#
# This script will:
#   1. Convert lgbm.onnx -> lgbm.surml  (skipped if already exists)
#   2. Import the ML model into SurrealDB RocksDB
#   3. Define fn::score_lead() function
#   4. Define events on lead + conversation tables
#
# Usage:
#   chmod +x replicate_ml_setup.sh
#   ./replicate_ml_setup.sh
#   ./replicate_ml_setup.sh http://your-server:8000 root root vitasales vitasales
# ============================================================

set -e

# ── Configuration (override via args) ────────────────────────
ENDPOINT="${1:-http://localhost:8000}"
USERNAME="${2:-root}"
PASSWORD="${3:-root}"
NAMESPACE="${4:-vitasales}"
DATABASE="${5:-vitasales}"

# ── Paths ─────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ONNX_PATH="$SCRIPT_DIR/models/lgbm.onnx"
SURML_PATH="$SCRIPT_DIR/models/lgbm.surml"
SETUP_SQL="$SCRIPT_DIR/setup_ml.surql"
CONVERT_PY="$SCRIPT_DIR/convert_to_surml.py"

# ── Colours ───────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e " ${GREEN}OK${NC} - $1"; }
fail() { echo -e " ${RED}ERROR${NC} - $1"; exit 1; }
skip() { echo -e " ${YELLOW}SKIP${NC} - $1"; }

echo ""
echo "============================================================"
echo " Vitasales ML Scoring Setup"
echo "============================================================"
echo " Endpoint  : $ENDPOINT"
echo " Namespace : $NAMESPACE"
echo " Database  : $DATABASE"
echo "============================================================"
echo ""

# ── Step 1: Check SurrealDB is reachable ──────────────────────
echo "[1/4] Checking SurrealDB is reachable..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$ENDPOINT/health")
if [ "$HTTP_CODE" != "200" ]; then
    fail "SurrealDB not reachable at $ENDPOINT (got HTTP $HTTP_CODE)\n  Start the server:\n  surreal start --user root --pass root --bind 0.0.0.0:8000 \"rocksdb:///path/to/data\""
fi
ok "SurrealDB is up at $ENDPOINT"
echo ""

# ── Step 2: Convert ONNX to SURML ─────────────────────────────
echo "[2/4] Preparing ML model..."
if [ -f "$SURML_PATH" ]; then
    skip "lgbm.surml already exists"
else
    [ -f "$ONNX_PATH" ] || fail "lgbm.onnx not found at $ONNX_PATH"

    # convert_to_surml.py only uses stdlib (os, struct) — no pip needed
    python3 "$CONVERT_PY" || fail "Conversion failed. Make sure python3 is installed."
    ok "lgbm.surml created"
fi
echo ""

# ── Step 3: Import ML model into RocksDB ──────────────────────
echo "[3/4] Importing ML model into SurrealDB RocksDB..."
ML_CODE=$(curl -s -o /tmp/ml_import_result.txt -w "%{http_code}" \
    -X POST "$ENDPOINT/ml/import" \
    -H "surreal-ns: $NAMESPACE" \
    -H "surreal-db: $DATABASE" \
    -u "$USERNAME:$PASSWORD" \
    --data-binary @"$SURML_PATH")

if [ "$ML_CODE" != "200" ]; then
    fail "Model import failed (HTTP $ML_CODE): $(cat /tmp/ml_import_result.txt)"
fi
ok "Model imported and stored in RocksDB"
echo ""

# ── Step 4: Apply function + events ───────────────────────────
echo "[4/4] Applying fn::score_lead + events..."
[ -f "$SETUP_SQL" ] || fail "setup_ml.surql not found at $SETUP_SQL"

# Drop existing definitions first (makes this script idempotent)
curl -s -o /dev/null \
    -X POST "$ENDPOINT/sql" \
    -H "surreal-ns: $NAMESPACE" \
    -H "surreal-db: $DATABASE" \
    -u "$USERNAME:$PASSWORD" \
    -d "REMOVE FUNCTION IF EXISTS fn::score_lead;
        REMOVE EVENT IF EXISTS score_on_lead_change ON TABLE lead;
        REMOVE EVENT IF EXISTS score_on_conv_change ON TABLE conversation;"

# Apply setup
SETUP_CODE=$(curl -s -o /tmp/setup_result.txt -w "%{http_code}" \
    -X POST "$ENDPOINT/sql" \
    -H "surreal-ns: $NAMESPACE" \
    -H "surreal-db: $DATABASE" \
    -u "$USERNAME:$PASSWORD" \
    --data-binary @"$SETUP_SQL")

if [ "$SETUP_CODE" != "200" ]; then
    fail "Setup SQL failed (HTTP $SETUP_CODE): $(cat /tmp/setup_result.txt)"
fi

# Check for ERR in response
if grep -q '"ERR"' /tmp/setup_result.txt; then
    fail "One or more SQL statements failed:\n$(cat /tmp/setup_result.txt)"
fi

ok "fn::score_lead defined"
ok "score_on_lead_change event defined"
ok "score_on_conv_change event defined"
echo ""

# ── Smoke test ────────────────────────────────────────────────
echo "[VERIFY] Running smoke test..."
SMOKE=$(curl -s \
    -X POST "$ENDPOINT/sql" \
    -H "surreal-ns: $NAMESPACE" \
    -H "surreal-db: $DATABASE" \
    -u "$USERNAME:$PASSWORD" \
    -d "LET \$lid = (SELECT id FROM lead LIMIT 1)[0].id; RETURN fn::score_lead(\$lid);" \
    | python3 -c "
import sys, json
d = json.load(sys.stdin)
score = d[-1].get('result')
print(f'{score:.4f}' if isinstance(score, float) else str(score))
" 2>/dev/null)

echo " Score for first lead: $SMOKE"
echo ""

echo "============================================================"
echo -e " ${GREEN}Setup complete. All components stored in RocksDB.${NC}"
echo "============================================================"
echo ""
echo " Everything survives server restarts — no re-setup needed."
echo ""
echo " Test:"
echo "   curl -X POST $ENDPOINT/sql \\"
echo "     -H 'surreal-ns: $NAMESPACE' -H 'surreal-db: $DATABASE' \\"
echo "     -u '$USERNAME:$PASSWORD' \\"
echo "     -d 'SELECT id, state, ai_confidence FROM lead LIMIT 5;'"
echo ""
