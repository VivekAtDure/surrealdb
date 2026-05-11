OPTION IMPORT;

-- ============================================================
-- Import All Models v2.0.0
-- ============================================================

USE NS vitasales;
USE DB vitasales;

-- ================================================================
-- 0. Close Probability Model v2.0.0 (Primary Deal Scoring)
-- ================================================================
INSERT INTO model_definition {
    model_name: "close_prob",
    version: "2.0.0",
    model_type: "LightGBM Regressor",
    engine: "pytorch (ONNX)",
    num_features: 29,
    input_features: [
        { feature_index: 0,  feature_name: "capacity_tons",                  data_type: "float32",  range_or_values: "0.0+",                         source_table: "product",   description: "Raw cooling/heating capacity in tons" },
        { feature_index: 1,  feature_name: "stage_ordinal",                  data_type: "ordinal",  range_or_values: "0-6",                        source_table: "lead",      description: "Pipeline stage encoded as ordinal 0-6" },
        { feature_index: 2,  feature_name: "has_urgency",                    data_type: "binary",   range_or_values: "0 or 1",                     source_table: "conversation", description: "1 if sentiment contains urgency keywords" },
        { feature_index: 3,  feature_name: "has_price",                      data_type: "binary",   range_or_values: "0 or 1",                     source_table: "conversation", description: "1 if conversation mentions price/cost" },
        { feature_index: 4,  feature_name: "log_base_price",                 data_type: "float32",  range_or_values: "0.0+",                         source_table: "product",   description: "Natural log of product base price" },
        { feature_index: 5,  feature_name: "total_price",                    data_type: "float32",  range_or_values: "0.0+",                         source_table: "product",   description: "Total price including tax" },
        { feature_index: 6,  feature_name: "log_capacity",                   data_type: "float32",  range_or_values: "0.0+",                         source_table: "product",   description: "Natural log of capacity_tons" },
        { feature_index: 7,  feature_name: "days_since_last_msg",            data_type: "float32",  range_or_values: "0.0+",                         source_table: "conversation", description: "Days elapsed since last message" },
        { feature_index: 8,  feature_name: "days_in_pipeline",               data_type: "float32",  range_or_values: "0.0+",                         source_table: "lead",      description: "Days since lead was created" },
        { feature_index: 9,  feature_name: "message_length",                 data_type: "int",      range_or_values: "0-200 (capped)",              source_table: "message",   description: "Length of latest message content" },
        { feature_index: 10, feature_name: "summary_length",                 data_type: "int",      range_or_values: "0-400 (capped)",              source_table: "conversation", description: "Length of conversation summary" },
        { feature_index: 11, feature_name: "stage_x_sentiment",              data_type: "float32",  range_or_values: "-5.0 to 8.0",                 source_table: "lead, conversation", description: "stage_ordinal × sentiment_score interaction" },
        { feature_index: 12, feature_name: "quotation_x_satisfied",          data_type: "binary",   range_or_values: "0 or 1",                     source_table: "generated_quotation, conversation", description: "1 if quotation sent AND sentiment positive" },
        { feature_index: 13, feature_name: "quotation_x_urgent",             data_type: "binary",   range_or_values: "0 or 1",                     source_table: "generated_quotation, conversation", description: "1 if quotation sent AND urgent sentiment" },
        { feature_index: 14, feature_name: "complete_x_quotation",           data_type: "binary",   range_or_values: "0 or 1",                     source_table: "lead, generated_quotation", description: "1 if complete AND quotation sent" },
        { feature_index: 15, feature_name: "angry_x_high_stage",             data_type: "binary",   range_or_values: "0 or 1",                     source_table: "conversation, lead", description: "1 if angry sentiment AND stage >= QUOTATION" },
        { feature_index: 16, feature_name: "urgent_x_high_stage",            data_type: "binary",   range_or_values: "0 or 1",                     source_table: "conversation, lead", description: "1 if urgent sentiment AND stage >= QUOTATION" },
        { feature_index: 17, feature_name: "is_enterprise_deal",             data_type: "binary",   range_or_values: "0 or 1",                     source_table: "product",   description: "1 if base_price >= 400,000" },
        { feature_index: 18, feature_name: "dissatisfied_x_late",            data_type: "binary",   range_or_values: "0 or 1",                     source_table: "conversation, lead", description: "1 if dissatisfied AND > 30 days without message" },
        { feature_index: 19, feature_name: "interested_x_complete",          data_type: "binary",   range_or_values: "0 or 1",                     source_table: "conversation, lead", description: "1 if positive/interested sentiment AND complete" },
        { feature_index: 20, feature_name: "pipeline_stage_enc",             data_type: "ordinal",  range_or_values: "0-6",                        source_table: "lead",      description: "Ordinal encoding of pipeline stage" },
        { feature_index: 21, feature_name: "source_channel_enc",             data_type: "ordinal",  range_or_values: "0-2 (email=0, phone=1, whatsapp=2)", source_table: "lead", description: "Source channel ordinal encoded" },
        { feature_index: 22, feature_name: "product_category_enc",           data_type: "ordinal",  range_or_values: "0-2 (chiller=0, cooler=1, combo=2)", source_table: "product", description: "Product category ordinal" },
        { feature_index: 23, feature_name: "product_type_enc",               data_type: "ordinal",  range_or_values: "0-21",                       source_table: "product",   description: "Product type label encoded 0-21" },
        { feature_index: 24, feature_name: "product_name_enc",               data_type: "ordinal",  range_or_values: "0-11",                       source_table: "product",   description: "Product name label encoded 0-11" },
        { feature_index: 25, feature_name: "product_sku_enc",                data_type: "ordinal",  range_or_values: "0-11",                       source_table: "product",   description: "Product SKU label encoded 0-11" },
        { feature_index: 26, feature_name: "org_industry_enc",               data_type: "ordinal",  range_or_values: "0-19",                       source_table: "organisation", description: "Industry type label encoded 0-19" },
        { feature_index: 27, feature_name: "lead_completeness_enc",          data_type: "binary",   range_or_values: "0 or 1",                     source_table: "lead",      description: "1 if lead profile is complete" },
        { feature_index: 28, feature_name: "quotation_sent_enc",             data_type: "binary",   range_or_values: "0 or 1",                     source_table: "generated_quotation", description: "1 if any quotation sent" }
    ],
    output_column: "close_probability",
    output_range: "0.0 to 1.0",
    output_unit: "probability",
    surml_file_path: "models/Deal-Risk/close_prob.surml",
    surrealdb_ml_name: "ml::close_prob<2.0.0>",
    surrealdb_function: "fn::score_lead",
    training_data_source: "lead, conversation, message, product, organisation, generated_quotation",
    normalization_method: "IQR binning for continuous values; ordinal label encoding for categorical; log transformation for prices and capacity",
    depends_on_models: [],
    description: "Primary deal scoring model predicting close probability based on lead profile, product, conversations, and pipeline position. Combines all deal signals.",
    is_active: true,
    deployed_by: "Vivek",
    feature_engineering_notes: "Interaction features: stage_x_sentiment, quotation_x_*, angry/urgent/dissatisfied_x_*. Log transforms: log_base_price = ln(max(base_price, 1)), log_capacity = ln(max(capacity, 1)). Enterprise threshold: base_price >= 400000.",
    created_at: time::now(),
    updated_at: time::now()
};

-- ================================================================
-- 1. Consumer Score Model v2.0.0
-- ================================================================
INSERT INTO model_definition {
    model_name: "consumer_score",
    version: "2.0.0",
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
    surml_file_path: "models/Consumer/consumer_score.surml",
    surrealdb_ml_name: "ml::consumer_score<2.0.0>",
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

-- ================================================================
-- 2. Interaction Score Model v2.0.0
-- ================================================================
INSERT INTO model_definition {
    model_name: "interaction_score",
    version: "2.0.0",
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
    surml_file_path: "models/Interaction/interaction_score.surml",
    surrealdb_ml_name: "ml::interaction_score<2.0.0>",
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

-- ================================================================
-- 3. Product Quotation Score Model v2.0.0
-- ================================================================
INSERT INTO model_definition {
    model_name: "product_quotation_score",
    version: "2.0.0",
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
    surml_file_path: "models/Product-Quotation/product_quotation_score.surml",
    surrealdb_ml_name: "ml::product_quotation_score<2.0.0>",
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

-- ================================================================
-- 4. Lead Qualification Model v2.0.0
-- ================================================================
INSERT INTO model_definition {
    model_name: "lead_qualification",
    version: "2.0.0",
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
    surml_file_path: "models/Lead-Qualification/lead_qualification.surml",
    surrealdb_ml_name: "ml::lead_qualification<2.0.0>",
    surrealdb_function: "fn::score_lead_qualification",
    training_data_source: "lead, conversation, product, organisation, consumer_score_result, interaction_score_result, product_quotation_score_result",
    normalization_method: "IQR binning (bins 1/2/3) for all continuous features; binary flags unchanged; sub-model outputs converted to tier 1/2/3",
    depends_on_models: ["consumer_score<2.0.0>", "interaction_score<2.0.0>", "product_quotation_score<2.0.0>"],
    description: "Master qualification model that combines outputs from 3 sub-models (consumer, interaction, product-quotation) with pipeline and organisational signals to produce a final lead score.",
    is_active: true,
    deployed_by: "Vivek",
    feature_engineering_notes: "Inputs from consumer_score<2.0.0>, interaction_score<2.0.0>, product_quotation_score<2.0.0> converted to tiers (1/2/3) based on output percentiles.",
    created_at: time::now(),
    updated_at: time::now()
};