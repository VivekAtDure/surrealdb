-- ============================================================
-- SurrealDB ML Setup for Vitasales Lead Scoring
-- ============================================================
-- Run with:
--   surreal import --endpoint http://localhost:8000 \
--     --username root --password root \
--     --namespace vitasales --database vitasales \
--     setup_ml.surql
-- ============================================================
-- NOTE: Model must be loaded first via:
--   curl -X POST http://localhost:8000/ml/import \
--     -H "surreal-ns: vitasales" -H "surreal-db: vitasales" \
--     -u "root:root" \
--     --data-binary @models/lgbm.surml
-- ============================================================

USE NS vitasales;
USE DB vitasales;

-- ============================================================
-- FUNCTION: fn::score_lead
-- Fetches all related data, engineers 29 features, normalises
-- them, calls the lgbm model and returns close_probability.
-- ============================================================
DEFINE FUNCTION fn::score_lead($lead_id: record) {

    -- ── Fetch core records ──────────────────────────────────
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

    -- ── Pipeline stage ordinal (raw 0-6) ────────────────────
    LET $stage_raw =
        IF $lead.state = "NEW_LEAD"                THEN 0
        ELSE IF $lead.state = "MANUAL_FOLLOW_UP"   THEN 1
        ELSE IF $lead.state = "SALES_FOLLOW_UP"    THEN 2
        ELSE IF $lead.state = "SALES_QUALIFIED"    THEN 3
        ELSE IF $lead.state = "QUOTATION"          THEN 4
        ELSE IF $lead.state = "FOLLOW_UP_NEGOTIATION" THEN 5
        ELSE IF $lead.state = "CLOSED"             THEN 6
        ELSE 0 END;

    -- ── Sentiment scalar (-1 to 1) ───────────────────────────
    LET $sentiment_str = IF $conv != NONE THEN $conv.sentiment ELSE "NEUTRAL" END;
    LET $sentiment_scalar =
        IF $sentiment_str = "POSITIVE"     THEN 1.0
        ELSE IF $sentiment_str = "SATISFIED"   THEN 1.0
        ELSE IF $sentiment_str = "INTERESTED"  THEN 0.8
        ELSE IF $sentiment_str = "NEGOTIATING" THEN 0.5
        ELSE IF $sentiment_str = "CURIOUS"     THEN 0.3
        ELSE IF $sentiment_str = "NEUTRAL"     THEN 0.0
        ELSE IF $sentiment_str = "URGENT"      THEN 0.5
        ELSE IF $sentiment_str = "DISSATISFIED" THEN -0.5
        ELSE IF $sentiment_str = "NEGATIVE"    THEN -1.0
        ELSE IF $sentiment_str = "ANGRY"       THEN -1.0
        ELSE 0.0 END;

    -- ── Boolean sentiment flags ──────────────────────────────
    LET $is_positive    = IF $sentiment_scalar >= 0.5 THEN 1.0 ELSE 0.0 END;
    LET $is_urgent      = IF $sentiment_str = "URGENT" THEN 1.0 ELSE 0.0 END;
    LET $is_angry       = IF $sentiment_str = "ANGRY" THEN 1.0 ELSE 0.0 END;
    LET $is_dissatisfied = IF $sentiment_str = "DISSATISFIED" OR $sentiment_str = "NEGATIVE"
                           THEN 1.0 ELSE 0.0 END;

    -- ── Lead completeness ────────────────────────────────────
    LET $is_complete    = IF $lead.completeness = "COMPLETE" THEN 1.0 ELSE 0.0 END;
    LET $is_high_stage  = IF $stage_raw >= 3 THEN 1.0 ELSE 0.0 END;
    LET $quotation_sent = IF $has_quotation THEN 1.0 ELSE 0.0 END;

    -- ── Source channel encoding ──────────────────────────────
    LET $channel_str = IF $lead.source_channel != NONE THEN
        string::split(type::string($lead.source_channel), ":")[1]
    ELSE "" END;
    LET $source_channel_enc =
        IF $channel_str = "email"    THEN 0.0
        ELSE IF $channel_str = "voice" OR $channel_str = "phone" THEN 1.0
        ELSE IF $channel_str = "whatsapp" THEN 2.0
        ELSE -1.0 END;

    -- ── Product features ─────────────────────────────────────
    LET $base_price  = IF $product != NONE THEN $product.base_price  ELSE 100000.0 END;
    LET $tax_rate    = IF $product != NONE THEN $product.tax_rate     ELSE 18.0     END;
    LET $total_price = $base_price * (1.0 + $tax_rate / 100.0);

    -- capacity_tons: use training mean (14.0832) when not a tonnage product
    LET $capacity_tons = 14.0832;

    -- Product category encoding: infer from name
    LET $product_name_str = IF $product != NONE THEN $product.name ELSE "" END;
    LET $product_sku_str  = IF $product != NONE THEN $product.sku  ELSE "" END;
    LET $product_category_enc =
        IF string::contains(string::lowercase($product_name_str), "chiller") THEN 0.0
        ELSE IF string::contains(string::lowercase($product_name_str), "cooler") THEN 1.0
        ELSE IF string::contains(string::lowercase($product_name_str), "combo")  THEN 2.0
        ELSE -1.0 END;

    -- Product type encoding (from training mapping, inferred from attributes)
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

    -- Product name encoding (training product names)
    LET $product_name_enc =
        IF $product_name_str = "Air Cooler Unit"              THEN 0.0
        ELSE IF $product_name_str = "Air-Cooled Chiller Package" THEN 1.0
        ELSE IF $product_name_str = "Centrifugal Chiller"     THEN 2.0
        ELSE IF $product_name_str = "Cooler and Chillers Combo" THEN 3.0
        ELSE IF $product_name_str = "Evaporative Cooler"      THEN 4.0
        ELSE IF $product_name_str = "Glycol Chiller System"   THEN 5.0
        ELSE IF $product_name_str = "Industrial Chiller"      THEN 6.0
        ELSE IF $product_name_str = "Modular Cooling Tower"   THEN 7.0
        ELSE IF $product_name_str = "Portable Cooling Unit"   THEN 8.0
        ELSE IF $product_name_str = "Precision Chiller"       THEN 9.0
        ELSE IF $product_name_str = "Rooftop Chiller"         THEN 10.0
        ELSE IF $product_name_str = "Screw Chiller"           THEN 11.0
        ELSE -1.0 END;

    -- Product SKU encoding (training SKUs)
    LET $product_sku_enc =
        IF $product_sku_str = "CHIL-001" THEN 0.0
        ELSE IF $product_sku_str = "CHIL-002" THEN 1.0
        ELSE IF $product_sku_str = "CHIL-003" THEN 2.0
        ELSE IF $product_sku_str = "CHIL-004" THEN 3.0
        ELSE IF $product_sku_str = "CHIL-005" THEN 4.0
        ELSE IF $product_sku_str = "CHIL-006" THEN 5.0
        ELSE IF $product_sku_str = "COMBO-001" THEN 6.0
        ELSE IF $product_sku_str = "COMBO-002" THEN 7.0
        ELSE IF $product_sku_str = "COOL-001"  THEN 8.0
        ELSE IF $product_sku_str = "COOL-002"  THEN 9.0
        ELSE IF $product_sku_str = "COOL-003"  THEN 10.0
        ELSE IF $product_sku_str = "COOL-004"  THEN 11.0
        ELSE -1.0 END;

    -- ── Organisation industry encoding ───────────────────────
    LET $industry_str = IF $org != NONE THEN $org.industry ELSE "" END;
    LET $org_industry_enc =
        IF $industry_str = "Automotive"               THEN 0.0
        ELSE IF $industry_str = "Breweries & Beverages" THEN 1.0
        ELSE IF $industry_str = "Chemicals"           THEN 2.0
        ELSE IF $industry_str = "Cold Chain Logistics" THEN 3.0
        ELSE IF $industry_str = "Dairy Processing"    THEN 4.0
        ELSE IF $industry_str = "Data Centers"        THEN 5.0
        ELSE IF $industry_str = "Defence & Aerospace" THEN 6.0
        ELSE IF $industry_str = "Food Processing"     THEN 7.0
        ELSE IF $industry_str = "Glass Manufacturing" THEN 8.0
        ELSE IF $industry_str = "Hospitality"         THEN 9.0
        ELSE IF $industry_str = "Oil & Gas"           THEN 10.0
        ELSE IF $industry_str = "Paper & Pulp"        THEN 11.0
        ELSE IF $industry_str = "Pharmaceuticals"     THEN 12.0
        ELSE IF $industry_str = "Plastics"            THEN 13.0
        ELSE IF $industry_str = "Power Generation"    THEN 14.0
        ELSE IF $industry_str = "Real Estate"         THEN 15.0
        ELSE IF $industry_str = "Rubber & Tyres"      THEN 16.0
        ELSE IF $industry_str = "Semiconductor Fabrication" THEN 17.0
        ELSE IF $industry_str = "Steel Manufacturing" THEN 18.0
        ELSE IF $industry_str = "Textiles"            THEN 19.0
        ELSE -1.0 END;

    -- ── Temporal features ────────────────────────────────────
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

    -- ── Text length features ─────────────────────────────────
    LET $message_length_raw = IF $msg != NONE AND $msg.content != NONE
        THEN math::min([string::len($msg.content), 200])
        ELSE 67.0 END;  -- training mean as default

    LET $summary_length_raw = IF $conv != NONE AND $conv.summary != NONE
            AND string::len($conv.summary) > 0
        THEN math::min([string::len($conv.summary), 400])
        ELSE 178.0 END; -- training mean as default

    -- ── Log transforms ───────────────────────────────────────
    LET $E = 2.718281828459045;
    LET $log_base_price = math::log(math::max([$base_price, 1.0]), $E);
    LET $log_capacity   = math::log(math::max([$capacity_tons, 1.0]), $E);

    -- ── Cross features (raw, before normalisation) ───────────
    LET $stage_x_sentiment_raw = $stage_raw * $sentiment_scalar;
    LET $is_enterprise = IF $total_price >= 500000.0 THEN 1.0 ELSE 0.0 END;

    -- ── Apply normalisations ──────────────────────────────────
    -- StandardScaler: (x - mean) / std
    LET $n_capacity_tons       = ($capacity_tons           - 14.0832)    / 14.707683;
    LET $n_log_base_price      = ($log_base_price          - 11.591958)  / 1.271296;
    LET $n_total_price         = ($total_price             - 242903.926) / 260074.554725;
    LET $n_log_capacity        = ($log_capacity            - 2.240947)   / 0.998809;
    LET $n_days_since_last_msg = ($days_since_last_msg_raw - 22.3486)    / 9.068094;
    LET $n_days_in_pipeline    = ($days_in_pipeline_raw    - 10.5838)    / 8.304455;
    LET $n_message_length      = ($message_length_raw      - 67.8074)    / 9.516324;
    LET $n_summary_length      = ($summary_length_raw      - 178.5432)   / 23.819328;

    -- MinMaxScaler: (x - min) / (max - min)
    LET $n_stage_ordinal          = $stage_raw / 6.0;
    LET $n_stage_x_sentiment      = ($stage_x_sentiment_raw + 5.0) / 11.0;
    LET $n_pipeline_stage_enc     = $stage_raw / 6.0;
    LET $n_source_channel_enc     = $source_channel_enc / 2.0;
    LET $n_product_category_enc   = $product_category_enc / 2.0;
    LET $n_product_type_enc       = $product_type_enc / 10.0;
    LET $n_product_name_enc       = $product_name_enc / 11.0;
    LET $n_product_sku_enc        = $product_sku_enc / 11.0;
    LET $n_org_industry_enc       = $org_industry_enc / 19.0;

    -- Binary features (already 0/1, no scaling needed)
    LET $n_has_urgency             = 0.0;  -- no urgency keyword detection in DB
    LET $n_has_price               = 0.0;  -- no price mention detection in DB
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

    -- ── Call model with all 29 normalised features ────────────
    LET $score = ml::close_prob<1.0.0>([
        $n_capacity_tons,            -- [ 0] capacity_tons
        $n_stage_ordinal,            -- [ 1] fe_stage_ordinal
        $n_has_urgency,              -- [ 2] fe_has_urgency_keyword
        $n_has_price,                -- [ 3] fe_has_price_mention
        $n_log_base_price,           -- [ 4] fe_log_base_price
        $n_total_price,              -- [ 5] fe_total_price_with_tax
        $n_log_capacity,             -- [ 6] fe_log_capacity
        $n_days_since_last_msg,      -- [ 7] fe_days_since_last_message
        $n_days_in_pipeline,         -- [ 8] fe_days_in_pipeline
        $n_message_length,           -- [ 9] fe_message_length
        $n_summary_length,           -- [10] fe_summary_length
        $n_stage_x_sentiment,        -- [11] fe_stage_x_sentiment
        $n_quotation_x_satisfied,    -- [12] fe_quotation_x_satisfied
        $n_quotation_x_urgent,       -- [13] fe_quotation_x_urgent
        $n_complete_x_quotation,     -- [14] fe_complete_x_quotation
        $n_angry_x_high_stage,       -- [15] fe_angry_x_high_stage
        $n_urgent_x_high_stage,      -- [16] fe_urgent_x_high_stage
        $n_enterprise_deal,          -- [17] fe_enterprise_deal
        $n_dissatisfied_x_late,      -- [18] fe_dissatisfied_x_late
        $n_interested_x_complete,    -- [19] fe_interested_x_complete
        $n_pipeline_stage_enc,       -- [20] pipeline_stage_enc
        $n_source_channel_enc,       -- [21] source_channel_type_enc
        $n_product_category_enc,     -- [22] product_category_enc
        $n_product_type_enc,         -- [23] product_type_enc
        $n_product_name_enc,         -- [24] product_name_enc
        $n_product_sku_enc,          -- [25] product_sku_enc
        $n_org_industry_enc,         -- [26] organisation_industry_enc
        $n_lead_completeness_enc,    -- [27] lead_completeness_enc
        $n_quotation_sent_enc        -- [28] quotation_sent_enc
    ]);

    -- Return as a percentage (e.g. 62.35)
    RETURN math::round($score[0] * 10000) / 100;
};

-- ============================================================
-- EVENT: Score lead on CREATE or UPDATE
-- ============================================================
-- Fire on CREATE always.
-- Fire on UPDATE only when a field that affects the score actually changed
-- (excludes ai_confidence itself to prevent infinite loop).
DEFINE EVENT score_on_lead_change ON TABLE lead
    WHEN $event = "CREATE"
      OR ($event = "UPDATE" AND (
            $before.state        != $value.state        OR
            $before.completeness != $value.completeness OR
            $before.source_channel != $value.source_channel OR
            $before.organisation != $value.organisation
         )) THEN {
        LET $score = fn::score_lead($value.id);
        UPDATE $value.id SET
            ai_confidence = math::round($score * 10000) / 10000;
    };

-- ============================================================
-- EVENT: Re-score lead when conversation changes
-- (sentiment, summary, last_message_at all affect the score)
-- ============================================================
DEFINE EVENT score_on_conv_change ON TABLE conversation
    WHEN $event = "CREATE"
      OR ($event = "UPDATE" AND (
            $before.sentiment      != $value.sentiment      OR
            $before.summary        != $value.summary        OR
            $before.last_message_at != $value.last_message_at
         )) THEN {
        LET $lead_id = $value.lead;
        LET $score = fn::score_lead($lead_id);
        UPDATE $lead_id SET
            ai_confidence = math::round($score * 10000) / 10000;
    };

-- ============================================================
-- FUNCTION: fn::infer_sentiment
-- Calls external LLM API to get sentiment labels
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
-- EVENT: Infer Sentiment on new messages
-- ============================================================
DEFINE EVENT infer_sentiment_on_message ON TABLE message
    WHEN $event = "CREATE" AND $value.content != NONE THEN {
        
        -- 1. Get the conversation summary as context
        LET $conv = (SELECT summary FROM ONLY $value.conversation);
        LET $context = IF $conv.summary != NONE THEN $conv.summary ELSE "" END;
        
        -- 2. Call the LLM API using the new message and conversation context
        LET $api_response = fn::infer_sentiment($context, $value.content);
        
        -- 3. Extract the labels array from the response and join them
        -- Example: ["Urgent", "Angry"] -> "URGENT,ANGRY"
        LET $labels_array = $api_response.labels;
        LET $sentiment_str = string::uppercase(string::join(',', $labels_array));
        
        -- 4. Update the conversation table with the new sentiment.
        -- (This will naturally trigger `score_on_conv_change` to re-score the lead!)
        UPDATE $value.conversation SET sentiment = $sentiment_str;
    };
