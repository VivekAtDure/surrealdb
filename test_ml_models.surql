-- ================================================================
-- VITAFI ML MODELS TEST
-- Covers: consumer_score | interaction_score | product_quotation_score
-- Tracks score progression: NEW_LEAD → MANUAL_FOLLOW_UP → SALES_FOLLOW_UP
--                           → SALES_QUALIFIED → QUOTATION
--                           → FOLLOW_UP_NEGOTIATION → CLOSED
-- Run each STEP block separately in Surrealist and observe score rise.
-- Server: http://localhost:8000  |  NS: vitasales  |  DB: vitasales
-- ================================================================

-- ================================================================
-- AUTO CLEANUP — Runs first every time to delete previous test data
-- ================================================================
DELETE FROM message WHERE conversation IN [
    conversation:ml_conv_whatsapp,
    conversation:ml_conv_email,
    conversation:ml_conv_voice,
    conversation:ml_conv_web
];
DELETE conversation:ml_conv_whatsapp;
DELETE conversation:ml_conv_email;
DELETE conversation:ml_conv_voice;
DELETE conversation:ml_conv_web;
DELETE FROM interested_in    WHERE in = lead:ml_test_lead;
DELETE FROM generated_quotation WHERE in = lead:ml_test_lead;
DELETE FROM generated        WHERE in = lead:ml_test_lead;
DELETE quotation:ml_quot_01;
DELETE lead:ml_test_lead;
DELETE organisation:ml_test_org;


-- ================================================================
-- STEP 0: Setup — Create Organisation + Lead (state: NEW_LEAD)
--         No conversations, no product, no history on this lead.
--         Expected scores: very low across all 3 models.
-- ================================================================

CREATE organisation:ml_test_org SET
    name                     = 'PharmaCore Industries Ltd',
    industry                 = 'Pharmaceuticals',
    country                  = 'India',
    city                     = 'Hyderabad',
    historical_deals_won     = 3,
    historical_avg_sentiment = 0.62;

CREATE lead:ml_test_lead SET
    name           = 'Arjun Mehta',
    email          = 'arjun.mehta@pharmacore.in',
    phone          = '+91-9988776655',
    designation    = 'Head of Procurement',
    state          = 'NEW_LEAD',
    completeness   = 'INCOMPLETE',
    classification = 'NON-SALES',
    source_channel = channel:whatsapp,
    organisation   = organisation:ml_test_org,
    created_at     = time::now(),
    updated_at     = time::now();

SELECT id, name, state, completeness FROM lead:ml_test_lead;
SELECT id, name, historical_deals_won, historical_avg_sentiment FROM organisation:ml_test_org;

-- ── ML SCORES at NEW_LEAD ─────────────────────────────────────────
-- Stage=0, neutral sentiment, no conversations, no product yet.

-- consumer_score (12 features)
RETURN {
    step:  "STEP 0 — NEW_LEAD",
    model: "consumer_score",
    score: ml::consumer_score<1.0.0>([
        3.0,    -- [0]  primary_sentiment       neutral=3
        0.0,    -- [1]  sentiment_score         no messages yet
        0.0,    -- [2]  sentiment_combo_score   stage(0) × score(0)
        7.0,    -- [3]  intent                  new=7
        2.0,    -- [4]  message_quality         medium=2
        0.0,    -- [5]  summary_length          no summary
        0.0,    -- [6]  has_action_milestone    stage < QUOTATION
        0.0,    -- [7]  stage_velocity          0 / 1 day
        3.0,    -- [8]  historical_deals_won    org record
        1.0,    -- [9]  is_repeat_customer      deals_won > 0
        0.62,   -- [10] historical_avg_sentiment org record
        0.48    -- [11] industry_close_rate     pharmaceuticals
    ])
};

-- interaction_score (15 features)
RETURN {
    step:  "STEP 0 — NEW_LEAD",
    model: "interaction_score",
    score: ml::interaction_score<1.0.0>([
        0.0,    -- [0]  whatsapp_count
        0.0,    -- [1]  phone_count
        0.0,    -- [2]  email_count
        0.0,    -- [3]  total_interactions
        2.0,    -- [4]  dominant_channel        whatsapp=2 (source)
        2.0,    -- [5]  first_channel           whatsapp=2
        2.0,    -- [6]  last_channel            whatsapp=2
        0.0,    -- [7]  is_multi_channel        no
        0.0,    -- [8]  channel_switch_count
        0.0,    -- [9]  conversation_time_hours
        4.0,    -- [10] conv_time_bucket        medium_medium=4 (default)
        1.0,    -- [11] recency_bucket          cold=1
        0.0,    -- [12] engagement_depth
        0.0,    -- [13] channel_x_stage         whatsapp(2) × stage(0)
        3.0     -- [14] historical_deals_won
    ])
};

-- product_quotation_score (18 features)
RETURN {
    step:  "STEP 0 — NEW_LEAD",
    model: "product_quotation_score",
    score: ml::product_quotation_score<1.0.0>([
        0.0,        -- [0]  product_category    chiller=0 (default)
        0.0,        -- [1]  product_type
        1.0,        -- [2]  product_complexity
        0.0,        -- [3]  product_base_price  no product linked yet
        18.0,       -- [4]  product_tax_rate
        2.0,        -- [5]  price_tier          low=2
        0.0,        -- [6]  capacity_tons
        0.0,        -- [7]  capacity_bin
        0.0,        -- [8]  product_x_capacity
        0.0,        -- [9]  total_price_with_tax
        0.0,        -- [10] capacity_price_ratio
        0.0,        -- [11] quotation_sent
        0.0,        -- [12] is_enterprise_deal
        0.48,       -- [13] industry_close_rate
        0.0,        -- [14] pipeline_stage      NEW_LEAD=0
        1.0,        -- [15] is_repeat_customer
        1.0,        -- [16] days_in_pipeline
        0.0         -- [17] pipeline_velocity   0/1
    ])
};


-- ================================================================
-- STEP 1: Link Product + WhatsApp Conversation + Customer Message
--         CHANNEL: WhatsApp (first touch)
--         sentiment: NEUTRAL → INTERESTED
--         days_in_pipeline: 1
--         Expected: consumer↑ (interested sentiment)
--                   interaction↑ (1 channel active)
--                   product_quotation↑ (product now linked)
-- ================================================================

RELATE lead:ml_test_lead->interested_in->product:p010; -- Chiller ₹75,000 5T

CREATE conversation:ml_conv_whatsapp SET
    lead            = lead:ml_test_lead,
    channel         = channel:whatsapp,
    sentiment       = 'INTERESTED',
    summary         = 'Customer inquired about industrial chillers for pharmaceutical plant. Strong initial interest. Requested specs and pricing.',
    started_at      = time::now(),
    last_message_at = time::now(),
    created_at      = time::now();

CREATE message SET
    conversation = conversation:ml_conv_whatsapp,
    content      = 'Hi, I am looking for industrial chillers for our pharma plant. We need cooling for our production line. Can you share specs and pricing?',
    sender       = 'CUSTOMER',
    message_type = 'TEXT',
    created_at   = time::now();

SELECT id, state, ai_confidence FROM lead:ml_test_lead;
SELECT id, channel, sentiment FROM conversation:ml_conv_whatsapp;

-- ── ML SCORES after Step 1 ────────────────────────────────────────

RETURN {
    step:  "STEP 1 — WhatsApp (INTERESTED) + Product linked",
    model: "consumer_score",
    score: ml::consumer_score<1.0.0>([
        5.0,    -- [0]  primary_sentiment       interested=5
        0.55,   -- [1]  sentiment_score
        0.0,    -- [2]  sentiment_combo_score   stage(0) × 0.55 = 0
        5.0,    -- [3]  intent                  interested=5
        1.0,    -- [4]  message_quality         long=1
        175.0,  -- [5]  summary_length
        0.0,    -- [6]  has_action_milestone    stage < QUOTATION
        0.0,    -- [7]  stage_velocity          0 / 1
        3.0,    -- [8]  historical_deals_won
        1.0,    -- [9]  is_repeat_customer
        0.62,   -- [10] historical_avg_sentiment
        0.48    -- [11] industry_close_rate
    ])
};

RETURN {
    step:  "STEP 1 — WhatsApp (INTERESTED) + Product linked",
    model: "interaction_score",
    score: ml::interaction_score<1.0.0>([
        1.0,    -- [0]  whatsapp_count          1 convo
        0.0,    -- [1]  phone_count
        0.0,    -- [2]  email_count
        1.0,    -- [3]  total_interactions
        2.0,    -- [4]  dominant_channel        whatsapp=2
        2.0,    -- [5]  first_channel           whatsapp=2
        2.0,    -- [6]  last_channel            whatsapp=2
        0.0,    -- [7]  is_multi_channel        no
        0.0,    -- [8]  channel_switch_count
        0.5,    -- [9]  conversation_time_hours ~30 min
        0.0,    -- [10] conv_time_bucket        high_fast=0
        2.0,    -- [11] recency_bucket          fresh=2
        0.55,   -- [12] engagement_depth        1 × 0.55
        0.0,    -- [13] channel_x_stage         whatsapp(2) × stage(0) = 0
        3.0     -- [14] historical_deals_won
    ])
};

RETURN {
    step:  "STEP 1 — WhatsApp (INTERESTED) + Product linked",
    model: "product_quotation_score",
    score: ml::product_quotation_score<1.0.0>([
        0.0,        -- [0]  product_category    chiller=0
        3.0,        -- [1]  product_type        chiller type ordinal ~3
        2.0,        -- [2]  product_complexity
        75000.0,    -- [3]  product_base_price
        18.0,       -- [4]  product_tax_rate
        2.0,        -- [5]  price_tier          low=2 (under ₹1L)
        5.0,        -- [6]  capacity_tons
        0.0,        -- [7]  capacity_bin        1-5t=0
        15.0,       -- [8]  product_x_capacity  3×5+0
        88500.0,    -- [9]  total_price_with_tax 75000×1.18
        0.0000565,  -- [10] capacity_price_ratio 5/88500
        0.0,        -- [11] quotation_sent      not yet
        0.0,        -- [12] is_enterprise_deal  75k < 400k
        0.48,       -- [13] industry_close_rate
        0.0,        -- [14] pipeline_stage      NEW_LEAD=0
        1.0,        -- [15] is_repeat_customer
        1.0,        -- [16] days_in_pipeline
        0.0         -- [17] pipeline_velocity   0/1
    ])
};


-- ================================================================
-- STEP 2: Move → MANUAL_FOLLOW_UP + Email Conversation + Message
--         CHANNEL: Email (2nd channel — multi-channel begins)
--         sentiment: INTERESTED (email confirms interest)
--         days_in_pipeline: 3
--         Expected: consumer↑ (stage=1, combo score rises)
--                   interaction↑ (is_multi_channel=1, channel_switch=1)
--                   product_quotation↑ (stage=1, velocity=0.33)
-- ================================================================

UPDATE lead:ml_test_lead SET
    state      = 'MANUAL_FOLLOW_UP',
    updated_at = time::now();

CREATE conversation:ml_conv_email SET
    lead            = lead:ml_test_lead,
    channel         = channel:email,
    sentiment       = 'INTERESTED',
    summary         = 'Follow-up email. Customer requested technical specs and pricing. Very responsive and engaged.',
    started_at      = time::now(),
    last_message_at = time::now(),
    created_at      = time::now();

CREATE message SET
    conversation = conversation:ml_conv_email,
    content      = 'Thank you for reaching out! I am very interested in your Chiller product range. Could you please send the technical specifications and pricing? We are evaluating options for our pharmaceutical production facility.',
    sender       = 'CUSTOMER',
    message_type = 'TEXT',
    created_at   = time::now();

SELECT id, state, ai_confidence FROM lead:ml_test_lead;
SELECT id, channel, sentiment FROM conversation:ml_conv_email;

-- ── ML SCORES after Step 2 ────────────────────────────────────────

RETURN {
    step:  "STEP 2 — MANUAL_FOLLOW_UP + Email (multi-channel starts)",
    model: "consumer_score",
    score: ml::consumer_score<1.0.0>([
        5.0,    -- [0]  primary_sentiment       interested=5
        0.60,   -- [1]  sentiment_score
        0.60,   -- [2]  sentiment_combo_score   stage(1) × 0.60
        5.0,    -- [3]  intent                  interested=5
        0.0,    -- [4]  message_quality         detailed=0
        245.0,  -- [5]  summary_length
        0.0,    -- [6]  has_action_milestone
        0.33,   -- [7]  stage_velocity          1/3
        3.0,    -- [8]  historical_deals_won
        1.0,    -- [9]  is_repeat_customer
        0.62,   -- [10] historical_avg_sentiment
        0.48    -- [11] industry_close_rate
    ])
};

RETURN {
    step:  "STEP 2 — MANUAL_FOLLOW_UP + Email (multi-channel starts)",
    model: "interaction_score",
    score: ml::interaction_score<1.0.0>([
        1.0,    -- [0]  whatsapp_count
        0.0,    -- [1]  phone_count
        1.0,    -- [2]  email_count
        2.0,    -- [3]  total_interactions
        2.0,    -- [4]  dominant_channel        whatsapp=2
        2.0,    -- [5]  first_channel           whatsapp=2
        0.0,    -- [6]  last_channel            email=0
        1.0,    -- [7]  is_multi_channel        YES ← key change
        1.0,    -- [8]  channel_switch_count    2-1
        24.0,   -- [9]  conversation_time_hours ~1 day span
        2.0,    -- [10] conv_time_bucket        medium_fast=2
        2.0,    -- [11] recency_bucket          fresh=2
        1.15,   -- [12] engagement_depth        2 × 0.575 avg
        2.0,    -- [13] channel_x_stage         whatsapp(2) × stage(1) = 2
        3.0     -- [14] historical_deals_won
    ])
};

RETURN {
    step:  "STEP 2 — MANUAL_FOLLOW_UP + Email (multi-channel starts)",
    model: "product_quotation_score",
    score: ml::product_quotation_score<1.0.0>([
        0.0,
        3.0,
        2.0,
        75000.0,
        18.0,
        2.0,
        5.0,
        0.0,
        15.0,
        88500.0,
        0.0000565,
        0.0,        -- [11] quotation_sent      not yet
        0.0,
        0.48,
        1.0,        -- [14] pipeline_stage      MANUAL_FOLLOW_UP=1
        1.0,
        3.0,        -- [16] days_in_pipeline
        0.33        -- [17] pipeline_velocity   1/3
    ])
};


-- ================================================================
-- STEP 3: Move → SALES_FOLLOW_UP + Voice Call + Urgent Message
--         CHANNEL: Voice/Phone (3rd channel)
--         sentiment: URGENT (budget approved, timeline pressure)
--         days_in_pipeline: 7
--         Expected: consumer↑↑ (URGENT=6 is max sentiment, stage=2)
--                   interaction↑ (3 channels, phone added)
--                   product_quotation↑ (stage=2, velocity=0.29)
-- ================================================================

UPDATE lead:ml_test_lead SET
    state      = 'SALES_FOLLOW_UP',
    updated_at = time::now();

CREATE conversation:ml_conv_voice SET
    lead            = lead:ml_test_lead,
    channel         = channel:voice,
    sentiment       = 'URGENT',
    summary         = 'Phone call. Customer confirmed URGENT requirement. Chiller needed before Q3 end. Budget officially approved by management. Wants site visit immediately.',
    started_at      = time::now(),
    last_message_at = time::now(),
    created_at      = time::now();

CREATE message SET
    conversation = conversation:ml_conv_voice,
    content      = 'We need the chiller installed urgently before end of this quarter. Budget has been approved by management. Please arrange a site visit and demo at the earliest possible date.',
    sender       = 'CUSTOMER',
    message_type = 'TEXT',
    created_at   = time::now();

SELECT id, state, ai_confidence FROM lead:ml_test_lead;
SELECT id, channel, sentiment FROM conversation:ml_conv_voice;

-- ── ML SCORES after Step 3 ────────────────────────────────────────

RETURN {
    step:  "STEP 3 — SALES_FOLLOW_UP + Voice (URGENT — 3 channels)",
    model: "consumer_score",
    score: ml::consumer_score<1.0.0>([
        6.0,    -- [0]  primary_sentiment       URGENT=6 ← maximum
        0.75,   -- [1]  sentiment_score         strong positive
        1.50,   -- [2]  sentiment_combo_score   stage(2) × 0.75
        4.0,    -- [3]  intent                  hot=4
        1.0,    -- [4]  message_quality         long=1
        220.0,  -- [5]  summary_length
        0.0,    -- [6]  has_action_milestone    stage < QUOTATION
        0.29,   -- [7]  stage_velocity          2/7
        3.0,    -- [8]  historical_deals_won
        1.0,    -- [9]  is_repeat_customer
        0.62,   -- [10] historical_avg_sentiment
        0.48    -- [11] industry_close_rate
    ])
};

RETURN {
    step:  "STEP 3 — SALES_FOLLOW_UP + Voice (URGENT — 3 channels)",
    model: "interaction_score",
    score: ml::interaction_score<1.0.0>([
        1.0,    -- [0]  whatsapp_count
        1.0,    -- [1]  phone_count             voice added
        1.0,    -- [2]  email_count
        3.0,    -- [3]  total_interactions
        2.0,    -- [4]  dominant_channel        whatsapp=2
        2.0,    -- [5]  first_channel           whatsapp=2
        1.0,    -- [6]  last_channel            voice/phone=1
        1.0,    -- [7]  is_multi_channel
        2.0,    -- [8]  channel_switch_count    3-1
        72.0,   -- [9]  conversation_time_hours ~3 days
        1.0,    -- [10] conv_time_bucket        medium_slow=1
        0.0,    -- [11] recency_bucket          active=0
        2.25,   -- [12] engagement_depth        3 × 0.75
        4.0,    -- [13] channel_x_stage         whatsapp(2) × stage(2) = 4
        3.0     -- [14] historical_deals_won
    ])
};

RETURN {
    step:  "STEP 3 — SALES_FOLLOW_UP + Voice (URGENT — 3 channels)",
    model: "product_quotation_score",
    score: ml::product_quotation_score<1.0.0>([
        0.0,
        3.0,
        2.0,
        75000.0,
        18.0,
        2.0,
        5.0,
        0.0,
        15.0,
        88500.0,
        0.0000565,
        0.0,        -- [11] quotation_sent      not yet
        0.0,
        0.48,
        2.0,        -- [14] pipeline_stage      SALES_FOLLOW_UP=2
        1.0,
        7.0,        -- [16] days_in_pipeline
        0.29        -- [17] pipeline_velocity   2/7
    ])
};


-- ================================================================
-- STEP 4: Move → SALES_QUALIFIED + COMPLETE + Web Chat Message
--         CHANNEL: Web (4th channel)
--         completeness: INCOMPLETE → COMPLETE
--         classification: NON-SALES → SALES
--         sentiment: POSITIVE (budget officially confirmed)
--         days_in_pipeline: 12
--         Expected: consumer↑↑ (stage=3, COMPLETE, strong combo)
--                   interaction↑ (all 4 channels active)
--                   product_quotation↑↑ (stage=3, SALES classified)
-- ================================================================

UPDATE lead:ml_test_lead SET
    state          = 'SALES_QUALIFIED',
    completeness   = 'COMPLETE',
    classification = 'SALES',
    updated_at     = time::now();

CREATE conversation:ml_conv_web SET
    lead            = lead:ml_test_lead,
    channel         = channel:web,
    sentiment       = 'POSITIVE',
    summary         = 'Web chat. Budget officially approved by finance team. Ready for formal quotation. Very satisfied with responsiveness.',
    started_at      = time::now(),
    last_message_at = time::now(),
    created_at      = time::now();

CREATE message SET
    conversation = conversation:ml_conv_web,
    content      = 'The budget has been officially approved by our finance team. We are definitely moving forward with this purchase. Please send us a formal quotation at the earliest. Very satisfied with your responsiveness.',
    sender       = 'CUSTOMER',
    message_type = 'TEXT',
    created_at   = time::now();

SELECT id, state, completeness, classification, ai_confidence FROM lead:ml_test_lead;
SELECT id, channel, sentiment FROM conversation:ml_conv_web;

-- ── ML SCORES after Step 4 ────────────────────────────────────────

RETURN {
    step:  "STEP 4 — SALES_QUALIFIED + COMPLETE (4 channels, budget confirmed)",
    model: "consumer_score",
    score: ml::consumer_score<1.0.0>([
        5.0,    -- [0]  primary_sentiment       interested=5 (positive)
        0.72,   -- [1]  sentiment_score
        2.16,   -- [2]  sentiment_combo_score   stage(3) × 0.72
        3.0,    -- [3]  intent                  evaluating=3
        0.0,    -- [4]  message_quality         detailed=0
        210.0,  -- [5]  summary_length
        0.0,    -- [6]  has_action_milestone    stage < QUOTATION
        0.25,   -- [7]  stage_velocity          3/12
        3.0,    -- [8]  historical_deals_won
        1.0,    -- [9]  is_repeat_customer
        0.62,   -- [10] historical_avg_sentiment
        0.48    -- [11] industry_close_rate
    ])
};

RETURN {
    step:  "STEP 4 — SALES_QUALIFIED + COMPLETE (4 channels, budget confirmed)",
    model: "interaction_score",
    score: ml::interaction_score<1.0.0>([
        1.0,    -- [0]  whatsapp_count
        1.0,    -- [1]  phone_count
        2.0,    -- [2]  email_count             web counted as email channel
        4.0,    -- [3]  total_interactions      all 4 channels
        0.0,    -- [4]  dominant_channel        email=0 (most msgs)
        2.0,    -- [5]  first_channel           whatsapp=2
        0.0,    -- [6]  last_channel            web/email=0
        1.0,    -- [7]  is_multi_channel
        2.0,    -- [8]  channel_switch_count
        168.0,  -- [9]  conversation_time_hours ~7 days
        3.0,    -- [10] conv_time_bucket        medium_medium=3
        0.0,    -- [11] recency_bucket          active=0
        2.88,   -- [12] engagement_depth        4 × 0.72
        6.0,    -- [13] channel_x_stage         whatsapp(2) × stage(3) = 6
        3.0     -- [14] historical_deals_won
    ])
};

RETURN {
    step:  "STEP 4 — SALES_QUALIFIED + COMPLETE (4 channels, budget confirmed)",
    model: "product_quotation_score",
    score: ml::product_quotation_score<1.0.0>([
        0.0,
        3.0,
        2.0,
        75000.0,
        18.0,
        2.0,
        5.0,
        0.0,
        15.0,
        88500.0,
        0.0000565,
        0.0,        -- [11] quotation_sent      not yet
        0.0,
        0.48,
        3.0,        -- [14] pipeline_stage      SALES_QUALIFIED=3
        1.0,
        12.0,       -- [16] days_in_pipeline
        0.25        -- [17] pipeline_velocity   3/12
    ])
};


-- ================================================================
-- STEP 5: Create + Send Quotation → Move to QUOTATION stage
--         quotation_sent = 1  |  has_action_milestone = 1
--         days_in_pipeline: 15
--         Expected: consumer↑↑ (has_action_milestone flips to 1)
--                   interaction↑ (channel_x_stage higher)
--                   product_quotation↑↑↑ (quotation_sent=1 ← biggest signal)
-- ================================================================

CREATE quotation:ml_quot_01 SET
    lead         = lead:ml_test_lead,
    quote_id     = 'QT-ML-2026-001',
    quotation_no = 'VF-ML-2026-001',
    status       = 'GENERATED',
    currency     = 'INR',
    subtotal     = 75000.00,
    products     = [{
        product    : product:p010,
        name       : 'Industrial Chiller',
        sku        : 'CHILL-001',
        quantity   : 1,
        unit_price : 75000.00,
        total      : 88500.00
    }],
    tax_amount   = 13500.00,
    total_amount = 88500.00,
    notes        = 'Industrial Chiller for pharmaceutical production line. Includes 1-year AMC.',
    model        = 'Industrial Chiller IC-5T',
    isfeedback   = false,
    generated_at = time::now(),
    created_at   = time::now();

RELATE lead:ml_test_lead->generated_quotation->quotation:ml_quot_01;
RELATE lead:ml_test_lead->generated->quotation:ml_quot_01;

UPDATE quotation:ml_quot_01 SET
    status   = 'SENT',
    sent_via = 'EMAIL',
    sent_at  = time::now();

UPDATE lead:ml_test_lead SET
    state      = 'QUOTATION',
    updated_at = time::now();

SELECT id, state, ai_confidence FROM lead:ml_test_lead;
SELECT id, quote_id, status, subtotal, sent_at FROM quotation:ml_quot_01;

-- ── ML SCORES after Step 5 ────────────────────────────────────────

RETURN {
    step:  "STEP 5 — QUOTATION sent (quotation_sent=1, has_action_milestone=1)",
    model: "consumer_score",
    score: ml::consumer_score<1.0.0>([
        5.0,    -- [0]  primary_sentiment
        0.72,   -- [1]  sentiment_score
        2.88,   -- [2]  sentiment_combo_score   stage(4) × 0.72
        3.0,    -- [3]  intent
        0.0,    -- [4]  message_quality
        210.0,  -- [5]  summary_length
        1.0,    -- [6]  has_action_milestone    QUOTATION reached ← flip
        0.27,   -- [7]  stage_velocity          4/15
        3.0,    -- [8]  historical_deals_won
        1.0,    -- [9]  is_repeat_customer
        0.62,   -- [10] historical_avg_sentiment
        0.48    -- [11] industry_close_rate
    ])
};

RETURN {
    step:  "STEP 5 — QUOTATION sent (quotation_sent=1, has_action_milestone=1)",
    model: "interaction_score",
    score: ml::interaction_score<1.0.0>([
        1.0,
        1.0,
        2.0,
        4.0,
        0.0,
        2.0,
        0.0,
        1.0,
        2.0,
        168.0,
        3.0,
        0.0,
        2.88,
        8.0,    -- [13] channel_x_stage         whatsapp(2) × stage(4) = 8
        3.0
    ])
};

RETURN {
    step:  "STEP 5 — QUOTATION sent (quotation_sent=1, has_action_milestone=1)",
    model: "product_quotation_score",
    score: ml::product_quotation_score<1.0.0>([
        0.0,
        3.0,
        2.0,
        75000.0,
        18.0,
        2.0,
        5.0,
        0.0,
        15.0,
        88500.0,
        0.0000565,
        1.0,        -- [11] quotation_sent      = 1 ← BIGGEST SIGNAL
        0.0,
        0.48,
        4.0,        -- [14] pipeline_stage      QUOTATION=4
        1.0,
        15.0,       -- [16] days_in_pipeline
        0.27        -- [17] pipeline_velocity   4/15
    ])
};


-- ================================================================
-- STEP 6: Move → FOLLOW_UP_NEGOTIATION + Negotiation WhatsApp Message
--         CHANNEL: WhatsApp (reusing conv_whatsapp — 2nd message)
--         sentiment: NEGOTIATING (strong buying signal — ready to sign)
--         days_in_pipeline: 20
--         Expected: consumer↑ (NEGOTIATING = near-close intent, stage=5)
--                   interaction↑ (whatsapp_count=2, engagement_depth rises)
--                   product_quotation↑ (stage=5, velocity=0.25)
-- ================================================================

UPDATE lead:ml_test_lead SET
    state      = 'FOLLOW_UP_NEGOTIATION',
    updated_at = time::now();

CREATE message SET
    conversation = conversation:ml_conv_whatsapp,
    content      = 'We reviewed the quotation. The price is slightly above our budget. Could you offer a 10% discount? We are ready to sign the purchase order immediately if you can adjust the price. Looking to close this deal this week.',
    sender       = 'CUSTOMER',
    message_type = 'TEXT',
    created_at   = time::now();

UPDATE conversation:ml_conv_whatsapp SET
    sentiment       = 'NEGOTIATING',
    last_message_at = time::now(),
    summary         = 'Customer negotiating 10% discount. Ready to sign PO immediately upon price adjustment. Closing expected this week.';

SELECT id, state, ai_confidence FROM lead:ml_test_lead;
SELECT id, channel, sentiment FROM conversation:ml_conv_whatsapp;

-- ── ML SCORES after Step 6 ────────────────────────────────────────

RETURN {
    step:  "STEP 6 — FOLLOW_UP_NEGOTIATION (NEGOTIATING — ready to sign PO)",
    model: "consumer_score",
    score: ml::consumer_score<1.0.0>([
        4.0,    -- [0]  primary_sentiment       curious/negotiating≈4
        0.65,   -- [1]  sentiment_score
        3.25,   -- [2]  sentiment_combo_score   stage(5) × 0.65
        3.0,    -- [3]  intent                  evaluating=3 (near close)
        1.0,    -- [4]  message_quality         long=1
        175.0,  -- [5]  summary_length
        1.0,    -- [6]  has_action_milestone    still QUOTATION stage+
        0.25,   -- [7]  stage_velocity          5/20
        3.0,    -- [8]  historical_deals_won
        1.0,    -- [9]  is_repeat_customer
        0.62,   -- [10] historical_avg_sentiment
        0.48    -- [11] industry_close_rate
    ])
};

RETURN {
    step:  "STEP 6 — FOLLOW_UP_NEGOTIATION (NEGOTIATING — ready to sign PO)",
    model: "interaction_score",
    score: ml::interaction_score<1.0.0>([
        2.0,    -- [0]  whatsapp_count          2nd message
        1.0,
        2.0,
        5.0,    -- [3]  total_interactions
        2.0,    -- [4]  dominant_channel        whatsapp=2
        2.0,    -- [5]  first_channel
        2.0,    -- [6]  last_channel            whatsapp=2
        1.0,
        2.0,
        240.0,  -- [9]  conversation_time_hours ~10 days
        3.0,
        0.0,
        3.25,   -- [12] engagement_depth        5 × 0.65
        10.0,   -- [13] channel_x_stage         whatsapp(2) × stage(5) = 10
        3.0
    ])
};

RETURN {
    step:  "STEP 6 — FOLLOW_UP_NEGOTIATION (NEGOTIATING — ready to sign PO)",
    model: "product_quotation_score",
    score: ml::product_quotation_score<1.0.0>([
        0.0,
        3.0,
        2.0,
        75000.0,
        18.0,
        2.0,
        5.0,
        0.0,
        15.0,
        88500.0,
        0.0000565,
        1.0,        -- [11] quotation_sent      still 1
        0.0,
        0.48,
        5.0,        -- [14] pipeline_stage      FOLLOW_UP_NEGOTIATION=5
        1.0,
        20.0,       -- [16] days_in_pipeline
        0.25        -- [17] pipeline_velocity   5/20
    ])
};


-- ================================================================
-- STEP 7: Accept Quotation + Final Message → CLOSED
--         sentiment: SATISFIED/POSITIVE (highest positive signal)
--         days_in_pipeline: 25
--         Expected: ALL 3 models → peak score
--                   consumer: stage=6, combo_score=5.10 (max)
--                   interaction: 6 total messages, max engagement_depth
--                   product_quotation: stage=6, quotation accepted
-- ================================================================

CREATE message SET
    conversation = conversation:ml_conv_whatsapp,
    content      = 'We accept the quotation and are very satisfied with the entire process and your team professionalism. Please proceed with the order. Looking forward to a long-term partnership.',
    sender       = 'CUSTOMER',
    message_type = 'TEXT',
    created_at   = time::now();

UPDATE quotation:ml_quot_01 SET
    status         = 'ACCEPTED',
    accepted_at    = time::now(),
    feedbackrating = '5',
    isfeedback     = true;

UPDATE lead:ml_test_lead SET
    state      = 'CLOSED',
    updated_at = time::now();

SELECT id, state, completeness, classification, ai_confidence FROM lead:ml_test_lead;
SELECT id, status, feedbackrating, accepted_at FROM quotation:ml_quot_01;

-- ── ML SCORES at CLOSED — peak scores ────────────────────────────

RETURN {
    step:  "STEP 7 — CLOSED (deal won, quotation accepted, SATISFIED)",
    model: "consumer_score",
    score: ml::consumer_score<1.0.0>([
        5.0,    -- [0]  primary_sentiment       satisfied≈interested=5
        0.85,   -- [1]  sentiment_score         highest positive
        5.10,   -- [2]  sentiment_combo_score   stage(6) × 0.85 ← max
        3.0,    -- [3]  intent
        0.0,    -- [4]  message_quality         detailed=0
        210.0,  -- [5]  summary_length
        1.0,    -- [6]  has_action_milestone
        0.24,   -- [7]  stage_velocity          6/25
        3.0,    -- [8]  historical_deals_won
        1.0,    -- [9]  is_repeat_customer
        0.62,   -- [10] historical_avg_sentiment
        0.48    -- [11] industry_close_rate
    ])
};

RETURN {
    step:  "STEP 7 — CLOSED (deal won, quotation accepted, SATISFIED)",
    model: "interaction_score",
    score: ml::interaction_score<1.0.0>([
        3.0,    -- [0]  whatsapp_count          3 messages total
        1.0,
        2.0,
        6.0,    -- [3]  total_interactions      max
        2.0,    -- [4]  dominant_channel        whatsapp=2
        2.0,    -- [5]  first_channel
        2.0,    -- [6]  last_channel            whatsapp=2
        1.0,
        2.0,
        360.0,  -- [9]  conversation_time_hours ~15 days full span
        3.0,
        0.0,
        5.10,   -- [12] engagement_depth        6 × 0.85 ← max
        12.0,   -- [13] channel_x_stage         whatsapp(2) × stage(6) = 12
        3.0
    ])
};

RETURN {
    step:  "STEP 7 — CLOSED (deal won, quotation accepted, SATISFIED)",
    model: "product_quotation_score",
    score: ml::product_quotation_score<1.0.0>([
        0.0,
        3.0,
        2.0,
        75000.0,
        18.0,
        2.0,
        5.0,
        0.0,
        15.0,
        88500.0,
        0.0000565,
        1.0,        -- [11] quotation_sent      = 1
        0.0,
        0.48,
        6.0,        -- [14] pipeline_stage      CLOSED=6 ← max
        1.0,
        25.0,       -- [16] days_in_pipeline
        0.24        -- [17] pipeline_velocity   6/25
    ])
};


-- ================================================================
-- STEP 8: Final Summary — Full lead + all conversations + quotation
-- ================================================================

-- 1. Lead final state
SELECT
    id,
    name,
    state,
    completeness,
    classification,
    ai_confidence,
    source_channel,
    organisation.name     AS org_name,
    organisation.industry AS industry
FROM lead:ml_test_lead
FETCH organisation;

-- 2. All conversations with sentiment
SELECT
    id,
    channel.name AS channel,
    sentiment,
    summary,
    last_message_at
FROM conversation
WHERE lead = lead:ml_test_lead
ORDER BY last_message_at ASC
FETCH channel;

-- 3. All messages (full multi-channel thread)
SELECT
    id,
    conversation.channel.name AS channel,
    sender,
    content,
    created_at
FROM message
WHERE conversation IN (
    SELECT VALUE id FROM conversation WHERE lead = lead:ml_test_lead
)
ORDER BY created_at ASC
FETCH conversation;

-- 4. Quotation details
SELECT
    id,
    quote_id,
    quotation_no,
    status,
    currency,
    subtotal,
    products,
    sent_via,
    sent_at,
    accepted_at,
    feedbackrating
FROM quotation
WHERE lead = lead:ml_test_lead;

-- 5. Product interest
SELECT ->interested_in->product.* AS interested_products
FROM lead:ml_test_lead;

-- ================================================================
-- SCORE PROGRESSION REFERENCE (run each RETURN block separately)
-- ================================================================
-- Stage             | consumer  | interaction | product_quotation
-- ------------------|-----------|-------------|------------------
-- NEW_LEAD          | very low  | very low    | very low
-- WhatsApp INTEREST | low+      | low+        | low+ (product linked)
-- MANUAL_FOLLOW_UP  | rising    | rising      | rising
-- SALES_FOLLOW_UP   | high+     | high+       | rising (3 channels)
-- SALES_QUALIFIED   | strong    | strong      | strong
-- QUOTATION SENT    | strong+   | strong+     | PEAK jump (quotation_sent=1)
-- FOLLOW_UP_NEGOT.  | high      | high        | high
-- CLOSED            | PEAK      | PEAK        | PEAK
-- ================================================================
