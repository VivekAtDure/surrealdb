#!/bin/bash
# ============================================================
# replicate_ml_setup.sh
# ============================================================
# Run this on any Ubuntu/Linux machine that has:
#   - SurrealDB v3.x running with RocksDB
#   - vitasalesbackup.surql already imported
#
# This script will:
#   1. Convert lgbm.onnx -> lgbm.surml          (existing close_prob model)
#   2. Convert 3 new models -> .surml            (consumer, interaction, product-quotation)
#   3. Import all 4 ML models into SurrealDB RocksDB
#   4. Define fn::score_lead() + all scoring functions + events
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
CONVERT_ALL_PY="$SCRIPT_DIR/convert_all_to_surml.py"

# New model ONNX paths
CONSUMER_ONNX="$SCRIPT_DIR/models/consumer_score.onnx"
INTERACTION_ONNX="$SCRIPT_DIR/models/interaction_score.onnx"
PRODUCT_ONNX="$SCRIPT_DIR/models/product_quotation_score.onnx"

# New model SURML output paths (each in its own subfolder)
CONSUMER_SURML="$SCRIPT_DIR/models/costermer-model/consumer_score.surml"
INTERACTION_SURML="$SCRIPT_DIR/models/interaction-model/interaction_score.surml"
PRODUCT_SURML="$SCRIPT_DIR/models/product-quotation/product_quotation_score.surml"

# ── Colours ───────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e " ${GREEN}OK${NC}   - $1"; }
fail() { echo -e " ${RED}ERROR${NC} - $1"; exit 1; }
skip() { echo -e " ${YELLOW}SKIP${NC}  - $1"; }
warn() { echo -e " ${YELLOW}WARN${NC}  - $1"; }

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
echo "[1/7] Checking SurrealDB is reachable..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$ENDPOINT/health")
if [ "$HTTP_CODE" != "200" ]; then
    fail "SurrealDB not reachable at $ENDPOINT (HTTP $HTTP_CODE)\n  Start: surreal start --user root --pass root --bind 0.0.0.0:8000 \"rocksdb:///path/to/data\""
fi
ok "SurrealDB is up at $ENDPOINT"
echo ""

# ── Step 2: Convert lgbm.onnx -> lgbm.surml ───────────────────
echo "[2/7] Preparing close_prob model (lgbm)..."
if [ -f "$SURML_PATH" ]; then
    skip "lgbm.surml already exists"
else
    [ -f "$ONNX_PATH" ] || fail "lgbm.onnx not found at $ONNX_PATH"
    python3 "$CONVERT_PY" || fail "Conversion failed. Make sure python3 is installed."
    ok "lgbm.surml created"
fi
echo ""

# ── Step 3: Convert 3 new models via convert_all_to_surml.py ──
echo "[3/7] Preparing 3 new scoring models..."

# consumer_score
if [ -f "$CONSUMER_SURML" ]; then
    skip "consumer_score.surml already exists"
elif [ ! -f "$CONSUMER_ONNX" ]; then
    warn "consumer_score.onnx not found — skipping consumer_score"
else
    python3 "$CONVERT_ALL_PY" consumer_score || fail "consumer_score conversion failed"
    ok "consumer_score.surml created → models/costermer-model/"
fi

# interaction_score
if [ -f "$INTERACTION_SURML" ]; then
    skip "interaction_score.surml already exists"
elif [ ! -f "$INTERACTION_ONNX" ]; then
    warn "interaction_score.onnx not found — skipping interaction_score"
else
    python3 "$CONVERT_ALL_PY" interaction_score || fail "interaction_score conversion failed"
    ok "interaction_score.surml created → models/interaction-model/"
fi

# product_quotation_score
if [ -f "$PRODUCT_SURML" ]; then
    skip "product_quotation_score.surml already exists"
elif [ ! -f "$PRODUCT_ONNX" ]; then
    warn "product_quotation_score.onnx not found — skipping product_quotation_score"
else
    python3 "$CONVERT_ALL_PY" product_quotation_score || fail "product_quotation_score conversion failed"
    ok "product_quotation_score.surml created → models/product-quotation/"
fi
echo ""

# ── Step 4: Import close_prob model ───────────────────────────
echo "[4/7] Importing close_prob (lgbm) model..."
ML_CODE=$(curl -s -o /tmp/ml_import_result.txt -w "%{http_code}" \
    -X POST "$ENDPOINT/ml/import" \
    -H "surreal-ns: $NAMESPACE" \
    -H "surreal-db: $DATABASE" \
    -u "$USERNAME:$PASSWORD" \
    --data-binary @"$SURML_PATH")
[ "$ML_CODE" = "200" ] || fail "close_prob import failed (HTTP $ML_CODE): $(cat /tmp/ml_import_result.txt)"
ok "close_prob model imported"
echo ""

# ── Step 5: Import 3 new models ───────────────────────────────
echo "[5/7] Importing 3 new scoring models..."

import_model() {
    local label="$1"
    local surml_path="$2"
    local tmp_file="/tmp/ml_${label}_result.txt"

    if [ ! -f "$surml_path" ]; then
        skip "$label — .surml not found, skipping upload"
        return
    fi

    local code
    code=$(curl -s -o "$tmp_file" -w "%{http_code}" \
        -X POST "$ENDPOINT/ml/import" \
        -H "surreal-ns: $NAMESPACE" \
        -H "surreal-db: $DATABASE" \
        -u "$USERNAME:$PASSWORD" \
        --data-binary @"$surml_path")

    if [ "$code" = "200" ]; then
        ok "$label model imported"
    else
        fail "$label import failed (HTTP $code): $(cat "$tmp_file")"
    fi
}

import_model "consumer_score"          "$CONSUMER_SURML"
import_model "interaction_score"        "$INTERACTION_SURML"
import_model "product_quotation_score"  "$PRODUCT_SURML"
echo ""

# ── Step 6: Apply functions + events ──────────────────────────
echo "[6/7] Applying scoring functions + events..."
[ -f "$SETUP_SQL" ] || fail "setup_ml.surql not found at $SETUP_SQL"

# Drop existing definitions first (idempotent re-run)
curl -s -o /dev/null \
    -X POST "$ENDPOINT/sql" \
    -H "surreal-ns: $NAMESPACE" \
    -H "surreal-db: $DATABASE" \
    -u "$USERNAME:$PASSWORD" \
    -d "REMOVE FUNCTION IF EXISTS fn::score_lead;
        REMOVE FUNCTION IF EXISTS fn::score_consumer;
        REMOVE FUNCTION IF EXISTS fn::score_interaction;
        REMOVE FUNCTION IF EXISTS fn::score_product_quotation;
        REMOVE EVENT IF EXISTS score_on_lead_change ON TABLE lead;
        REMOVE EVENT IF EXISTS score_on_conv_change ON TABLE conversation;
        REMOVE EVENT IF EXISTS score_consumer_on_lead_change ON TABLE lead;
        REMOVE EVENT IF EXISTS score_consumer_on_conv_change ON TABLE conversation;
        REMOVE EVENT IF EXISTS score_interaction_on_lead_change ON TABLE lead;
        REMOVE EVENT IF EXISTS score_interaction_on_conv_change ON TABLE conversation;
        REMOVE EVENT IF EXISTS score_product_quotation_on_lead_change ON TABLE lead;
        REMOVE EVENT IF EXISTS score_product_quotation_on_quotation_created ON TABLE generated_quotation;"

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

if grep -q '"ERR"' /tmp/setup_result.txt; then
    fail "One or more SQL statements failed:\n$(cat /tmp/setup_result.txt)"
fi

ok "fn::score_lead defined"
ok "fn::score_consumer defined"
ok "fn::score_interaction defined"
ok "fn::score_product_quotation defined"
ok "All events defined"
echo ""

# ── Step 7: Smoke tests ───────────────────────────────────────
echo "[7/7] Running smoke tests..."
SMOKE=$(curl -s \
    -X POST "$ENDPOINT/sql" \
    -H "surreal-ns: $NAMESPACE" \
    -H "surreal-db: $DATABASE" \
    -u "$USERNAME:$PASSWORD" \
    -d "LET \$lid = (SELECT id FROM lead LIMIT 1)[0].id;
        RETURN {
            close_prob:        fn::score_lead(\$lid),
            consumer:          fn::score_consumer(\$lid),
            interaction:       fn::score_interaction(\$lid),
            product_quotation: fn::score_product_quotation(\$lid)
        };" \
    | python3 -c "
import sys, json
d = json.load(sys.stdin)
r = d[-1].get('result', {})
for k, v in r.items():
    val = f'{v:.4f}' if isinstance(v, float) else str(v)
    print(f'  {k}: {val}')
" 2>/dev/null)

echo " Scores for first lead:"
echo "$SMOKE"
echo ""

echo "============================================================"
echo -e " ${GREEN}Setup complete. All models stored in RocksDB.${NC}"
echo "============================================================"
echo ""
echo " Model locations:"
echo "   models/lgbm.surml                                     (close_prob)"
echo "   models/costermer-model/consumer_score.surml           (consumer_score)"
echo "   models/interaction-model/interaction_score.surml      (interaction_score)"
echo "   models/product-quotation/product_quotation_score.surml (product_quotation_score)"
echo ""
echo " Everything survives server restarts — no re-setup needed."
echo ""
echo " Test:"
echo "   curl -X POST $ENDPOINT/sql \\"
echo "     -H 'surreal-ns: $NAMESPACE' -H 'surreal-db: $DATABASE' \\"
echo "     -u '$USERNAME:$PASSWORD' \\"
echo "     -d 'SELECT id, state, ai_confidence, consumer_score, interaction_score, product_quotation_score FROM lead LIMIT 5;'"
echo ""
