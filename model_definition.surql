-- ============================================================
-- Model Definition Table
-- Stores metadata for all ML models used in VitaSales
-- ============================================================
-- Run with:
--   surreal import --endpoint http://localhost:8000 \
--     --username root --password root \
--     --namespace vitasales --database vitasales \
--     model_definition.surql
-- ============================================================

USE NS vitasales;
USE DB vitasales;

-- ============================================================
-- TABLE DEFINITION
-- ============================================================

DEFINE TABLE model_definition SCHEMAFULL
    COMMENT "Registry of all ML models deployed in VitaSales";

-- Core Identity
DEFINE FIELD model_name          ON model_definition TYPE string
    COMMENT "Unique name of the model (matches SurrealDB ml:: name)";

DEFINE FIELD version             ON model_definition TYPE string
    COMMENT "Semantic version e.g. 1.0.0";

DEFINE FIELD model_type          ON model_definition TYPE string
    COMMENT "Algorithm family e.g. LightGBM Regressor, XGBoost, etc.";

DEFINE FIELD engine              ON model_definition TYPE string
    COMMENT "Inference runtime e.g. pytorch (ONNX)";

-- Feature / Column Info
DEFINE FIELD num_features        ON model_definition TYPE int
    COMMENT "Total number of input features the model accepts";

DEFINE FIELD input_features      ON model_definition TYPE array
    COMMENT "Ordered list of input feature definitions";

DEFINE FIELD input_features.*    ON model_definition TYPE object;

DEFINE FIELD input_features.*.feature_index    ON model_definition TYPE int
    COMMENT "0-based position in the input array";

DEFINE FIELD input_features.*.feature_name     ON model_definition TYPE string
    COMMENT "Column / feature name";

DEFINE FIELD input_features.*.data_type        ON model_definition TYPE string
    COMMENT "Data type: float32 | int | binary | ordinal | categorical";

DEFINE FIELD input_features.*.range_or_values  ON model_definition TYPE string
    COMMENT "Allowed range (e.g. 0.0 to 1.0) or discrete values (e.g. 0,1,2)";

DEFINE FIELD input_features.*.source_table     ON model_definition TYPE string
    COMMENT "Which SurrealDB table this feature comes from";

DEFINE FIELD input_features.*.description      ON model_definition TYPE string
    COMMENT "Human-readable explanation of the feature";

-- Output Info
DEFINE FIELD output_column       ON model_definition TYPE string
    COMMENT "Name of the predicted output e.g. close_probability";

DEFINE FIELD output_range        ON model_definition TYPE string
    COMMENT "Output value range e.g. 0.0 to 1.0";

DEFINE FIELD output_unit         ON model_definition TYPE string
    COMMENT "Unit of output e.g. probability, percentage, score";

-- File & Function References
DEFINE FIELD surml_file_path     ON model_definition TYPE string
    COMMENT "Relative path to the .surml file";

DEFINE FIELD surrealdb_ml_name   ON model_definition TYPE string
    COMMENT "SurrealDB ml:: reference e.g. ml::consumer_score<1.0.0>";

DEFINE FIELD surrealdb_function  ON model_definition TYPE string
    COMMENT "SurrealDB fn:: wrapper e.g. fn::score_consumer";

-- Training & Accuracy
DEFINE FIELD training_data_source ON model_definition TYPE string
    COMMENT "Table(s) used for training e.g. lead, conversation, product";

DEFINE FIELD training_date       ON model_definition TYPE option<datetime>
    COMMENT "Date when model was trained";

DEFINE FIELD normalization_method ON model_definition TYPE string
    COMMENT "Feature scaling method e.g. IQR binning, raw float32, label encoding";

DEFINE FIELD accuracy_metrics    ON model_definition TYPE option<object>
    COMMENT "Training evaluation metrics";

DEFINE FIELD accuracy_metrics.rmse  ON model_definition TYPE option<float>;
DEFINE FIELD accuracy_metrics.r2    ON model_definition TYPE option<float>;
DEFINE FIELD accuracy_metrics.mae   ON model_definition TYPE option<float>;

-- Dependencies
DEFINE FIELD depends_on_models   ON model_definition TYPE array
    COMMENT "Other models whose scores this model uses as input features";

DEFINE FIELD depends_on_models.* ON model_definition TYPE string;

-- Status & Audit
DEFINE FIELD description         ON model_definition TYPE string
    COMMENT "What this model predicts and when it is used";

DEFINE FIELD is_active           ON model_definition TYPE bool   DEFAULT true
    COMMENT "Whether this version is currently serving predictions";

DEFINE FIELD deployed_by         ON model_definition TYPE option<string>
    COMMENT "Who deployed this model version";

DEFINE FIELD feature_engineering_notes ON model_definition TYPE option<string>
    COMMENT "Notes on how derived features are computed";

DEFINE FIELD created_at          ON model_definition TYPE datetime DEFAULT time::now();
DEFINE FIELD updated_at          ON model_definition TYPE datetime DEFAULT time::now();

-- Unique index: one active record per model_name + version
DEFINE INDEX idx_model_version ON model_definition
    FIELDS model_name, version UNIQUE;


-- ============================================================
-- SEED DATA: 4 VitaSales Models
-- ============================================================

-- ----------------------------------------------------------------
-- 1. Consumer Score Model
-- ----------------------------------------------------------------
INSERT INTO model_definition {
    model_name: "consumer_score",
    version: "1.0.0",
    model_type: "LightGBM Regressor",
    engine: "pytorch (ONNX)",
    num_features: 12,
    input_features: [
        { feature_index: 0,  feature_name: "primary_sentiment",       data_type: "ordinal",  range_or_values: "0-6 (angry=0, negative=1, dissatisfied=2, neutral=3, curious/negotiating/urgent=4-6)", source_table: "conversation", description: "Most recent dominant sentiment of the lead" },
        { feature_index: 1,  feature_name: "sentiment_score",         data_type: "float32",  range_or_values: "-1.0 to 1.0",                                                                           source_table: "conversation", description: "Continuous sentiment score, IQR binned" },
        { feature_index: 2,  feature_name: "sentiment_combo_score",   data_type: "float32",  range_or_values: "-5.0 to 8.0",                                                                           source_table: "conversation, lead", description: "Pipeline stage ordinal × sentiment score, clamped" },
        { feature_index: 3,  feature_name: "intent",                  data_type: "ordinal",  range_or_values: "0-9 (at_risk=0 … window_shopping=9)",                                                   source_table: "lead",         description: "Lead intent classification ordinal" },
        { feature_index: 4,  feature_name: "message_quality",         data_type: "ordinal",  range_or_values: "0-3 (detailed=0, long=1, medium=2, short=3)",                                           source_table: "conversation", description: "Length/quality category of the latest summary" },
        { feature_index: 5,  feature_name: "summary_length",          data_type: "int",      range_or_values: "0 to 499 (capped)",                                                                     source_table: "conversation", description: "Character count of conversation summary" },
        { feature_index: 6,  feature_name: "has_action_milestone",    data_type: "binary",   range_or_values: "0 or 1",                                                                                 source_table: "lead",         description: "1 if lead stage >= QUOTATION" },
        { feature_index: 7,  feature_name: "stage_velocity",          data_type: "float32",  range_or_values: "0.0+",                                                                                   source_table: "lead",         description: "stage_ordinal / days_in_pipeline" },
        { feature_index: 8,  feature_name: "historical_deals_won",    data_type: "float32",  range_or_values: "0.0+ (IQR binned)",                                                                     source_table: "organisation", description: "Total past deals closed by the organisation" },
        { feature_index: 9,  feature_name: "is_repeat_customer",      data_type: "binary",   range_or_values: "0 or 1",                                                                                 source_table: "organisation", description: "1 if organisation has historical_deals_won > 0" },
        { feature_index: 10, feature_name: "historical_avg_sentiment", data_type: "float32", range_or_values: "-1.0 to 1.0 (IQR binned)",                                                              source_table: "organisation", description: "Average past sentiment across all leads of this org" },
        { feature_index: 11, feature_name: "industry_close_rate",     data_type: "float32",  range_or_values: "0.38 to 0.67",                                                                          source_table: "organisation", description: "Fixed lookup close rate by industry segment" }
    ],
    output_column: "close_probability",
    output_range: "0.0 to 1.0",
    output_unit: "probability",
    surml_file_path: "models/consumer-model/consumer_score.surml",
    surrealdb_ml_name: "ml::consumer_score<1.0.0>",
    surrealdb_function: "fn::score_consumer",
    training_data_source: "lead, conversation, organisation",
    normalization_method: "IQR binning for continuous; ordinal label encoding for categorical; raw float32",
    depends_on_models: [],
    description: "Predicts lead close probability based on consumer sentiment signals, message quality, intent, and historical organisation data.",
    is_active: true,
    deployed_by: "Vivek",
    feature_engineering_notes: "sentiment_combo_score = stage_ordinal × sentiment_score, clamped to [-5, 8]. stage_velocity = stage_ordinal / max(days_in_pipeline, 1).",
    created_at: time::now(),
    updated_at: time::now()
};

-- ----------------------------------------------------------------
-- 2. Interaction Score Model
-- ----------------------------------------------------------------
INSERT INTO model_definition {
    model_name: "interaction_score",
    version: "1.0.0",
    model_type: "LightGBM Regressor",
    engine: "pytorch (ONNX)",
    num_features: 15,
    input_features: [
        { feature_index: 0,  feature_name: "whatsapp_count",        data_type: "int",     range_or_values: "0+",                                               source_table: "conversation", description: "Number of WhatsApp conversations with this lead" },
        { feature_index: 1,  feature_name: "phone_count",           data_type: "int",     range_or_values: "0+",                                               source_table: "conversation", description: "Number of phone/voice conversations" },
        { feature_index: 2,  feature_name: "email_count",           data_type: "int",     range_or_values: "0+",                                               source_table: "conversation", description: "Number of email conversations" },
        { feature_index: 3,  feature_name: "total_interactions",    data_type: "int",     range_or_values: "0+",                                               source_table: "conversation", description: "Sum of all channel conversation counts" },
        { feature_index: 4,  feature_name: "dominant_channel",      data_type: "ordinal", range_or_values: "0-2 (email=0, phone=1, whatsapp=2)",               source_table: "conversation", description: "Channel with the most conversations" },
        { feature_index: 5,  feature_name: "first_channel",         data_type: "ordinal", range_or_values: "0-2 (email=0, phone=1, whatsapp=2)",               source_table: "conversation", description: "Channel used in the first conversation" },
        { feature_index: 6,  feature_name: "last_channel",          data_type: "ordinal", range_or_values: "0-2 (email=0, phone=1, whatsapp=2)",               source_table: "conversation", description: "Channel used in the most recent conversation" },
        { feature_index: 7,  feature_name: "is_multi_channel",      data_type: "binary",  range_or_values: "0 or 1",                                           source_table: "conversation", description: "1 if lead interacted via more than one channel" },
        { feature_index: 8,  feature_name: "channel_switch_count",  data_type: "int",     range_or_values: "0+",                                               source_table: "conversation", description: "Number of distinct channels used minus 1" },
        { feature_index: 9,  feature_name: "conversation_time_hours", data_type: "float32", range_or_values: "0.0+",                                           source_table: "conversation", description: "Hours elapsed from first to last message" },
        { feature_index: 10, feature_name: "conv_time_bucket",      data_type: "ordinal", range_or_values: "0-4 (high_fast=0, high_slow=1, medium_fast=2, medium_slow=3, medium_medium=4)", source_table: "conversation", description: "Bucketed engagement depth vs. time" },
        { feature_index: 11, feature_name: "recency_bucket",        data_type: "ordinal", range_or_values: "0-3 (active=0, cold=1, fresh=2, stale=3)",         source_table: "conversation", description: "How recently the lead had a conversation" },
        { feature_index: 12, feature_name: "engagement_depth",      data_type: "float32", range_or_values: "0.0+",                                             source_table: "conversation", description: "total_interactions × sentiment_weight" },
        { feature_index: 13, feature_name: "channel_x_stage",       data_type: "ordinal", range_or_values: "0-35 (6 channels × 6 stages)",                    source_table: "conversation, lead", description: "Interaction term: dominant_channel × pipeline_stage" },
        { feature_index: 14, feature_name: "historical_deals_won",  data_type: "float32", range_or_values: "0.0+ (IQR binned)",                               source_table: "organisation", description: "Total past deals closed by the organisation" }
    ],
    output_column: "close_probability",
    output_range: "0.0 to 1.0",
    output_unit: "probability",
    surml_file_path: "models/interaction-model/interaction_score.surml",
    surrealdb_ml_name: "ml::interaction_score<1.0.0>",
    surrealdb_function: "fn::score_interaction",
    training_data_source: "lead, conversation, organisation",
    normalization_method: "IQR binning for continuous; ordinal label encoding for channel and stage; raw int for counts",
    depends_on_models: [],
    description: "Predicts close probability based on channel interaction patterns, conversation recency, engagement depth, and multi-channel behaviour.",
    is_active: true,
    deployed_by: "Vivek",
    feature_engineering_notes: "channel_x_stage = dominant_channel_ordinal × 6 + pipeline_stage_ordinal (0-35). engagement_depth = total_interactions × (1 + avg_sentiment).",
    created_at: time::now(),
    updated_at: time::now()
};

-- ----------------------------------------------------------------
-- 3. Product Quotation Score Model
-- ----------------------------------------------------------------
INSERT INTO model_definition {
    model_name: "product_quotation_score",
    version: "1.0.0",
    model_type: "LightGBM Regressor",
    engine: "pytorch (ONNX)",
    num_features: 18,
    input_features: [
        { feature_index: 0,  feature_name: "product_category",       data_type: "ordinal", range_or_values: "0-2 (chiller=0, cooler=1, hybrid=2)",                     source_table: "product",   description: "High-level product category" },
        { feature_index: 1,  feature_name: "product_type",           data_type: "ordinal", range_or_values: "0-21 (centrifugal=0 … vrf=21)",                            source_table: "product",   description: "Specific product type, label encoded alphabetically" },
        { feature_index: 2,  feature_name: "product_complexity",     data_type: "float32", range_or_values: "1.0 to 4.5",                                               source_table: "product",   description: "Complexity score assigned to the product" },
        { feature_index: 3,  feature_name: "product_base_price",     data_type: "float32", range_or_values: "0.0+",                                                     source_table: "product",   description: "Raw base price of the product before tax" },
        { feature_index: 4,  feature_name: "product_tax_rate",       data_type: "float32", range_or_values: "0.0 to 100.0 (e.g. 18.0 for 18%)",                        source_table: "product",   description: "Applicable tax percentage" },
        { feature_index: 5,  feature_name: "price_tier",             data_type: "ordinal", range_or_values: "0-3 (enterprise=0, high=1, low=2, mid=3)",                 source_table: "product",   description: "Price bracket of the product" },
        { feature_index: 6,  feature_name: "capacity_tons",          data_type: "float32", range_or_values: "0.0+",                                                     source_table: "product",   description: "Raw cooling/heating capacity in tons" },
        { feature_index: 7,  feature_name: "capacity_bin",           data_type: "ordinal", range_or_values: "0-4 (1-5t=0, 6-10t=4, 11-20t=1, 21-50t=2, 51-100t=3)",  source_table: "product",   description: "Capacity range bucket" },
        { feature_index: 8,  feature_name: "product_x_capacity",     data_type: "ordinal", range_or_values: "0+ (product_type × 5 + capacity_bin)",                    source_table: "product",   description: "Interaction term: product type combined with capacity bin" },
        { feature_index: 9,  feature_name: "total_price_with_tax",   data_type: "float32", range_or_values: "0.0+",                                                     source_table: "product",   description: "base_price × (1 + tax_rate / 100)" },
        { feature_index: 10, feature_name: "capacity_price_ratio",   data_type: "float32", range_or_values: "0.0+",                                                     source_table: "product",   description: "capacity_tons / total_price_with_tax — value-for-money signal" },
        { feature_index: 11, feature_name: "quotation_sent",         data_type: "binary",  range_or_values: "0 or 1",                                                   source_table: "generated_quotation", description: "1 if a quotation has been generated for this lead" },
        { feature_index: 12, feature_name: "is_enterprise_deal",     data_type: "binary",  range_or_values: "0 or 1",                                                   source_table: "product",   description: "1 if base_price >= 400,000 (enterprise threshold)" },
        { feature_index: 13, feature_name: "industry_close_rate",    data_type: "float32", range_or_values: "0.38 to 0.67",                                             source_table: "organisation", description: "Fixed lookup close rate by industry segment" },
        { feature_index: 14, feature_name: "pipeline_stage",         data_type: "ordinal", range_or_values: "0-12 (Closed=0 … Sales_Qualified=12, alphabetical)",      source_table: "lead",      description: "Current pipeline stage, alphabetically label encoded" },
        { feature_index: 15, feature_name: "is_repeat_customer",     data_type: "binary",  range_or_values: "0 or 1",                                                   source_table: "organisation", description: "1 if organisation has previous closed deals" },
        { feature_index: 16, feature_name: "days_in_pipeline",       data_type: "float32", range_or_values: "0.0+",                                                     source_table: "lead",      description: "Days since lead was created (lead.created_at to now)" },
        { feature_index: 17, feature_name: "pipeline_velocity",      data_type: "float32", range_or_values: "0.0+",                                                     source_table: "lead",      description: "pipeline_stage_ordinal / max(days_in_pipeline, 1)" }
    ],
    output_column: "close_probability",
    output_range: "0.0 to 1.0",
    output_unit: "probability",
    surml_file_path: "models/product-quotation-model/product_quotation_score.surml",
    surrealdb_ml_name: "ml::product_quotation_score<1.0.0>",
    surrealdb_function: "fn::score_product_quotation",
    training_data_source: "lead, product, quotation, organisation, generated_quotation",
    normalization_method: "Raw float32 for prices and capacities; ordinal label encoding; binary flags",
    depends_on_models: [],
    description: "Predicts close probability based on the product being considered, its pricing and capacity, whether a quotation was sent, and pipeline position.",
    is_active: true,
    deployed_by: "Vivek",
    feature_engineering_notes: "product_x_capacity = product_type_ordinal × 5 + capacity_bin. total_price_with_tax = base_price × (1 + tax_rate/100). Enterprise threshold: base_price >= 400000.",
    created_at: time::now(),
    updated_at: time::now()
};

-- ----------------------------------------------------------------
-- 4. Lead Qualification Model
-- ----------------------------------------------------------------
INSERT INTO model_definition {
    model_name: "lead_qualification",
    version: "1.0.0",
    model_type: "LightGBM Regressor",
    engine: "pytorch (ONNX)",
    num_features: 20,
    input_features: [
        { feature_index: 0,  feature_name: "has_action_milestone",        data_type: "binary",  range_or_values: "0 or 1",            source_table: "lead",         description: "1 if lead stage >= QUOTATION" },
        { feature_index: 1,  feature_name: "stage_velocity",              data_type: "ordinal", range_or_values: "1, 2, or 3 (IQR bin)", source_table: "lead",      description: "IQR-binned version of stage_ordinal / days_in_pipeline" },
        { feature_index: 2,  feature_name: "historical_deals_won",        data_type: "ordinal", range_or_values: "1, 2, or 3 (IQR bin)", source_table: "organisation", description: "IQR-binned total past deals closed by the organisation" },
        { feature_index: 3,  feature_name: "is_repeat_customer",          data_type: "binary",  range_or_values: "0 or 1",            source_table: "organisation", description: "1 if organisation has historical_deals_won > 0" },
        { feature_index: 4,  feature_name: "industry_close_rate",         data_type: "ordinal", range_or_values: "1, 2, or 3 (IQR bin)", source_table: "organisation", description: "IQR-binned industry-level close rate lookup" },
        { feature_index: 5,  feature_name: "historical_avg_sentiment",    data_type: "ordinal", range_or_values: "1, 2, or 3 (IQR bin)", source_table: "organisation", description: "IQR-binned average past sentiment across org leads" },
        { feature_index: 6,  feature_name: "intent",                      data_type: "ordinal", range_or_values: "1, 2, or 3 (rebinned from 0-9)", source_table: "lead", description: "Rebinned lead intent: low/medium/high" },
        { feature_index: 7,  feature_name: "total_interactions",          data_type: "ordinal", range_or_values: "1, 2, or 3 (IQR bin)", source_table: "conversation", description: "IQR-binned total conversation count across all channels" },
        { feature_index: 8,  feature_name: "is_multi_channel",            data_type: "binary",  range_or_values: "0 or 1",            source_table: "conversation", description: "1 if lead used more than one communication channel" },
        { feature_index: 9,  feature_name: "recency_bucket",              data_type: "ordinal", range_or_values: "1=cold, 2=stale, 3=active, 4=fresh", source_table: "conversation", description: "How recently the lead had a conversation" },
        { feature_index: 10, feature_name: "engagement_depth",            data_type: "ordinal", range_or_values: "1, 2, or 3 (IQR bin)", source_table: "conversation", description: "IQR-binned engagement depth (interactions × sentiment weight)" },
        { feature_index: 11, feature_name: "quotation_sent",              data_type: "binary",  range_or_values: "0 or 1",            source_table: "generated_quotation", description: "1 if a formal quotation has been issued" },
        { feature_index: 12, feature_name: "is_enterprise_deal",          data_type: "binary",  range_or_values: "0 or 1",            source_table: "product",      description: "1 if product base_price >= 400,000" },
        { feature_index: 13, feature_name: "pipeline_stage",              data_type: "ordinal", range_or_values: "1-12 (alphabetical label encoding)", source_table: "lead", description: "Current pipeline stage, alphabetically label encoded 1-12" },
        { feature_index: 14, feature_name: "days_in_pipeline",            data_type: "ordinal", range_or_values: "1, 2, or 3 (IQR bin)", source_table: "lead",      description: "IQR-binned days since lead was created" },
        { feature_index: 15, feature_name: "pipeline_velocity",           data_type: "ordinal", range_or_values: "1, 2, or 3 (IQR bin)", source_table: "lead",      description: "IQR-binned stage_ordinal / days_in_pipeline" },
        { feature_index: 16, feature_name: "total_price_with_tax",        data_type: "ordinal", range_or_values: "1, 2, or 3 (IQR bin)", source_table: "product",   description: "IQR-binned total deal value including tax" },
        { feature_index: 17, feature_name: "consumer_score_tier",         data_type: "ordinal", range_or_values: "1=<40%, 2=40-70%, 3=>70%", source_table: "consumer_score_result", description: "Tier from consumer_score model output" },
        { feature_index: 18, feature_name: "interaction_score_tier",      data_type: "ordinal", range_or_values: "1=<40%, 2=40-70%, 3=>70%", source_table: "interaction_score_result", description: "Tier from interaction_score model output" },
        { feature_index: 19, feature_name: "product_quotation_score_tier", data_type: "ordinal", range_or_values: "1=<40%, 2=40-70%, 3=>70%", source_table: "product_quotation_score_result", description: "Tier from product_quotation_score model output" }
    ],
    output_column: "close_probability",
    output_range: "0.0 to 1.0",
    output_unit: "probability",
    surml_file_path: "models/lead-qualification/lead_qualification.surml",
    surrealdb_ml_name: "ml::lead_qualification<1.0.0>",
    surrealdb_function: "fn::score_lead_qualification",
    training_data_source: "lead, conversation, product, organisation, consumer_score_result, interaction_score_result, product_quotation_score_result",
    normalization_method: "IQR binning (bins 1/2/3) for all continuous features; binary flags unchanged; sub-model outputs converted to tier 1/2/3",
    depends_on_models: ["consumer_score", "interaction_score", "product_quotation_score"],
    description: "Master qualification model that combines outputs from 3 sub-models (consumer, interaction, product-quotation) with pipeline and organisational signals to produce a final lead score.",
    is_active: true,
    deployed_by: "Vivek",
    feature_engineering_notes: "consumer/interaction/product_quotation_score_tier: score < 0.40 → tier 1, 0.40–0.70 → tier 2, > 0.70 → tier 3. All continuous features IQR-binned into 3 equal-frequency buckets before training.",
    created_at: time::now(),
    updated_at: time::now()
};
