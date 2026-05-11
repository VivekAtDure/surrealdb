"""
convert_to_surml.py
===================
Manually constructs a .surml file from lgbm.onnx without needing
the native surrealml library (which has no Windows DLL).

.surml binary layout (from SurrealML Rust source):
    [4 bytes big-endian u32: header length]
    [header bytes: UTF-8 text, 9 fields joined by //=>]
    [raw ONNX model bytes]

Header field order (//=> delimited):
    0  keys         — column names joined by =>
    1  normalisers  — col=>type(a,b)//col=>type(a,b)  (empty = no normalisers)
    2  output       — name=>normaliser (e.g. close_probability=>none)
    3  name         — model name string
    4  version      — X.Y.Z
    5  description  — free text
    6  engine       — "pytorch" for ONNX runtime
    7  origin       — empty
    8  input_dims   — "1,29"  (batch,features)

NOTE: normalisation is done in SurrealQL fn::score_lead(), NOT here.

Output:
    models/lgbm.surml

Usage:
    python convert_to_surml.py
"""

import os
import struct

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ONNX_PATH  = os.path.join(SCRIPT_DIR, "models", "Deal-Risk", "close_prob_lgbm.onnx")
SURML_PATH = os.path.join(SCRIPT_DIR, "models", "Deal-Risk", "lgbm.surml")

# ── 29 features in exact training order ──────────────────────────────────────
FEATURE_COLS = [
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
]


def build_header() -> bytes:
    keys        = "=>".join(FEATURE_COLS)
    normalisers = ""                          # pre-normalised in SurrealQL
    output      = "close_probability=>none"   # output name, no denormalisation needed
    name        = "close_prob"
    version     = "1.0.0"
    description = (
        "LightGBM regressor predicting sales close probability (0-1). "
        "Input: 29 pre-normalised float32 features. "
        "Normalisation applied in fn::score_lead() before calling model."
    )
    engine      = "pytorch"                   # Rust ONNX runtime uses 'pytorch'
    origin      = ""
    input_dims  = f"1,{len(FEATURE_COLS)}"   # 1,29

    # Format: //=>{field0}//=>{field1}//=>...//=>{field8}//=>
    # (leading //=> + fields joined by //=> + trailing //=>)
    fields = [keys, normalisers, output, name, version, description, engine, origin, input_dims]
    header_str = "//=>" + "//=>".join(fields) + "//=>"
    return header_str.encode("utf-8")


def build_surml():
    print(f"Reading ONNX: {ONNX_PATH}")
    with open(ONNX_PATH, "rb") as f:
        onnx_bytes = f.read()
    print(f"  ONNX size : {len(onnx_bytes):,} bytes")

    header_bytes = build_header()
    print(f"  Header size: {len(header_bytes):,} bytes")
    print(f"  Columns   : {len(FEATURE_COLS)}")

    # Pack: [i32 big-endian header length] + [header] + [onnx model]
    header_len_prefix = struct.pack(">i", len(header_bytes))
    surml_bytes = header_len_prefix + header_bytes + onnx_bytes

    os.makedirs(os.path.dirname(SURML_PATH), exist_ok=True)
    with open(SURML_PATH, "wb") as f:
        f.write(surml_bytes)

    total_kb = len(surml_bytes) / 1024
    print(f"\nSaved: {SURML_PATH}  ({total_kb:.1f} KB)")
    print("Done.")


if __name__ == "__main__":
    build_surml()
