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
-- FUNCTION: fn::infer_sentiment
-- ============================================================
DEFINE FUNCTION fn::infer_sentiment($context: string, $text: string) {
    LET $url = "https://llm.imonitorplus.com/vitalai/infersentiment/";
    LET $body = {
        "context": $context,
        "text": $text
    };
    LET $headers = {
        "Authorization": "Token e614a25d52419a9a46a915e06c4ffbed10a61a35",
        "Content-Type": "application/json"
    };
    RETURN http::post($url, $body, $headers);
};

-- ============================================================
-- EVENT: infer_sentiment_on_message
-- ============================================================
DEFINE EVENT infer_sentiment_on_message ON TABLE message
    WHEN $event = "CREATE" AND $value.content != NONE THEN {
        LET $conv = (SELECT summary FROM ONLY $value.conversation);
        LET $context = IF $conv.summary != NONE THEN $conv.summary ELSE "" END;

        LET $last_msg = (
            SELECT content, created_at FROM message
            WHERE conversation = $value.conversation
            ORDER BY created_at DESC LIMIT 1
        )[0];
        LET $text = IF $last_msg.content != NONE THEN $last_msg.content ELSE $value.content END;

        LET $api_response = fn::infer_sentiment($context, $text);

        LET $raw = type::string($api_response.labels);
        LET $raw_clean = string::replace(
            string::replace(
                string::replace(
                    string::replace($raw, "[", ""),
                "]", ""),
            "'", ""),
        " ", "");
        LET $raw_parts = string::split($raw_clean, ",");
        LET $sentiment_str = string::uppercase(string::trim($raw_parts[0]));

        UPDATE $value.conversation SET sentiment = $sentiment_str;
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
-- ============================================================
DEFINE FUNCTION fn::score_consumer($lead_id: record) {

    LET $lead = (SELECT * FROM ONLY $lead_id);

    LET $conv = (
        SELECT * FROM conversation
        WHERE lead = $lead_id
        ORDER BY last_message_at DESC LIMIT 1
    )[0];

    LET $msg = IF $conv != NONE THEN (
        SELECT * FROM message
        WHERE conversation = $conv.id
        ORDER BY created_at DESC LIMIT 1
    )[0] ELSE NONE END;

    LET $org = IF $lead.organisation != NONE THEN
        (SELECT * FROM ONLY $lead.organisation)
    ELSE NONE END;

    LET $stage_raw =
        IF $lead.state = "NEW_LEAD"                   THEN 0
        ELSE IF $lead.state = "MANUAL_FOLLOW_UP"      THEN 1
        ELSE IF $lead.state = "SALES_FOLLOW_UP"       THEN 2
        ELSE IF $lead.state = "SALES_QUALIFIED"       THEN 3
        ELSE IF $lead.state = "QUOTATION"             THEN 4
        ELSE IF $lead.state = "FOLLOW_UP_NEGOTIATION" THEN 5
        ELSE IF $lead.state = "CLOSED"                THEN 6
        ELSE 0 END;

    LET $now = time::now();
    LET $days_in_pipeline = math::max([
        math::floor(duration::secs($now - $lead.created_at) / 86400),
        1
    ]);

    LET $s = IF $conv != NONE THEN $conv.sentiment ELSE "NEUTRAL" END;

    -- Label encode alphabetically (1-7): angry=1,curious=2,dissatisfied=3,interested=4,negotiating=5,satisfied=6,urgent=7
    LET $primary_sentiment =
        IF $s = "ANGRY"                                  THEN 1
        ELSE IF $s = "CURIOUS"                           THEN 2
        ELSE IF $s = "DISSATISFIED" OR $s = "FRUSTRATED"
                OR $s = "NEGATIVE"                       THEN 3
        ELSE IF $s = "INTERESTED"                        THEN 4
        ELSE IF $s = "NEGOTIATING"                       THEN 5
        ELSE IF $s = "SATISFIED" OR $s = "POSITIVE"     THEN 6
        ELSE IF $s = "URGENT"                            THEN 7
        ELSE 2 END;

    -- Raw sentiment weight (-1.0 to 1.0), then IQR-bin: <=−0.36→1, <=0.67→2, >0.67→3
    LET $sentiment_score_raw =
        IF $s = "POSITIVE" OR $s = "SATISFIED" THEN 1.0
        ELSE IF $s = "INTERESTED"              THEN 0.8
        ELSE IF $s = "URGENT"                  THEN 0.75
        ELSE IF $s = "NEGOTIATING"             THEN 0.5
        ELSE IF $s = "CURIOUS"                 THEN 0.3
        ELSE IF $s = "NEUTRAL"                 THEN 0.0
        ELSE IF $s = "DISSATISFIED"            THEN -0.5
        ELSE IF $s = "FRUSTRATED"              THEN -0.7
        ELSE IF $s = "NEGATIVE"                THEN -1.0
        ELSE IF $s = "ANGRY"                   THEN -1.0
        ELSE 0.0 END;
    LET $sentiment_score =
        IF $sentiment_score_raw <= -0.36 THEN 1
        ELSE IF $sentiment_score_raw <= 0.67 THEN 2
        ELSE 3 END;

    -- Raw combo = stage × sentiment, then IQR-bin: <=1→1, <=5→2, >5→3
    LET $combo_raw = type::float($stage_raw) * $sentiment_score_raw;
    LET $sentiment_combo_score =
        IF $combo_raw <= 1.0 THEN 1
        ELSE IF $combo_raw <= 5.0 THEN 2
        ELSE 3 END;

    -- Map live sentiment+stage to training intent labels (alphabetical 1-10):
    -- at_risk=1, churning=2, closing=3, comparison_shopping=4, evaluating=5,
    -- information_seeking=6, negotiating=7, ready_to_buy=8, upsell_opportunity=9, window_shopping=10
    LET $intent =
        IF $s = "ANGRY"                                             THEN 1
        ELSE IF $s = "NEGATIVE" OR $s = "FRUSTRATED"
                OR $s = "DISSATISFIED"                             THEN 2
        ELSE IF ($s = "SATISFIED" OR $s = "URGENT") AND $stage_raw >= 4 THEN 3
        ELSE IF $s = "NEUTRAL" AND $stage_raw > 0                  THEN 4
        ELSE IF $s = "INTERESTED"                                   THEN 5
        ELSE IF $s = "CURIOUS"                                      THEN 6
        ELSE IF $s = "NEGOTIATING"                                  THEN 7
        ELSE IF $s = "POSITIVE" OR ($s = "URGENT" AND $stage_raw < 4) THEN 8
        ELSE IF $s = "SATISFIED" AND $stage_raw < 4                THEN 9
        ELSE 10 END;

    -- Ordinal encode: short=1, medium=2, long=3, detailed=4
    LET $msg_len = IF $msg != NONE AND $msg.content != NONE
        THEN string::len($msg.content) ELSE 0 END;
    LET $message_quality =
        IF $msg_len > 200      THEN 4
        ELSE IF $msg_len > 100 THEN 3
        ELSE IF $msg_len > 50  THEN 2
        ELSE 1 END;

    -- Raw summary length, then IQR-bin: <=163→1, <=281→2, >281→3
    LET $summary_len_raw = IF $conv != NONE AND $conv.summary != NONE
        THEN string::len($conv.summary)
        ELSE 0 END;
    LET $summary_length =
        IF $summary_len_raw <= 163 THEN 1
        ELSE IF $summary_len_raw <= 281 THEN 2
        ELSE 3 END;

    -- Binary 0/1, no change
    LET $has_action_milestone = IF $stage_raw >= 4 THEN 1 ELSE 0 END;

    -- Raw velocity, then IQR-bin: <=0.48→1, <=1.86→2, >1.86→3
    LET $stage_velocity_raw = type::float($stage_raw) / type::float($days_in_pipeline);
    LET $stage_velocity =
        IF $stage_velocity_raw <= 0.48 THEN 1
        ELSE IF $stage_velocity_raw <= 1.86 THEN 2
        ELSE 3 END;

    -- Raw deals won, then IQR-bin: <=0→1, <=3→2, >3→3
    LET $historical_deals_won_raw = type::float($org.historical_deals_won ?? 0);
    LET $historical_deals_won =
        IF $historical_deals_won_raw <= 0.0 THEN 1
        ELSE IF $historical_deals_won_raw <= 3.0 THEN 2
        ELSE 3 END;

    -- Binary 0/1, no change
    LET $is_repeat_customer = IF $historical_deals_won_raw > 0 THEN 1 ELSE 0 END;

    -- Raw avg sentiment, then IQR-bin: <=-0.20→1, <=0.48→2, >0.48→3
    LET $historical_avg_sentiment_raw = type::float($org.historical_avg_sentiment ?? 0.0);
    LET $historical_avg_sentiment =
        IF $historical_avg_sentiment_raw <= -0.20 THEN 1
        ELSE IF $historical_avg_sentiment_raw <= 0.48 THEN 2
        ELSE 3 END;

    -- Raw industry close rate, then IQR-bin: <=0.424→1, <=0.594→2, >0.594→3
    LET $industry = $org.industry ?? "";
    LET $industry_close_rate_raw =
        IF $industry = "Data Centers"                   THEN 0.67
        ELSE IF $industry = "Cold Chain Logistics"      THEN 0.62
        ELSE IF $industry = "Semiconductor Fabrication" THEN 0.60
        ELSE IF $industry = "Dairy Processing"          THEN 0.58
        ELSE IF $industry = "Breweries & Beverages"     THEN 0.55
        ELSE IF $industry = "Food Processing"           THEN 0.55
        ELSE IF $industry = "Defence & Aerospace"       THEN 0.53
        ELSE IF $industry = "Pharmaceuticals"           THEN 0.52
        ELSE IF $industry = "Automotive"                THEN 0.50
        ELSE IF $industry = "Hospitality"               THEN 0.50
        ELSE IF $industry = "Chemicals"                 THEN 0.48
        ELSE IF $industry = "Real Estate"               THEN 0.47
        ELSE IF $industry = "Oil & Gas"                 THEN 0.45
        ELSE IF $industry = "Power Generation"          THEN 0.45
        ELSE IF $industry = "Glass Manufacturing"       THEN 0.44
        ELSE IF $industry = "Paper & Pulp"              THEN 0.43
        ELSE IF $industry = "Steel Manufacturing"       THEN 0.42
        ELSE IF $industry = "Rubber & Tyres"            THEN 0.41
        ELSE IF $industry = "Plastics"                  THEN 0.40
        ELSE IF $industry = "Textiles"                  THEN 0.38
        ELSE 0.48 END;
    LET $industry_close_rate =
        IF $industry_close_rate_raw <= 0.424 THEN 1
        ELSE IF $industry_close_rate_raw <= 0.594 THEN 2
        ELSE 3 END;

    LET $raw = ml::consumer_score<1.0.0>([
        $primary_sentiment,        -- label encoded 1-7
        $sentiment_score,          -- IQR binned 1/2/3
        $sentiment_combo_score,    -- IQR binned 1/2/3
        $intent,                   -- label encoded 1-10
        $message_quality,          -- ordinal 1-4
        $summary_length,           -- IQR binned 1/2/3
        $has_action_milestone,     -- binary 0/1
        $stage_velocity,           -- IQR binned 1/2/3
        $historical_deals_won,     -- IQR binned 1/2/3
        $is_repeat_customer,       -- binary 0/1
        $historical_avg_sentiment, -- IQR binned 1/2/3
        $industry_close_rate       -- IQR binned 1/2/3
    ]);

    RETURN math::round($raw[0] * 10000) / 100;
};

-- ============================================================
-- FUNCTION: fn::score_interaction
-- ============================================================
DEFINE FUNCTION fn::score_interaction($lead_id: record) {

    LET $lead = (SELECT * FROM ONLY $lead_id);

    LET $org = IF $lead.organisation != NONE THEN
        (SELECT * FROM ONLY $lead.organisation)
    ELSE NONE END;

    LET $stage_raw =
        IF $lead.state = "NEW_LEAD"                   THEN 0
        ELSE IF $lead.state = "MANUAL_FOLLOW_UP"      THEN 1
        ELSE IF $lead.state = "SALES_FOLLOW_UP"       THEN 2
        ELSE IF $lead.state = "SALES_QUALIFIED"       THEN 3
        ELSE IF $lead.state = "QUOTATION"             THEN 4
        ELSE IF $lead.state = "FOLLOW_UP_NEGOTIATION" THEN 5
        ELSE IF $lead.state = "CLOSED"                THEN 6
        ELSE 0 END;

    LET $whatsapp_count = type::float(
        (SELECT count() FROM conversation
         WHERE lead = $lead_id AND channel = channel:whatsapp GROUP ALL)[0].count ?? 0
    );

    LET $phone_count = type::float(
        (SELECT count() FROM conversation
         WHERE lead = $lead_id AND (channel = channel:voice OR channel = channel:phone)
         GROUP ALL)[0].count ?? 0
    );

    LET $email_count = type::float(
        (SELECT count() FROM conversation
         WHERE lead = $lead_id AND (channel = channel:email OR channel = channel:web)
         GROUP ALL)[0].count ?? 0
    );

    LET $total_interactions = $whatsapp_count + $phone_count + $email_count;

    LET $dominant_channel =
        IF $whatsapp_count >= $phone_count AND $whatsapp_count >= $email_count THEN 2.0
        ELSE IF $phone_count >= $whatsapp_count AND $phone_count >= $email_count THEN 1.0
        ELSE 0.0 END;

    LET $first_conv = (
        SELECT id, started_at, channel FROM conversation
        WHERE lead = $lead_id
        ORDER BY started_at ASC LIMIT 1
    )[0];

    LET $last_conv = (
        SELECT id, last_message_at, channel, sentiment FROM conversation
        WHERE lead = $lead_id
        ORDER BY last_message_at DESC LIMIT 1
    )[0];

    LET $first_ch = IF $first_conv != NONE
        THEN string::split(type::string($first_conv.channel), ":")[1]
        ELSE "whatsapp" END;
    LET $first_channel =
        IF $first_ch = "email" OR $first_ch = "web"        THEN 0.0
        ELSE IF $first_ch = "voice" OR $first_ch = "phone" THEN 1.0
        ELSE 2.0 END;

    LET $last_ch = IF $last_conv != NONE
        THEN string::split(type::string($last_conv.channel), ":")[1]
        ELSE $first_ch END;
    LET $last_channel =
        IF $last_ch = "email" OR $last_ch = "web"          THEN 0.0
        ELSE IF $last_ch = "voice" OR $last_ch = "phone"   THEN 1.0
        ELSE 2.0 END;

    LET $distinct_ch = (IF $whatsapp_count > 0 THEN 1 ELSE 0 END)
                     + (IF $phone_count    > 0 THEN 1 ELSE 0 END)
                     + (IF $email_count    > 0 THEN 1 ELSE 0 END);
    LET $is_multi_channel     = IF $distinct_ch > 1 THEN 1.0 ELSE 0.0 END;
    LET $channel_switch_count = IF $distinct_ch > 1 THEN type::float($distinct_ch - 1) ELSE 0.0 END;

    LET $now = time::now();
    LET $t_start = $first_conv.started_at ?? $now;
    LET $t_end   = $last_conv.last_message_at ?? $now;
    LET $conversation_time_hours = duration::secs($t_end - $t_start) / 3600.0;

    LET $conv_time_bucket =
        IF $total_interactions >= 5 AND $conversation_time_hours <= 48  THEN 0.0
        ELSE IF $total_interactions >= 3 AND $conversation_time_hours <= 72  THEN 1.0
        ELSE IF $total_interactions >= 3 AND $conversation_time_hours <= 168 THEN 2.0
        ELSE IF $total_interactions >= 2 AND $conversation_time_hours > 168  THEN 3.0
        ELSE 4.0 END;

    LET $days_since = duration::secs($now - ($last_conv.last_message_at ?? $now)) / 86400.0;
    LET $recency_bucket =
        IF $days_since <= 3  THEN 2.0
        ELSE IF $days_since <= 7  THEN 0.0
        ELSE IF $days_since <= 21 THEN 3.0
        ELSE 1.0 END;

    LET $last_s = $last_conv.sentiment ?? "NEUTRAL";
    LET $sent_w =
        IF $last_s = "POSITIVE" OR $last_s = "SATISFIED" THEN 1.0
        ELSE IF $last_s = "INTERESTED"                   THEN 0.8
        ELSE IF $last_s = "URGENT"                       THEN 0.75
        ELSE IF $last_s = "NEGOTIATING"                  THEN 0.5
        ELSE IF $last_s = "CURIOUS"                      THEN 0.3
        ELSE IF $last_s = "NEUTRAL"                      THEN 0.0
        ELSE IF $last_s = "DISSATISFIED"                 THEN -0.5
        ELSE -1.0 END;
    LET $engagement_depth = $total_interactions * $sent_w;

    LET $channel_x_stage = $dominant_channel * type::float($stage_raw);

    LET $historical_deals_won = type::float($org.historical_deals_won ?? 0);

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
-- ============================================================
DEFINE FUNCTION fn::score_product_quotation($lead_id: record) {

    LET $lead = (SELECT * FROM ONLY $lead_id);

    LET $product = (SELECT * FROM ($lead_id->interested_in->product))[0];

    LET $org = IF $lead.organisation != NONE THEN
        (SELECT * FROM ONLY $lead.organisation)
    ELSE NONE END;

    LET $has_quotation = (
        SELECT count() FROM generated_quotation
        WHERE in = $lead_id GROUP ALL
    )[0].count > 0;

    LET $stage_raw =
        IF $lead.state = "NEW_LEAD"                   THEN 0
        ELSE IF $lead.state = "MANUAL_FOLLOW_UP"      THEN 1
        ELSE IF $lead.state = "SALES_FOLLOW_UP"       THEN 2
        ELSE IF $lead.state = "SALES_QUALIFIED"       THEN 3
        ELSE IF $lead.state = "QUOTATION"             THEN 4
        ELSE IF $lead.state = "FOLLOW_UP_NEGOTIATION" THEN 5
        ELSE IF $lead.state = "CLOSED"                THEN 6
        ELSE 0 END;

    LET $now = time::now();
    LET $days_in_pipeline = type::float(math::max([
        math::floor(duration::secs($now - $lead.created_at) / 86400),
        1
    ]));

    LET $pname      = $product.name             ?? "";
    LET $base_price = type::float($product.base_price ?? 0.0);
    LET $tax_rate   = type::float($product.tax_rate   ?? 18.0);
    LET $total_price = $base_price * (1.0 + $tax_rate / 100.0);
    LET $ptype      = $product.attributes.type  ?? "";
    LET $capacity_tons = type::float(
        $product.capacity_tons ??
        ($product.attributes.capacity_tons ?? 14.0832)
    );

    LET $product_category =
        IF string::contains(string::lowercase($pname), "chiller") THEN 0.0
        ELSE IF string::contains(string::lowercase($pname), "cooler") THEN 1.0
        ELSE IF string::contains(string::lowercase($pname), "combo")  THEN 2.0
        ELSE 0.0 END;

    LET $product_type =
        IF $ptype = "centrifugal"  THEN 0.0
        ELSE IF $ptype = "combo"   THEN 1.0
        ELSE IF $ptype = "economy" THEN 2.0
        ELSE IF $ptype = "glycol"  THEN 3.0
        ELSE IF $ptype = "industrial" THEN 4.0
        ELSE IF $ptype = "modular" THEN 5.0
        ELSE IF $ptype = "package" THEN 6.0
        ELSE IF $ptype = "portable" THEN 7.0
        ELSE IF $ptype = "premium" THEN 8.0
        ELSE IF $ptype = "rooftop" THEN 9.0
        ELSE IF $ptype = "single"  THEN 10.0
        ELSE IF $ptype = "screw"   THEN 11.0
        ELSE 0.0 END;

    LET $product_complexity =
        IF $ptype = "centrifugal"  THEN 4.5
        ELSE IF $ptype = "premium" THEN 4.0
        ELSE IF $ptype = "industrial" OR $ptype = "screw" THEN 3.5
        ELSE IF $ptype = "modular" THEN 3.0
        ELSE IF $ptype = "glycol" OR $ptype = "rooftop" THEN 2.5
        ELSE IF $ptype = "package" OR $ptype = "combo"  THEN 2.0
        ELSE IF $ptype = "portable" OR $ptype = "economy" THEN 1.5
        ELSE IF $ptype = "single"  THEN 1.0
        ELSE 2.0 END;

    LET $price_tier =
        IF $base_price >= 400000      THEN 0.0
        ELSE IF $base_price >= 200000 THEN 1.0
        ELSE IF $base_price >= 100000 THEN 3.0
        ELSE 2.0 END;

    LET $capacity_bin =
        IF $capacity_tons <= 5        THEN 0.0
        ELSE IF $capacity_tons <= 10  THEN 4.0
        ELSE IF $capacity_tons <= 20  THEN 1.0
        ELSE IF $capacity_tons <= 50  THEN 2.0
        ELSE 3.0 END;

    LET $product_x_capacity = $product_type * 5.0 + $capacity_bin;

    LET $capacity_price_ratio = IF $total_price > 0
        THEN $capacity_tons / $total_price ELSE 0.0 END;

    LET $quotation_sent     = IF $has_quotation THEN 1.0 ELSE 0.0 END;
    LET $is_enterprise_deal = IF $base_price >= 400000 THEN 1.0 ELSE 0.0 END;

    LET $industry = $org.industry ?? "";
    LET $industry_close_rate =
        IF $industry = "Data Centers"                   THEN 0.67
        ELSE IF $industry = "Cold Chain Logistics"      THEN 0.62
        ELSE IF $industry = "Semiconductor Fabrication" THEN 0.60
        ELSE IF $industry = "Dairy Processing"          THEN 0.58
        ELSE IF $industry = "Breweries & Beverages"     THEN 0.55
        ELSE IF $industry = "Food Processing"           THEN 0.55
        ELSE IF $industry = "Defence & Aerospace"       THEN 0.53
        ELSE IF $industry = "Pharmaceuticals"           THEN 0.52
        ELSE IF $industry = "Automotive"                THEN 0.50
        ELSE IF $industry = "Hospitality"               THEN 0.50
        ELSE IF $industry = "Chemicals"                 THEN 0.48
        ELSE IF $industry = "Real Estate"               THEN 0.47
        ELSE IF $industry = "Oil & Gas"                 THEN 0.45
        ELSE IF $industry = "Power Generation"          THEN 0.45
        ELSE IF $industry = "Glass Manufacturing"       THEN 0.44
        ELSE IF $industry = "Paper & Pulp"              THEN 0.43
        ELSE IF $industry = "Steel Manufacturing"       THEN 0.42
        ELSE IF $industry = "Rubber & Tyres"            THEN 0.41
        ELSE IF $industry = "Plastics"                  THEN 0.40
        ELSE IF $industry = "Textiles"                  THEN 0.38
        ELSE 0.48 END;

    LET $is_repeat_customer = IF type::float($org.historical_deals_won ?? 0) > 0 THEN 1.0 ELSE 0.0 END;
    LET $pipeline_velocity  = type::float($stage_raw) / $days_in_pipeline;

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
        type::float($stage_raw),
        $is_repeat_customer,
        $days_in_pipeline,
        $pipeline_velocity
    ]);

    RETURN math::round($raw[0] * 10000) / 100;
};

-- ============================================================
-- EVENT: score_consumer_on_lead_change
-- ============================================================
DEFINE EVENT score_consumer_on_lead_change ON TABLE lead
    WHEN $event = "CREATE"
      OR ($event = "UPDATE" AND (
            $before.state        != $value.state        OR
            $before.completeness != $value.completeness OR
            $before.organisation != $value.organisation
         )) THEN {
        LET $cs = fn::score_consumer($value.id);
        -- ✅ FIX: SELECT id + last_message_at so ORDER BY is valid
        LET $conv_row = (
            SELECT id, last_message_at FROM conversation
            WHERE lead = $value.id
            ORDER BY last_message_at DESC LIMIT 1
        )[0];
        LET $conv = $conv_row.id;
        UPDATE $value.id SET consumer_score = $cs;
        LET $ex = (SELECT id FROM consumer_score_result WHERE lead = $value.id LIMIT 1)[0];
        IF $ex != NONE THEN {
            UPDATE $ex.id SET conversation = $conv, score = $cs, scored_at = time::now();
        } ELSE {
            CREATE consumer_score_result SET lead = $value.id, conversation = $conv, score = $cs, scored_at = time::now();
        } END;
    };

-- ============================================================
-- EVENT: score_consumer_on_conv_change
-- ============================================================
DEFINE EVENT score_consumer_on_conv_change ON TABLE conversation
    WHEN $event = "CREATE"
      OR ($event = "UPDATE" AND (
            $before.sentiment != $value.sentiment OR
            $before.summary   != $value.summary
         )) THEN {
        LET $lid = $value.lead;
        LET $cs  = fn::score_consumer($lid);
        UPDATE $lid SET consumer_score = $cs;
        LET $ex = (SELECT id FROM consumer_score_result WHERE lead = $lid LIMIT 1)[0];
        IF $ex != NONE THEN {
            UPDATE $ex.id SET conversation = $value.id, score = $cs, scored_at = time::now();
        } ELSE {
            CREATE consumer_score_result SET lead = $lid, conversation = $value.id, score = $cs, scored_at = time::now();
        } END;
    };

-- ============================================================
-- EVENT: score_interaction_on_lead_change
-- ============================================================
DEFINE EVENT score_interaction_on_lead_change ON TABLE lead
    WHEN $event = "CREATE"
      OR ($event = "UPDATE" AND (
            $before.state        != $value.state        OR
            $before.organisation != $value.organisation
         )) THEN {
        LET $is = fn::score_interaction($value.id);
        -- ✅ FIX: SELECT id + last_message_at so ORDER BY is valid
        LET $conv_row = (
            SELECT id, last_message_at FROM conversation
            WHERE lead = $value.id
            ORDER BY last_message_at DESC LIMIT 1
        )[0];
        LET $conv = $conv_row.id;
        UPDATE $value.id SET interaction_score = $is;
        LET $ex = (SELECT id FROM interaction_score_result WHERE lead = $value.id LIMIT 1)[0];
        IF $ex != NONE THEN {
            UPDATE $ex.id SET conversation = $conv, score = $is, scored_at = time::now();
        } ELSE {
            CREATE interaction_score_result SET lead = $value.id, conversation = $conv, score = $is, scored_at = time::now();
        } END;
    };

-- ============================================================
-- EVENT: score_interaction_on_conv_change
-- ============================================================
DEFINE EVENT score_interaction_on_conv_change ON TABLE conversation
    WHEN $event = "CREATE"
      OR ($event = "UPDATE" AND (
            $before.sentiment       != $value.sentiment       OR
            $before.last_message_at != $value.last_message_at
         )) THEN {
        LET $lid = $value.lead;
        LET $is  = fn::score_interaction($lid);
        UPDATE $lid SET interaction_score = $is;
        LET $ex = (SELECT id FROM interaction_score_result WHERE lead = $lid LIMIT 1)[0];
        IF $ex != NONE THEN {
            UPDATE $ex.id SET conversation = $value.id, score = $is, scored_at = time::now();
        } ELSE {
            CREATE interaction_score_result SET lead = $lid, conversation = $value.id, score = $is, scored_at = time::now();
        } END;
    };

-- ============================================================
-- EVENT: score_product_quotation_on_lead_change
-- ============================================================
DEFINE EVENT score_product_quotation_on_lead_change ON TABLE lead
    WHEN $event = "CREATE"
      OR ($event = "UPDATE" AND (
            $before.state        != $value.state        OR
            $before.completeness != $value.completeness OR
            $before.organisation != $value.organisation
         )) THEN {
        LET $pq = fn::score_product_quotation($value.id);
        -- ✅ FIX: SELECT id + last_message_at so ORDER BY is valid
        LET $conv_row = (
            SELECT id, last_message_at FROM conversation
            WHERE lead = $value.id
            ORDER BY last_message_at DESC LIMIT 1
        )[0];
        LET $conv = $conv_row.id;
        UPDATE $value.id SET product_quotation_score = $pq;
        LET $ex = (SELECT id FROM product_quotation_score_result WHERE lead = $value.id LIMIT 1)[0];
        IF $ex != NONE THEN {
            UPDATE $ex.id SET conversation = $conv, score = $pq, scored_at = time::now();
        } ELSE {
            CREATE product_quotation_score_result SET lead = $value.id, conversation = $conv, score = $pq, scored_at = time::now();
        } END;
    };

-- ============================================================
-- EVENT: score_product_quotation_on_quotation_created
-- ============================================================
DEFINE EVENT score_product_quotation_on_quotation_created ON TABLE generated_quotation
    WHEN $event = "CREATE" THEN {
        LET $lid = $value.in;
        LET $pq  = fn::score_product_quotation($lid);
        -- ✅ FIX: SELECT id + last_message_at so ORDER BY is valid
        LET $conv_row = (
            SELECT id, last_message_at FROM conversation
            WHERE lead = $lid
            ORDER BY last_message_at DESC LIMIT 1
        )[0];
        LET $conv = $conv_row.id;
        UPDATE $lid SET product_quotation_score = $pq;
        LET $ex = (SELECT id FROM product_quotation_score_result WHERE lead = $lid LIMIT 1)[0];
        IF $ex != NONE THEN {
            UPDATE $ex.id SET conversation = $conv, score = $pq, scored_at = time::now();
        } ELSE {
            CREATE product_quotation_score_result SET lead = $lid, conversation = $conv, score = $pq, scored_at = time::now();
        } END;
    };




-- ============================================================
-- FUNCTION: fn::score_lead_qualification
-- ============================================================
DEFINE FUNCTION fn::score_lead_qualification($lead_id: record) {

    LET $lead = (SELECT * FROM ONLY $lead_id);

    LET $org = IF $lead.organisation != NONE THEN
        (SELECT * FROM ONLY $lead.organisation)
    ELSE NONE END;

    LET $product = (SELECT * FROM ($lead_id->interested_in->product))[0];

    -- 0-6 internal stage scale (same as other functions)
    LET $stage_raw =
        IF $lead.state = "NEW_LEAD"                   THEN 0
        ELSE IF $lead.state = "MANUAL_FOLLOW_UP"      THEN 1
        ELSE IF $lead.state = "SALES_FOLLOW_UP"       THEN 2
        ELSE IF $lead.state = "SALES_QUALIFIED"       THEN 3
        ELSE IF $lead.state = "QUOTATION"             THEN 4
        ELSE IF $lead.state = "FOLLOW_UP_NEGOTIATION" THEN 5
        ELSE IF $lead.state = "CLOSED"                THEN 6
        ELSE 0 END;

    -- pipeline_stage feature: lead_qualification uses 1-12 label encoding (alphabetical)
    LET $pipeline_stage =
        IF $lead.state = "CLOSED"                THEN 1
        ELSE IF $lead.state = "FOLLOW_UP_NEGOTIATION" THEN 4
        ELSE IF $lead.state = "MANUAL_FOLLOW_UP" THEN 6
        ELSE IF $lead.state = "NEW_LEAD"         THEN 7
        ELSE IF $lead.state = "QUOTATION"        THEN 10
        ELSE IF $lead.state = "SALES_FOLLOW_UP"  THEN 11
        ELSE IF $lead.state = "SALES_QUALIFIED"  THEN 12
        ELSE 7 END;

    LET $has_action_milestone = IF $stage_raw >= 4 THEN 1 ELSE 0 END;

    LET $now = time::now();
    LET $days_in_pipeline_raw = type::float(math::max([
        math::floor(duration::secs($now - $lead.created_at) / 86400),
        1
    ]));
    LET $days_in_pipeline =
        IF $days_in_pipeline_raw <= 5  THEN 1
        ELSE IF $days_in_pipeline_raw <= 25 THEN 2
        ELSE 3 END;

    LET $stage_velocity_raw = type::float($stage_raw) / $days_in_pipeline_raw;
    LET $stage_velocity =
        IF $stage_velocity_raw <= 0.48 THEN 1
        ELSE IF $stage_velocity_raw <= 1.86 THEN 2
        ELSE 3 END;

    -- pipeline_velocity uses different cutoffs than stage_velocity
    LET $pipeline_velocity =
        IF $stage_velocity_raw <= 0.10 THEN 1
        ELSE IF $stage_velocity_raw <= 0.50 THEN 2
        ELSE 3 END;

    LET $historical_deals_won_raw = type::float($org.historical_deals_won ?? 0);
    LET $historical_deals_won =
        IF $historical_deals_won_raw <= 0.0 THEN 1
        ELSE IF $historical_deals_won_raw <= 3.0 THEN 2
        ELSE 3 END;

    LET $is_repeat_customer = IF $historical_deals_won_raw > 0 THEN 1 ELSE 0 END;

    LET $historical_avg_sentiment_raw = type::float($org.historical_avg_sentiment ?? 0.0);
    LET $historical_avg_sentiment =
        IF $historical_avg_sentiment_raw <= -0.20 THEN 1
        ELSE IF $historical_avg_sentiment_raw <= 0.48 THEN 2
        ELSE 3 END;

    LET $industry = $org.industry ?? "";
    LET $industry_close_rate_raw =
        IF $industry = "Data Centers"                   THEN 0.67
        ELSE IF $industry = "Cold Chain Logistics"      THEN 0.62
        ELSE IF $industry = "Semiconductor Fabrication" THEN 0.60
        ELSE IF $industry = "Dairy Processing"          THEN 0.58
        ELSE IF $industry = "Breweries & Beverages"     THEN 0.55
        ELSE IF $industry = "Food Processing"           THEN 0.55
        ELSE IF $industry = "Defence & Aerospace"       THEN 0.53
        ELSE IF $industry = "Pharmaceuticals"           THEN 0.52
        ELSE IF $industry = "Automotive"                THEN 0.50
        ELSE IF $industry = "Hospitality"               THEN 0.50
        ELSE IF $industry = "Chemicals"                 THEN 0.48
        ELSE IF $industry = "Real Estate"               THEN 0.47
        ELSE IF $industry = "Oil & Gas"                 THEN 0.45
        ELSE IF $industry = "Power Generation"          THEN 0.45
        ELSE IF $industry = "Glass Manufacturing"       THEN 0.44
        ELSE IF $industry = "Paper & Pulp"              THEN 0.43
        ELSE IF $industry = "Steel Manufacturing"       THEN 0.42
        ELSE IF $industry = "Rubber & Tyres"            THEN 0.41
        ELSE IF $industry = "Plastics"                  THEN 0.40
        ELSE IF $industry = "Textiles"                  THEN 0.38
        ELSE 0.48 END;
    LET $industry_close_rate =
        IF $industry_close_rate_raw <= 0.424 THEN 1
        ELSE IF $industry_close_rate_raw <= 0.594 THEN 2
        ELSE 3 END;

    LET $last_conv = (
        SELECT id, last_message_at, sentiment FROM conversation
        WHERE lead = $lead_id
        ORDER BY last_message_at DESC LIMIT 1
    )[0];

    LET $whatsapp_count = type::float(
        (SELECT count() FROM conversation
         WHERE lead = $lead_id AND channel = channel:whatsapp GROUP ALL)[0].count ?? 0
    );
    LET $phone_count = type::float(
        (SELECT count() FROM conversation
         WHERE lead = $lead_id AND (channel = channel:voice OR channel = channel:phone)
         GROUP ALL)[0].count ?? 0
    );
    LET $email_count = type::float(
        (SELECT count() FROM conversation
         WHERE lead = $lead_id AND (channel = channel:email OR channel = channel:web)
         GROUP ALL)[0].count ?? 0
    );
    LET $total_interactions_raw = $whatsapp_count + $phone_count + $email_count;
    LET $total_interactions =
        IF $total_interactions_raw <= 4  THEN 1
        ELSE IF $total_interactions_raw <= 10 THEN 2
        ELSE 3 END;

    LET $distinct_ch = (IF $whatsapp_count > 0 THEN 1 ELSE 0 END)
                     + (IF $phone_count    > 0 THEN 1 ELSE 0 END)
                     + (IF $email_count    > 0 THEN 1 ELSE 0 END);
    LET $is_multi_channel = IF $distinct_ch > 1 THEN 1 ELSE 0 END;

    -- recency: fresh(≤3d)=4, active(≤7d)=3, stale(≤21d)=2, cold(>21d)=1
    LET $days_since = duration::secs($now - ($last_conv.last_message_at ?? $now)) / 86400.0;
    LET $recency_bucket =
        IF $days_since <= 3  THEN 4
        ELSE IF $days_since <= 7  THEN 3
        ELSE IF $days_since <= 21 THEN 2
        ELSE 1 END;

    LET $s = $last_conv.sentiment ?? "NEUTRAL";
    LET $sent_w =
        IF $s = "POSITIVE" OR $s = "SATISFIED" THEN 1.0
        ELSE IF $s = "INTERESTED"              THEN 0.8
        ELSE IF $s = "URGENT"                  THEN 0.75
        ELSE IF $s = "NEGOTIATING"             THEN 0.5
        ELSE IF $s = "CURIOUS"                 THEN 0.3
        ELSE IF $s = "NEUTRAL"                 THEN 0.0
        ELSE IF $s = "DISSATISFIED"            THEN -0.5
        ELSE -1.0 END;
    LET $engagement_depth_raw = $total_interactions_raw * $sent_w;
    LET $engagement_depth =
        IF $engagement_depth_raw <= 3.0 THEN 1
        ELSE IF $engagement_depth_raw <= 5.0 THEN 2
        ELSE 3 END;

    -- intent: derive same as fn::score_consumer (1-10), then rebin for lead_qualification (1-2→1, 3-7→2, 8-10→3)
    LET $intent_raw =
        IF $s = "ANGRY"                                              THEN 1
        ELSE IF $s = "NEGATIVE" OR $s = "FRUSTRATED"
                OR $s = "DISSATISFIED"                              THEN 2
        ELSE IF ($s = "SATISFIED" OR $s = "URGENT") AND $stage_raw >= 4 THEN 3
        ELSE IF $s = "NEUTRAL" AND $stage_raw > 0                   THEN 4
        ELSE IF $s = "INTERESTED"                                    THEN 5
        ELSE IF $s = "CURIOUS"                                       THEN 6
        ELSE IF $s = "NEGOTIATING"                                   THEN 7
        ELSE IF $s = "POSITIVE" OR ($s = "URGENT" AND $stage_raw < 4) THEN 8
        ELSE IF $s = "SATISFIED" AND $stage_raw < 4                 THEN 9
        ELSE 10 END;
    LET $intent =
        IF $intent_raw <= 2 THEN 1
        ELSE IF $intent_raw <= 7 THEN 2
        ELSE 3 END;

    LET $has_quotation = (
        SELECT count() FROM generated_quotation
        WHERE in = $lead_id GROUP ALL
    )[0].count > 0;
    LET $quotation_sent = IF $has_quotation THEN 1 ELSE 0 END;

    LET $base_price     = type::float($product.base_price ?? 0.0);
    LET $tax_rate       = type::float($product.tax_rate   ?? 18.0);
    LET $total_price_raw = $base_price * (1.0 + $tax_rate / 100.0);
    LET $total_price_with_tax =
        IF $total_price_raw <= 50000   THEN 1
        ELSE IF $total_price_raw <= 300000 THEN 2
        ELSE 3 END;
    LET $is_enterprise_deal = IF $base_price >= 400000 THEN 1 ELSE 0 END;

    -- tier thresholds: <40=Low(1), 40-70=Medium(2), >70=High(3)
    LET $consumer_score_tier =
        IF ($lead.consumer_score ?? 0) < 40    THEN 1
        ELSE IF ($lead.consumer_score ?? 0) <= 70 THEN 2
        ELSE 3 END;
    LET $interaction_score_tier =
        IF ($lead.interaction_score ?? 0) < 40    THEN 1
        ELSE IF ($lead.interaction_score ?? 0) <= 70 THEN 2
        ELSE 3 END;
    LET $product_quotation_score_tier =
        IF ($lead.product_quotation_score ?? 0) < 40    THEN 1
        ELSE IF ($lead.product_quotation_score ?? 0) <= 70 THEN 2
        ELSE 3 END;

    LET $raw = ml::lead_qualification<1.0.0>([
        type::float($has_action_milestone),         -- [0]  binary 0/1
        type::float($stage_velocity),               -- [1]  IQR bin 1/2/3
        type::float($historical_deals_won),         -- [2]  IQR bin 1/2/3
        type::float($is_repeat_customer),           -- [3]  binary 0/1
        type::float($industry_close_rate),          -- [4]  IQR bin 1/2/3
        type::float($historical_avg_sentiment),     -- [5]  IQR bin 1/2/3
        type::float($intent),                       -- [6]  bin 1/2/3
        type::float($total_interactions),           -- [7]  IQR bin 1/2/3
        type::float($is_multi_channel),             -- [8]  binary 0/1
        type::float($recency_bucket),               -- [9]  1/2/3/4
        type::float($engagement_depth),             -- [10] IQR bin 1/2/3
        type::float($quotation_sent),               -- [11] binary 0/1
        type::float($is_enterprise_deal),           -- [12] binary 0/1
        type::float($pipeline_stage),               -- [13] label encoded 1-12
        type::float($days_in_pipeline),             -- [14] IQR bin 1/2/3
        type::float($pipeline_velocity),            -- [15] IQR bin 1/2/3
        type::float($total_price_with_tax),         -- [16] IQR bin 1/2/3
        type::float($consumer_score_tier),          -- [17] tier 1/2/3
        type::float($interaction_score_tier),       -- [18] tier 1/2/3
        type::float($product_quotation_score_tier)  -- [19] tier 1/2/3
    ]);

    RETURN math::round($raw[0] * 10000) / 100;
};

-- ============================================================
-- EVENT: score_lead_qualification_on_lead_change
-- Fires when any sub-score or pipeline stage changes on a lead
-- ============================================================
DEFINE EVENT score_lead_qualification_on_lead_change ON TABLE lead
    WHEN $event = "UPDATE" AND (
        $before.consumer_score          != $value.consumer_score          OR
        $before.interaction_score       != $value.interaction_score       OR
        $before.product_quotation_score != $value.product_quotation_score OR
        $before.state                   != $value.state
    ) THEN {
        LET $lq = fn::score_lead_qualification($value.id);
        LET $conv_row = (
            SELECT id, last_message_at FROM conversation
            WHERE lead = $value.id
            ORDER BY last_message_at DESC LIMIT 1
        )[0];
        LET $conv = $conv_row.id;
        UPDATE $value.id SET lead_qualification_score = $lq;
        LET $ex = (SELECT id FROM lead_qualification_score_result WHERE lead = $value.id LIMIT 1)[0];
        IF $ex != NONE THEN {
            UPDATE $ex.id SET conversation = $conv, score = $lq, scored_at = time::now();
        } ELSE {
            CREATE lead_qualification_score_result SET lead = $value.id, conversation = $conv, score = $lq, scored_at = time::now();
        } END;
    };


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