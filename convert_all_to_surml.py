"""
convert_all_to_surml.py
=======================
Generic converter: builds a .surml file for each of the 4 scoring models
(consumer_score, interaction_score, product_quotation_score, lead_qualification)
from their respective .onnx files.

Same binary layout as the existing close_prob model — see convert_to_surml.py
for detailed format documentation.

NOTE: No normalisers are embedded — these models are trained on raw feature
      values, so SurrealQL functions pass raw values directly (no StandardScaler
      needed unlike fn::score_lead).

Usage:
    python convert_all_to_surml.py                    # converts all 4 models
    python convert_all_to_surml.py consumer_score     # converts only one model
    python convert_all_to_surml.py lead_qualification # converts only lead_qual
"""

import os
import struct
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
MODELS_DIR = os.path.join(SCRIPT_DIR, "models")

# ─────────────────────────────────────────────────────────────────────────────
# Model definitions — add new models here without touching any other code
# ─────────────────────────────────────────────────────────────────────────────

MODEL_CONFIGS = {

    "close_prob": {
        "onnx_file":   "Deal-Risk/close_prob_lgbm.onnx",
        "surml_file":  "Deal-Risk/v2/close_prob.surml",
        "name":        "close_prob",
        "version":     "2.0.0",
        "output":      "close_probability=>none",
        "description": (
            "LightGBM regressor predicting sales close probability (0-1). "
            "Input: 29 pre-normalised float32 features. "
            "Normalisation applied in fn::score_lead() before calling model."
        ),
        "feature_cols": [
            "capacity_tons",
            "fe_stage_ordinal",
            "fe_has_urgency_keyword",
            "fe_has_price_mention",
            "fe_log_base_price",
            "fe_total_price_with_tax",
            "fe_log_capacity",
            "fe_days_since_last_message",
            "fe_days_in_pipeline",
            "fe_message_length",
            "fe_summary_length",
            "fe_stage_x_sentiment",
            "fe_quotation_x_satisfied",
            "fe_quotation_x_urgent",
            "fe_complete_x_quotation",
            "fe_angry_x_high_stage",
            "fe_urgent_x_high_stage",
            "fe_enterprise_deal",
            "fe_dissatisfied_x_late",
            "fe_interested_x_complete",
            "pipeline_stage_enc",
            "source_channel_type_enc",
            "product_category_enc",
            "product_type_enc",
            "product_name_enc",
            "product_sku_enc",
            "organisation_industry_enc",
            "lead_completeness_enc",
            "quotation_sent_enc",
        ],
    },

    "consumer_score": {
        "onnx_file":   "Consumer/consumer_score_lgbm.onnx",
        "surml_file":  "Consumer/v2/consumer_score.surml",
        "name":        "consumer_score",
        "version":     "2.0.0",
        "output":      "close_probability=>none",
        "description": (
            "LightGBM regressor predicting sale close probability from consumer "
            "sentiment signals. 12 raw (un-normalised) float32 features. "
            "Feature engineering done in fn::score_consumer() before calling model."
        ),
        "feature_cols": [
            "primary_sentiment",        # [0]  ordinal: angry=0 … urgent=6
            "sentiment_score",          # [1]  continuous -1.0 to 1.0
            "sentiment_combo_score",    # [2]  stage × sentiment, clamped -5 to 8
            "intent",                   # [3]  ordinal: at_risk=0 … window_shopping=9
            "message_quality",          # [4]  ordinal: detailed=0, long=1, medium=2, short=3
            "summary_length",           # [5]  char count, capped at 499
            "has_action_milestone",     # [6]  binary: 1 if stage >= QUOTATION
            "stage_velocity",           # [7]  stage_ordinal / days_in_pipeline
            "historical_deals_won",     # [8]  from organisation record
            "is_repeat_customer",       # [9]  binary: 1 if historical_deals_won > 0
            "historical_avg_sentiment", # [10] from organisation record
            "industry_close_rate",      # [11] fixed lookup 0.38-0.67 by industry
        ],
    },

    "interaction_score": {
        "onnx_file":   "Interaction/interaction_score_lgbm.onnx",
        "surml_file":  "Interaction/v2/interaction_score.surml",
        "name":        "interaction_score",
        "version":     "2.0.0",
        "output":      "close_probability=>none",
        "description": (
            "LightGBM regressor predicting sale close probability from channel "
            "interaction patterns. 15 raw float32 features. "
            "Feature engineering done in fn::score_interaction() before calling model."
        ),
        "feature_cols": [
            "whatsapp_count",           # [0]  count of WhatsApp conversations
            "phone_count",              # [1]  count of phone/voice conversations
            "email_count",              # [2]  count of email conversations
            "total_interactions",       # [3]  sum of all channel counts
            "dominant_channel",         # [4]  ordinal: email=0, phone=1, whatsapp=2
            "first_channel",            # [5]  ordinal: email=0, phone=1, whatsapp=2
            "last_channel",             # [6]  ordinal: email=0, phone=1, whatsapp=2
            "is_multi_channel",         # [7]  binary: 1 if distinct channels > 1
            "channel_switch_count",     # [8]  distinct_channels - 1
            "conversation_time_hours",  # [9]  hours from first to last message
            "conv_time_bucket",         # [10] ordinal: high_fast=0 … medium_medium=4
            "recency_bucket",           # [11] ordinal: active=0, cold=1, fresh=2, stale=3
            "engagement_depth",         # [12] total_interactions × sentiment_weight
            "channel_x_stage",          # [13] ordinal: 36 combinations (channel × stage)
            "historical_deals_won",     # [14] from organisation record
        ],
    },

    "product_quotation_score": {
        "onnx_file":   "Product-Quotation/product_quotation_lgbm.onnx",
        "surml_file":  "Product-Quotation/v2/product_quotation_score.surml",
        "name":        "product_quotation_score",
        "version":     "2.0.0",
        "output":      "close_probability=>none",
        "description": (
            "LightGBM regressor predicting sale close probability from product "
            "and quotation data. 17 raw float32 features. "
            "Feature engineering done in fn::score_product_quotation() before calling model."
        ),
        "feature_cols": [
            "product_category",         # [0]  ordinal: chiller=0, cooler=1, hybrid=2
            "product_type",             # [1]  ordinal: absorption=0 … vrf=21
            "product_complexity",       # [2]  continuous 1.0-4.5 inferred from type
            "base_price",               # [3]  raw price value
            "tax_rate",                 # [4]  tax % (e.g. 18.0)
            "price_tier",               # [5]  ordinal: enterprise=0, high=1, low=2, mid=3
            "capacity_tons",            # [6]  raw capacity value
            "capacity_bin",             # [7]  ordinal: 1-5t=0, 11-20t=1, 21-50t=2, 51-100t=3, 6-10t=4
            "product_x_capacity",       # [8]  ordinal: product_type × 5 + capacity_bin
            "total_price_with_tax",     # [9]  base_price × (1 + tax_rate/100)
            "capacity_price_ratio",     # [10] capacity_tons / total_price_with_tax
            "quotation_sent",           # [11] binary: 1 if generated_quotation exists
            "is_enterprise_deal",       # [12] binary: 1 if base_price >= 400,000
            "industry_close_rate",      # [13] fixed lookup 0.38-0.67 by industry
            "stage_raw",                # [14] ordinal: raw pipeline stage value
            "is_repeat_customer",       # [15] binary: 1 if historical_deals_won > 0
            "days_in_pipeline",         # [16] days since lead.created_at
        ],
    },

    "lead_qualification": {
        "onnx_file":   "Lead-Qualification/lead_qualification_lgbm.onnx",
        "surml_file":  "Lead-Qualification/v2/lead_qualification.surml",
        "name":        "lead_qualification",
        "version":     "2.0.0",
        "output":      "close_probability=>none",
        "description": (
            "LightGBM regressor predicting overall lead qualification score by "
            "combining signals from all 3 sub-models (consumer, interaction, product) "
            "plus pipeline and org data. 20 IQR-binned float32 features. "
            "Feature engineering done in fn::score_lead_qualification() before calling model."
        ),
        "feature_cols": [
            "has_action_milestone",          # [0]  binary: 1 if stage >= QUOTATION
            "stage_velocity",                # [1]  IQR bin 1/2/3: stage_raw / days_in_pipeline
            "historical_deals_won",          # [2]  IQR bin 1/2/3: from organisation record
            "is_repeat_customer",            # [3]  binary: 1 if historical_deals_won > 0
            "industry_close_rate",           # [4]  IQR bin 1/2/3: lookup 0.38-0.67 by industry
            "historical_avg_sentiment",      # [5]  IQR bin 1/2/3: from organisation record
            "intent",                        # [6]  bin 1/2/3: rebinned from 1-10 consumer intent
            "total_interactions",            # [7]  IQR bin 1/2/3: sum of all channel conversations
            "is_multi_channel",              # [8]  binary: 1 if distinct channels > 1
            "recency_bucket",                # [9]  1=cold(>21d), 2=stale(≤21d), 3=active(≤7d), 4=fresh(≤3d)
            "engagement_depth",              # [10] IQR bin 1/2/3: total_interactions × sentiment_weight
            "quotation_sent",                # [11] binary: 1 if generated_quotation exists
            "is_enterprise_deal",            # [12] binary: 1 if product.base_price >= 400,000
            "pipeline_stage",                # [13] label encoded 1-12 (alphabetical stage names)
            "days_in_pipeline",              # [14] IQR bin 1/2/3: days since lead.created_at
            "pipeline_velocity",             # [15] IQR bin 1/2/3: stage_raw / days_in_pipeline
            "total_price_with_tax",          # [16] IQR bin 1/2/3: base_price × (1 + tax_rate/100)
            "consumer_score_tier",           # [17] tier 1/2/3: from lead.consumer_score field
            "interaction_score_tier",        # [18] tier 1/2/3: from lead.interaction_score field
            "product_quotation_score_tier",  # [19] tier 1/2/3: from lead.product_quotation_score field
        ],
    },
}


# ─────────────────────────────────────────────────────────────────────────────
# Core builder (same binary format as convert_to_surml.py)
# ─────────────────────────────────────────────────────────────────────────────

def build_header(cfg: dict) -> bytes:
    keys        = "=>".join(cfg["feature_cols"])
    normalisers = ""                    # raw features — no normalisers needed
    output      = cfg["output"]
    name        = cfg["name"]
    version     = cfg["version"]
    description = cfg["description"]
    engine      = "pytorch"            # SurrealDB ONNX runtime label
    origin      = ""
    input_dims  = f"1,{len(cfg['feature_cols'])}"

    fields = [keys, normalisers, output, name, version, description, engine, origin, input_dims]
    header_str = "//=>" + "//=>".join(fields) + "//=>"
    return header_str.encode("utf-8")


def convert_model(model_key: str) -> None:
    cfg = MODEL_CONFIGS[model_key]

    onnx_path  = os.path.join(MODELS_DIR, cfg["onnx_file"])
    surml_path = os.path.join(MODELS_DIR, cfg["surml_file"])

    if not os.path.exists(onnx_path):
        print(f"  [SKIP] ONNX not found: {onnx_path}")
        return

    print(f"\n{'─' * 60}")
    print(f"Model      : {cfg['name']} v{cfg['version']}")
    print(f"Features   : {len(cfg['feature_cols'])}")
    print(f"ONNX       : {onnx_path}")

    with open(onnx_path, "rb") as f:
        onnx_bytes = f.read()
    print(f"ONNX size  : {len(onnx_bytes):,} bytes")

    header_bytes = build_header(cfg)
    print(f"Header size: {len(header_bytes):,} bytes")

    header_len_prefix = struct.pack(">i", len(header_bytes))
    surml_bytes = header_len_prefix + header_bytes + onnx_bytes

    os.makedirs(os.path.dirname(surml_path), exist_ok=True)
    with open(surml_path, "wb") as f:
        f.write(surml_bytes)

    print(f"Saved      : {surml_path}  ({len(surml_bytes) / 1024:.1f} KB)")


def main():
    # Allow targeting a single model via CLI arg, else convert all
    if len(sys.argv) > 1:
        key = sys.argv[1]
        if key not in MODEL_CONFIGS:
            print(f"Unknown model '{key}'. Available: {list(MODEL_CONFIGS.keys())}")
            sys.exit(1)
        keys_to_run = [key]
    else:
        keys_to_run = list(MODEL_CONFIGS.keys())

    print(f"Converting {len(keys_to_run)} model(s) to SURML...")
    for key in keys_to_run:
        convert_model(key)

    print(f"\n{'─' * 60}")
    print("Done. Load each .surml into SurrealDB with:")
    print()
    for key in keys_to_run:
        cfg = MODEL_CONFIGS[key]
        print(f"  curl -X POST http://localhost:8000/ml/import \\")
        print(f"    -H \"surreal-ns: vitasales\" -H \"surreal-db: vitasales\" \\")
        print(f"    -u \"root:root\" --data-binary @models/{cfg['surml_file']}")
        print()


if __name__ == "__main__":
    main()
