-- ============================================================
-- SurrealDB ML Setup for Vitasales Lead Scoring
-- ============================================================
-- Run with:
--   surreal import --endpoint http://localhost:8000 \
--     --username root --password root \
--     --namespace vitasales --database vitasales \
--     setup_ml.surql
-- ============================================================

USE NS vitasales;
USE DB vitasales;

-- ============================================================
-- FUNCTION: fn::score_lead
-- Fetches all related data, engineers 29 features, normalises
-- them, calls the lgbm model and returns close_probability.
-- ============================================================
DEFINE FUNCTION fn::score_lead($lead_id: record) {

    LET $lead = (SELECT * FROM ONLY $lead_id);

    LET $conv = (
        SELECT * FROM conversation
        WHERE lead = $lead_id
        ORDER BY created_at DESC LIMIT 1
    )[0];

    LET $msg = IF $conv != NONE THEN (
        SELECT * FROM message
        WHERE conversation = $conv.id
        ORDER BY created_at DESC LIMIT 1
    )[0] ELSE NONE END;

    LET $product = (SELECT * FROM ($lead_id->interested_in->product))[0];

    LET $org = IF $lead.organisation != NONE THEN
        (SELECT * FROM ONLY $lead.organisation)
    ELSE NONE END;

    LET $has_quotation = (
        SELECT count() FROM generated_quotation
        WHERE lead = $lead_id GROUP ALL
    )[0].count > 0;

    LET $stage_raw =
        IF $lead.state = "NEW_LEAD"                THEN 0
        ELSE IF $lead.state = "MANUAL_FOLLOW_UP"   THEN 1
        ELSE IF $lead.state = "SALES_FOLLOW_UP"    THEN 2
        ELSE IF $lead.state = "SALES_QUALIFIED"    THEN 3
        ELSE IF $lead.state = "QUOTATION"          THEN 4
        ELSE IF $lead.state = "FOLLOW_UP_NEGOTIATION" THEN 5
        ELSE IF $lead.state = "CLOSED"             THEN 6
        ELSE 0 END;

    LET $sentiment_str = IF $conv != NONE THEN $conv.sentiment ELSE "NEUTRAL" END;
    LET $sentiment_scalar =
        IF $sentiment_str = "POSITIVE"      THEN 1.0
        ELSE IF $sentiment_str = "SATISFIED"    THEN 1.0
        ELSE IF $sentiment_str = "INTERESTED"   THEN 0.8
        ELSE IF $sentiment_str = "NEGOTIATING"  THEN 0.5
        ELSE IF $sentiment_str = "CURIOUS"      THEN 0.3
        ELSE IF $sentiment_str = "NEUTRAL"      THEN 0.0
        ELSE IF $sentiment_str = "URGENT"       THEN 0.5
        ELSE IF $sentiment_str = "DISSATISFIED" THEN -0.5
        ELSE IF $sentiment_str = "NEGATIVE"     THEN -1.0
        ELSE IF $sentiment_str = "ANGRY"        THEN -1.0
        ELSE 0.0 END;

    LET $is_positive     = IF $sentiment_scalar >= 0.5 THEN 1.0 ELSE 0.0 END;
    LET $is_urgent       = IF $sentiment_str = "URGENT" THEN 1.0 ELSE 0.0 END;
    LET $is_angry        = IF $sentiment_str = "ANGRY" THEN 1.0 ELSE 0.0 END;
    LET $is_dissatisfied = IF $sentiment_str = "DISSATISFIED" OR $sentiment_str = "NEGATIVE"
                           THEN 1.0 ELSE 0.0 END;

    LET $is_complete   = IF $lead.completeness = "COMPLETE" THEN 1.0 ELSE 0.0 END;
    LET $is_high_stage = IF $stage_raw >= 3 THEN 1.0 ELSE 0.0 END;
    LET $quotation_sent = IF $has_quotation THEN 1.0 ELSE 0.0 END;

    LET $channel_str = IF $lead.source_channel != NONE THEN
        string::split(type::string($lead.source_channel), ":")[1]
    ELSE "" END;
    LET $source_channel_enc =
        IF $channel_str = "email"    THEN 0.0
        ELSE IF $channel_str = "voice" OR $channel_str = "phone" THEN 1.0
        ELSE IF $channel_str = "whatsapp" THEN 2.0
        ELSE -1.0 END;

    LET $base_price  = IF $product != NONE THEN $product.base_price  ELSE 100000.0 END;
    LET $tax_rate    = IF $product != NONE THEN $product.tax_rate     ELSE 18.0     END;
    LET $total_price = $base_price * (1.0 + $tax_rate / 100.0);
    LET $capacity_tons = 14.0832;

    LET $product_name_str = IF $product != NONE THEN $product.name ELSE "" END;
    LET $product_sku_str  = IF $product != NONE THEN $product.sku  ELSE "" END;
    LET $product_category_enc =
        IF string::contains(string::lowercase($product_name_str), "chiller") THEN 0.0
        ELSE IF string::contains(string::lowercase($product_name_str), "cooler") THEN 1.0
        ELSE IF string::contains(string::lowercase($product_name_str), "combo")  THEN 2.0
        ELSE -1.0 END;

    LET $product_type_attr = IF $product != NONE AND $product.attributes != NONE
        THEN $product.attributes.type ELSE "" END;
    LET $product_type_enc =
        IF $product_type_attr = "centrifugal" THEN 0.0
        ELSE IF $product_type_attr = "combo"     THEN 1.0
        ELSE IF $product_type_attr = "economy"   THEN 2.0
        ELSE IF $product_type_attr = "glycol"    THEN 3.0
        ELSE IF $product_type_attr = "industrial" THEN 4.0
        ELSE IF $product_type_attr = "modular"   THEN 5.0
        ELSE IF $product_type_attr = "package"   THEN 6.0
        ELSE IF $product_type_attr = "portable"  THEN 7.0
        ELSE IF $product_type_attr = "premium"   THEN 8.0
        ELSE IF $product_type_attr = "rooftop"   THEN 9.0
        ELSE IF $product_type_attr = "single"    THEN 10.0
        ELSE -1.0 END;

    LET $product_name_enc =
        IF $product_name_str = "Air Cooler Unit"                 THEN 0.0
        ELSE IF $product_name_str = "Air-Cooled Chiller Package" THEN 1.0
        ELSE IF $product_name_str = "Centrifugal Chiller"        THEN 2.0
        ELSE IF $product_name_str = "Cooler and Chillers Combo"  THEN 3.0
        ELSE IF $product_name_str = "Evaporative Cooler"         THEN 4.0
        ELSE IF $product_name_str = "Glycol Chiller System"      THEN 5.0
        ELSE IF $product_name_str = "Industrial Chiller"         THEN 6.0
        ELSE IF $product_name_str = "Modular Cooling Tower"      THEN 7.0
        ELSE IF $product_name_str = "Portable Cooling Unit"      THEN 8.0
        ELSE IF $product_name_str = "Precision Chiller"          THEN 9.0
        ELSE IF $product_name_str = "Rooftop Chiller"            THEN 10.0
        ELSE IF $product_name_str = "Screw Chiller"              THEN 11.0
        ELSE -1.0 END;

    LET $product_sku_enc =
        IF $product_sku_str = "CHIL-001"  THEN 0.0
        ELSE IF $product_sku_str = "CHIL-002"  THEN 1.0
        ELSE IF $product_sku_str = "CHIL-003"  THEN 2.0
        ELSE IF $product_sku_str = "CHIL-004"  THEN 3.0
        ELSE IF $product_sku_str = "CHIL-005"  THEN 4.0
        ELSE IF $product_sku_str = "CHIL-006"  THEN 5.0
        ELSE IF $product_sku_str = "COMBO-001" THEN 6.0
        ELSE IF $product_sku_str = "COMBO-002" THEN 7.0
        ELSE IF $product_sku_str = "COOL-001"  THEN 8.0
        ELSE IF $product_sku_str = "COOL-002"  THEN 9.0
        ELSE IF $product_sku_str = "COOL-003"  THEN 10.0
        ELSE IF $product_sku_str = "COOL-004"  THEN 11.0
        ELSE -1.0 END;

    LET $industry_str = IF $org != NONE THEN $org.industry ELSE "" END;
    LET $org_industry_enc =
        IF $industry_str = "Automotive"                THEN 0.0
        ELSE IF $industry_str = "Breweries & Beverages"  THEN 1.0
        ELSE IF $industry_str = "Chemicals"              THEN 2.0
        ELSE IF $industry_str = "Cold Chain Logistics"   THEN 3.0
        ELSE IF $industry_str = "Dairy Processing"       THEN 4.0
        ELSE IF $industry_str = "Data Centers"           THEN 5.0
        ELSE IF $industry_str = "Defence & Aerospace"    THEN 6.0
        ELSE IF $industry_str = "Food Processing"        THEN 7.0
        ELSE IF $industry_str = "Glass Manufacturing"    THEN 8.0
        ELSE IF $industry_str = "Hospitality"            THEN 9.0
        ELSE IF $industry_str = "Oil & Gas"              THEN 10.0
        ELSE IF $industry_str = "Paper & Pulp"           THEN 11.0
        ELSE IF $industry_str = "Pharmaceuticals"        THEN 12.0
        ELSE IF $industry_str = "Plastics"               THEN 13.0
        ELSE IF $industry_str = "Power Generation"       THEN 14.0
        ELSE IF $industry_str = "Real Estate"            THEN 15.0
        ELSE IF $industry_str = "Rubber & Tyres"         THEN 16.0
        ELSE IF $industry_str = "Semiconductor Fabrication" THEN 17.0
        ELSE IF $industry_str = "Steel Manufacturing"    THEN 18.0
        ELSE IF $industry_str = "Textiles"               THEN 19.0
        ELSE -1.0 END;

    LET $now = time::now();

    LET $days_in_pipeline_raw =
        IF $lead.created_at != NONE THEN
            math::floor(duration::secs($now - $lead.created_at) / 86400)
        ELSE 10.0 END;

    LET $last_msg_time = IF $conv != NONE AND $conv.last_message_at != NONE
        THEN $conv.last_message_at
        ELSE IF $lead.created_at != NONE THEN $lead.created_at
        ELSE $now END;
    LET $days_since_last_msg_raw =
        math::floor(duration::secs($now - $last_msg_time) / 86400);

    LET $is_late = IF $days_since_last_msg_raw > 30 THEN 1.0 ELSE 0.0 END;

    LET $message_length_raw = IF $msg != NONE AND $msg.content != NONE
        THEN math::min([string::len($msg.content), 200])
        ELSE 67.0 END;

    LET $summary_length_raw = IF $conv != NONE AND $conv.summary != NONE
            AND string::len($conv.summary) > 0
        THEN math::min([string::len($conv.summary), 400])
        ELSE 178.0 END;

    LET $E = 2.718281828459045;
    LET $log_base_price = math::log(math::max([$base_price, 1.0]), $E);
    LET $log_capacity   = math::log(math::max([$capacity_tons, 1.0]), $E);

    LET $stage_x_sentiment_raw = $stage_raw * $sentiment_scalar;
    LET $is_enterprise = IF $total_price >= 500000.0 THEN 1.0 ELSE 0.0 END;

    LET $n_capacity_tons       = ($capacity_tons           - 14.0832)    / 14.707683;
    LET $n_log_base_price      = ($log_base_price          - 11.591958)  / 1.271296;
    LET $n_total_price         = ($total_price             - 242903.926) / 260074.554725;
    LET $n_log_capacity        = ($log_capacity            - 2.240947)   / 0.998809;
    LET $n_days_since_last_msg = ($days_since_last_msg_raw - 22.3486)    / 9.068094;
    LET $n_days_in_pipeline    = ($days_in_pipeline_raw    - 10.5838)    / 8.304455;
    LET $n_message_length      = ($message_length_raw      - 67.8074)    / 9.516324;
    LET $n_summary_length      = ($summary_length_raw      - 178.5432)   / 23.819328;

    LET $n_stage_ordinal          = $stage_raw / 6.0;
    LET $n_stage_x_sentiment      = ($stage_x_sentiment_raw + 5.0) / 11.0;
    LET $n_pipeline_stage_enc     = $stage_raw / 6.0;
    LET $n_source_channel_enc     = $source_channel_enc / 2.0;
    LET $n_product_category_enc   = $product_category_enc / 2.0;
    LET $n_product_type_enc       = $product_type_enc / 10.0;
    LET $n_product_name_enc       = $product_name_enc / 11.0;
    LET $n_product_sku_enc        = $product_sku_enc / 11.0;
    LET $n_org_industry_enc       = $org_industry_enc / 19.0;

    LET $n_has_urgency             = 0.0;
    LET $n_has_price               = 0.0;
    LET $n_quotation_x_satisfied   = $quotation_sent * $is_positive;
    LET $n_quotation_x_urgent      = $quotation_sent * $is_urgent;
    LET $n_complete_x_quotation    = $is_complete * $quotation_sent;
    LET $n_angry_x_high_stage      = $is_angry * $is_high_stage;
    LET $n_urgent_x_high_stage     = $is_urgent * $is_high_stage;
    LET $n_enterprise_deal         = $is_enterprise;
    LET $n_dissatisfied_x_late     = $is_dissatisfied * $is_late;
    LET $n_interested_x_complete   = $is_positive * $is_complete;
    LET $n_lead_completeness_enc   = $is_complete;
    LET $n_quotation_sent_enc      = $quotation_sent;

    LET $score = ml::close_prob<1.0.0>([
        $n_capacity_tons,
        $n_stage_ordinal,
        $n_has_urgency,
        $n_has_price,
        $n_log_base_price,
        $n_total_price,
        $n_log_capacity,
        $n_days_since_last_msg,
        $n_days_in_pipeline,
        $n_message_length,
        $n_summary_length,
        $n_stage_x_sentiment,
        $n_quotation_x_satisfied,
        $n_quotation_x_urgent,
        $n_complete_x_quotation,
        $n_angry_x_high_stage,
        $n_urgent_x_high_stage,
        $n_enterprise_deal,
        $n_dissatisfied_x_late,
        $n_interested_x_complete,
        $n_pipeline_stage_enc,
        $n_source_channel_enc,
        $n_product_category_enc,
        $n_product_type_enc,
        $n_product_name_enc,
        $n_product_sku_enc,
        $n_org_industry_enc,
        $n_lead_completeness_enc,
        $n_quotation_sent_enc
    ]);

    RETURN math::round($score[0] * 10000) / 100;
};

-- ============================================================
-- EVENT: score_on_lead_change
-- ============================================================
DEFINE EVENT score_on_lead_change ON TABLE lead
    WHEN $event = "CREATE"
      OR ($event = "UPDATE" AND (
            $before.state          != $value.state          OR
            $before.completeness   != $value.completeness   OR
            $before.source_channel != $value.source_channel OR
            $before.organisation   != $value.organisation
         )) THEN {
        LET $score = fn::score_lead($value.id);
        UPDATE $value.id SET
            ai_confidence = math::round($score * 10000) / 10000;
    };

-- ============================================================
-- EVENT: score_on_conv_change
-- ============================================================
DEFINE EVENT score_on_conv_change ON TABLE conversation
    WHEN $event = "CREATE"
      OR ($event = "UPDATE" AND (
            $before.sentiment       != $value.sentiment       OR
            $before.summary         != $value.summary         OR
            $before.last_message_at != $value.last_message_at
         )) THEN {
        LET $lead_id = $value.lead;
        LET $score = fn::score_lead($lead_id);
        UPDATE $lead_id SET
            ai_confidence = math::round($score * 10000) / 10000;
    };

-- ============================================================
-- TABLE definitions
-- ============================================================
DEFINE TABLE consumer_score_result SCHEMALESS;
DEFINE INDEX idx_consumer_lead ON TABLE consumer_score_result COLUMNS lead UNIQUE;

DEFINE TABLE interaction_score_result SCHEMALESS;
DEFINE INDEX idx_interaction_lead ON TABLE interaction_score_result COLUMNS lead UNIQUE;

DEFINE TABLE product_quotation_score_result SCHEMALESS;
DEFINE INDEX idx_product_quotation_lead ON TABLE product_quotation_score_result COLUMNS lead UNIQUE;

DEFINE TABLE lead_qualification_score_result SCHEMALESS;
DEFINE INDEX idx_lead_qualification_lead ON TABLE lead_qualification_score_result COLUMNS lead UNIQUE;

-- ============================================================
-- FUNCTION: fn::score_consumer
-- All 12 features are computed by the Java mapper and passed
-- directly. This function only invokes the ML model.
-- ============================================================
DEFINE FUNCTION fn::score_consumer(
    $primary_sentiment:        float,  -- label encoded 1-7
    $sentiment_score:          float,  -- IQR bin 1/2/3
    $sentiment_combo_score:    float,  -- IQR bin 1/2/3
    $intent:                   float,  -- label encoded 1-10
    $message_quality:          float,  -- ordinal 1-4
    $summary_length:           float,  -- IQR bin 1/2/3
    $has_action_milestone:     float,  -- binary 0/1
    $stage_velocity:           float,  -- IQR bin 1/2/3
    $historical_deals_won:     float,  -- IQR bin 1/2/3
    $is_repeat_customer:       float,  -- binary 0/1
    $historical_avg_sentiment: float,  -- IQR bin 1/2/3
    $industry_close_rate:      float   -- IQR bin 1/2/3
) {
    LET $raw = ml::consumer_score<1.0.0>([
        $primary_sentiment,
        $sentiment_score,
        $sentiment_combo_score,
        $intent,
        $message_quality,
        $summary_length,
        $has_action_milestone,
        $stage_velocity,
        $historical_deals_won,
        $is_repeat_customer,
        $historical_avg_sentiment,
        $industry_close_rate
    ]);

    RETURN math::round($raw[0] * 10000) / 100;
};

-- ============================================================
-- FUNCTION: fn::score_interaction
-- Data fetch + feature engineering handled by Java mapper.
-- Accepts 15 pre-computed features and calls the ML model.
-- ============================================================
DEFINE FUNCTION fn::score_interaction(
    $whatsapp_count: float,
    $phone_count: float,
    $email_count: float,
    $total_interactions: float,
    $dominant_channel: float,
    $first_channel: float,
    $last_channel: float,
    $is_multi_channel: float,
    $channel_switch_count: float,
    $conversation_time_hours: float,
    $conv_time_bucket: float,
    $recency_bucket: float,
    $engagement_depth: float,
    $channel_x_stage: float,
    $historical_deals_won: float
) {
    LET $raw = ml::interaction_score<1.0.0>([
        $whatsapp_count,
        $phone_count,
        $email_count,
        $total_interactions,
        $dominant_channel,
        $first_channel,
        $last_channel,
        $is_multi_channel,
        $channel_switch_count,
        $conversation_time_hours,
        $conv_time_bucket,
        $recency_bucket,
        $engagement_depth,
        $channel_x_stage,
        $historical_deals_won
    ]);

    RETURN math::round($raw[0] * 10000) / 100;
};

-- ============================================================
-- FUNCTION: fn::score_product_quotation
-- All 18 features are pre-computed by the Java mapper and passed
-- directly. This function only invokes the ML model.
-- ============================================================
DEFINE FUNCTION fn::score_product_quotation(
    $product_category    : float,   -- [0]  chiller=0, cooler=1, combo=2
    $product_type        : float,   -- [1]  centrifugal=0 … screw=11
    $product_complexity  : float,   -- [2]  1.0–4.5
    $base_price          : float,   -- [3]  raw value
    $tax_rate            : float,   -- [4]  raw %
    $price_tier          : float,   -- [5]  0/1/2/3
    $capacity_tons       : float,   -- [6]  raw value
    $capacity_bin        : float,   -- [7]  0/1/2/3/4
    $product_x_capacity  : float,   -- [8]  product_type×5 + capacity_bin
    $total_price         : float,   -- [9]  base×(1+tax/100)
    $capacity_price_ratio: float,   -- [10] capacity_tons / total_price
    $quotation_sent      : float,   -- [11] 0/1
    $is_enterprise_deal  : float,   -- [12] 0/1
    $industry_close_rate : float,   -- [13] 0.38–0.67
    $stage_raw           : float,   -- [14] 0–6
    $is_repeat_customer  : float,   -- [15] 0/1
    $days_in_pipeline    : float,   -- [16] raw days
    $pipeline_velocity   : float    -- [17] stage/days
) {
    LET $raw = ml::product_quotation_score<1.0.0>([
        $product_category,
        $product_type,
        $product_complexity,
        $base_price,
        $tax_rate,
        $price_tier,
        $capacity_tons,
        $capacity_bin,
        $product_x_capacity,
        $total_price,
        $capacity_price_ratio,
        $quotation_sent,
        $is_enterprise_deal,
        $industry_close_rate,
        $stage_raw,
        $is_repeat_customer,
        $days_in_pipeline,
        $pipeline_velocity
    ]);

    RETURN math::round($raw[0] * 10000) / 100;
};

-- NOTE: score_consumer_on_lead_change and score_consumer_on_conv_change
-- events removed. Java mapper now handles feature computation and
-- calls fn::score_consumer directly with pre-computed features.

-- NOTE: score_interaction_on_lead_change and score_interaction_on_conv_change
-- events removed. Java mapper now handles feature computation and
-- calls fn::score_interaction directly with pre-computed features.

-- NOTE: score_product_quotation_on_lead_change and
-- score_product_quotation_on_quotation_created events removed.
-- Java mapper now handles all feature computation and calls
-- fn::score_product_quotation directly with pre-computed features.




-- ============================================================
-- FUNCTION: fn::score_lead_qualification
-- All 20 features are pre-computed by the Java mapper and passed
-- directly. This function only invokes the ML model.
-- ============================================================
DEFINE FUNCTION fn::score_lead_qualification(
    $has_action_milestone:         float,  -- binary 0/1
    $stage_velocity:               float,  -- IQR bin 1/2/3  (Q1=0.48, Q3=1.86)
    $historical_deals_won:         float,  -- IQR bin 1/2/3  (Q1=0.0,  Q3=3.0)
    $is_repeat_customer:           float,  -- binary 0/1
    $industry_close_rate:          float,  -- IQR bin 1/2/3  (Q1=0.424,Q3=0.594)
    $historical_avg_sentiment:     float,  -- IQR bin 1/2/3  (Q1=-0.20,Q3=0.48)
    $intent:                       float,  -- bin 1/2/3      (raw 1-10 rebinned)
    $total_interactions:           float,  -- IQR bin 1/2/3  (Q1=4,    Q3=10)
    $is_multi_channel:             float,  -- binary 0/1
    $recency_bucket:               float,  -- 1=cold 2=stale 3=active 4=fresh
    $engagement_depth:             float,  -- IQR bin 1/2/3  (Q1=3.0,  Q3=5.0)
    $quotation_sent:               float,  -- binary 0/1
    $is_enterprise_deal:           float,  -- binary 0/1
    $pipeline_stage:               float,  -- label encoded 1-12 (alphabetical)
    $days_in_pipeline:             float,  -- IQR bin 1/2/3  (Q1=5,    Q3=25)
    $pipeline_velocity:            float,  -- IQR bin 1/2/3  (Q1=0.10, Q3=0.50)
    $total_price_with_tax:         float,  -- IQR bin 1/2/3  (Q1=50000,Q3=300000)
    $consumer_score_tier:          float,  -- tier 1=Low(<40) 2=Mid(40-70) 3=High(>70)
    $interaction_score_tier:       float,  -- tier same thresholds
    $product_quotation_score_tier: float   -- tier same thresholds
) {
    LET $raw = ml::lead_qualification<1.0.0>([
        $has_action_milestone,          -- [0]  binary 0/1
        $stage_velocity,                -- [1]  IQR bin 1/2/3
        $historical_deals_won,          -- [2]  IQR bin 1/2/3
        $is_repeat_customer,            -- [3]  binary 0/1
        $industry_close_rate,           -- [4]  IQR bin 1/2/3
        $historical_avg_sentiment,      -- [5]  IQR bin 1/2/3
        $intent,                        -- [6]  bin 1/2/3
        $total_interactions,            -- [7]  IQR bin 1/2/3
        $is_multi_channel,              -- [8]  binary 0/1
        $recency_bucket,                -- [9]  1/2/3/4
        $engagement_depth,              -- [10] IQR bin 1/2/3
        $quotation_sent,                -- [11] binary 0/1
        $is_enterprise_deal,            -- [12] binary 0/1
        $pipeline_stage,                -- [13] label encoded 1-12
        $days_in_pipeline,              -- [14] IQR bin 1/2/3
        $pipeline_velocity,             -- [15] IQR bin 1/2/3
        $total_price_with_tax,          -- [16] IQR bin 1/2/3
        $consumer_score_tier,           -- [17] tier 1/2/3
        $interaction_score_tier,        -- [18] tier 1/2/3
        $product_quotation_score_tier   -- [19] tier 1/2/3
    ]);

    RETURN math::round($raw[0] * 10000) / 100;
};

-- NOTE: score_lead_qualification_on_lead_change event removed.
-- Java mapper now handles all feature computation and calls
-- fn::score_lead_qualification directly with pre-computed features.


-- 3 Correct Test Queries
-- Query 1 — HIGH SCORE (hot lead)


RETURN {
    model: "consumer_score",
    score: ml::consumer_score<1.0.0>([
        6.0,  -- primary_sentiment: satisfied=6
        3.0,  -- sentiment_score: bin 3 (SATISFIED raw=1.0 > 0.67)
        3.0,  -- sentiment_combo_score: bin 3 (stage=6 × 1.0=6.0 > 5.0)
        3.0,  -- intent: closing=3
        4.0,  -- message_quality: detailed=4
        3.0,  -- summary_length: bin 3 (>281 chars)
        1.0,  -- has_action_milestone: 1
        3.0,  -- stage_velocity: bin 3 (fast)
        3.0,  -- historical_deals_won: bin 3 (>3 deals)
        1.0,  -- is_repeat_customer: 1
        3.0,  -- historical_avg_sentiment: bin 3
        3.0   -- industry_close_rate: bin 3 (Data Centers=0.67)
    ])
};
-- Query 2 — MEDIUM SCORE (interested lead)


RETURN {
    model: "consumer_score",
    score: ml::consumer_score<1.0.0>([
        4.0,  -- primary_sentiment: interested=4
        2.0,  -- sentiment_score: bin 2
        2.0,  -- sentiment_combo_score: bin 2
        5.0,  -- intent: evaluating=5
        2.0,  -- message_quality: medium=2
        2.0,  -- summary_length: bin 2
        0.0,  -- has_action_milestone: 0
        2.0,  -- stage_velocity: bin 2
        2.0,  -- historical_deals_won: bin 2
        1.0,  -- is_repeat_customer: 1
        2.0,  -- historical_avg_sentiment: bin 2
        2.0   -- industry_close_rate: bin 2
    ])
};
-- Query 3 — LOW SCORE (angry/cold lead)


RETURN {
    model: "consumer_score",
    score: ml::consumer_score<1.0.0>([
        1.0,  -- primary_sentiment: angry=1
        1.0,  -- sentiment_score: bin 1 (ANGRY raw=-1.0 <= -0.36)
        1.0,  -- sentiment_combo_score: bin 1
        1.0,  -- intent: at_risk=1
        1.0,  -- message_quality: short=1
        1.0,  -- summary_length: bin 1
        0.0,  -- has_action_milestone: 0
        1.0,  -- stage_velocity: bin 1
        1.0,  -- historical_deals_won: bin 1
        0.0,  -- is_repeat_customer: 0
        1.0,  -- historical_avg_sentiment: bin 1
        1.0   -- industry_close_rate: bin 1
    ])
};


RETURN ml::consumer_score<1.0.0>([
    6.0, 3.0, 3.0, 3.0, 4.0, 3.0, 1.0, 3.0, 3.0, 1.0, 3.0, 3.0
]);