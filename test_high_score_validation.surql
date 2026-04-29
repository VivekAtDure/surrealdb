-- ================================================================
-- VITAFI HIGH SCORE VALIDATION TEST
-- ================================================================
-- Purpose  : Verify that when consumer_score, interaction_score,
--            and product_quotation_score are all HIGH (> 70%),
--            lead_qualification is also HIGH (> 80%).
--
-- Coverage :
--   ✓ 7 Stages     : NEW_LEAD → MANUAL_FOLLOW_UP → SALES_FOLLOW_UP
--                    → SALES_QUALIFIED → QUOTATION
--                    → FOLLOW_UP_NEGOTIATION → CLOSED
--   ✓ 7 Sentiments : NEUTRAL, INTERESTED, CURIOUS, POSITIVE,
--                    URGENT, NEGOTIATING, SATISFIED
--   ✓ 3 Channels   : WhatsApp, Email, Voice/Phone
--   ✓ Msg Lengths  : short (Step 1), medium (Steps 2,4), long (Steps 3,5,7),
--                    short (Step 6)
--   ✓ Enterprise product  → is_enterprise_deal = 1
--   ✓ Data Centers org    → industry_close_rate = 0.67 (highest)
--
-- Key Validation Logic:
--   If lead_qualification > 0.80 (HIGH) then
--   consumer_score > 0.70 AND interaction_score > 0.70
--   AND product_quotation_score > 0.70 must all be true.
--
-- Server: http://localhost:8000  |  NS: vitasales  |  DB: vitasales
-- ================================================================


-- ================================================================
-- AUTO CLEANUP — run this block first every time
-- ================================================================

DELETE FROM message WHERE conversation IN [
    conversation:hs_conv_whatsapp,
    conversation:hs_conv_email,
    conversation:hs_conv_voice
];
DELETE conversation:hs_conv_whatsapp;
DELETE conversation:hs_conv_email;
DELETE conversation:hs_conv_voice;
DELETE FROM interested_in       WHERE in = lead:hs_test_lead;
DELETE FROM generated_quotation WHERE in = lead:hs_test_lead;
DELETE FROM generated           WHERE in = lead:hs_test_lead;
DELETE quotation:hs_quot_01;
DELETE lead:hs_test_lead;
DELETE organisation:hs_test_org;
DELETE product:hs_ent_product;


-- ================================================================
-- SETUP — Organisation + Enterprise Product + Lead (NEW_LEAD)
--
-- Organisation : Data Centers → industry_close_rate = 0.67 (max)
--                historical_deals_won = 5, avg_sentiment = 0.75
-- Product      : Enterprise Precision Chiller ₹5,00,000 (> 4L threshold)
--                → is_enterprise_deal = 1
-- ================================================================

CREATE organisation:hs_test_org SET
    name                     = 'DataCore Systems Pvt Ltd',
    industry                 = 'Data Centers',
    country                  = 'India',
    city                     = 'Bengaluru',
    historical_deals_won     = 5,
    historical_avg_sentiment = 0.75;

CREATE product:hs_ent_product SET
    name          = 'Enterprise Precision Chiller 20T',
    base_price    = 500000.0,
    tax_rate      = 18.0,
    capacity_tons = 20.0,
    attributes    = { type: 'single', complexity: 1.5 };

CREATE lead:hs_test_lead SET
    name           = 'Karan Malhotra',
    email          = 'karan.malhotra@datacoresystems.in',
    phone          = '+91-9876512300',
    designation    = 'VP Engineering',
    state          = 'NEW_LEAD',
    completeness   = 'INCOMPLETE',
    classification = 'NON-SALES',
    source_channel = channel:whatsapp,
    organisation   = organisation:hs_test_org,
    created_at     = time::now(),
    updated_at     = time::now();

RELATE lead:hs_test_lead->interested_in->product:hs_ent_product;

SELECT id, name, state, completeness FROM lead:hs_test_lead;
SELECT id, name, industry, historical_deals_won, historical_avg_sentiment
FROM organisation:hs_test_org;
SELECT id, name, base_price, capacity_tons FROM product:hs_ent_product;


-- ================================================================
-- STEP 0 — NEW_LEAD (baseline, product linked, no conversations)
--
-- Sentiments  : none yet (neutral baseline)
-- Channels    : none yet
-- Expected    : all 3 sub-model scores LOW
--               consumer: neutral=3, no msgs, stage=0
--               interaction: no convs, source=whatsapp
--               product_quotation: enterprise product, stage=0, no quotation
-- ================================================================

-- consumer_score [12 features]
RETURN {
    step:  "STEP 0 — NEW_LEAD (baseline)",
    model: "consumer_score",
    score: ml::consumer_score<1.0.0>([
        3.0,    -- [0]  primary_sentiment       neutral=3
        0.0,    -- [1]  sentiment_score         no messages yet
        0.0,    -- [2]  sentiment_combo_score   stage(0) × 0.0 = 0
        7.0,    -- [3]  intent                  new=7
        2.0,    -- [4]  message_quality         medium=2 (default)
        0.0,    -- [5]  summary_length          no summary
        0.0,    -- [6]  has_action_milestone    stage < QUOTATION
        0.0,    -- [7]  stage_velocity          0 / 1 day
        5.0,    -- [8]  historical_deals_won    org: 5 deals ← HIGH
        1.0,    -- [9]  is_repeat_customer      deals_won > 0 → 1
        0.75,   -- [10] historical_avg_sentiment org: 0.75 ← HIGH
        0.67    -- [11] industry_close_rate     Data Centers ← HIGHEST
    ])
};

-- interaction_score [15 features]
RETURN {
    step:  "STEP 0 — NEW_LEAD (baseline)",
    model: "interaction_score",
    score: ml::interaction_score<1.0.0>([
        0.0,    -- [0]  whatsapp_count          no conversations yet
        0.0,    -- [1]  phone_count
        0.0,    -- [2]  email_count
        0.0,    -- [3]  total_interactions
        2.0,    -- [4]  dominant_channel        whatsapp=2 (source_channel)
        2.0,    -- [5]  first_channel           whatsapp=2
        2.0,    -- [6]  last_channel            whatsapp=2
        0.0,    -- [7]  is_multi_channel        no
        0.0,    -- [8]  channel_switch_count
        0.0,    -- [9]  conversation_time_hours no span yet
        4.0,    -- [10] conv_time_bucket        medium_medium=4 (default)
        1.0,    -- [11] recency_bucket          cold=1 (no convs)
        0.0,    -- [12] engagement_depth        0 interactions × 0 = 0
        0.0,    -- [13] channel_x_stage         whatsapp(2) × stage(0) = 0
        5.0     -- [14] historical_deals_won    org: 5 ← HIGH
    ])
};

-- product_quotation_score [17 features — reference format]
RETURN {
    step:  "STEP 0 — NEW_LEAD (baseline)",
    model: "product_quotation_score",
    score: ml::product_quotation_score<1.0.0>([
        10.0,        -- [0]  product_type          single=10.0
        1.5,         -- [1]  product_complexity    enterprise chiller → 1.5
        500000.0,    -- [2]  product_base_price    ₹5,00,000 ← ENTERPRISE
        18.0,        -- [3]  product_tax_rate      18%
        0.0,         -- [4]  price_tier            enterprise=0.0 (≥ ₹4L)
        20.0,        -- [5]  capacity_tons         20T enterprise capacity
        1.0,         -- [6]  capacity_bin          11-20T = 1.0
        51.0,        -- [7]  product_x_capacity    10.0 × 5 + 1.0 = 51.0
        590000.0,    -- [8]  total_price_with_tax  500000 × 1.18
        0.0000339,   -- [9]  capacity_price_ratio  20 / 590000
        0.0,         -- [10] quotation_sent        not sent yet
        1.0,         -- [11] is_enterprise_deal    base_price ≥ 400000 → 1 ← HIGH
        0.67,        -- [12] industry_close_rate   Data Centers ← HIGHEST
        0.0,         -- [13] pipeline_stage        NEW_LEAD = 0.0
        1.0,         -- [14] is_repeat_customer    deals_won > 0 → 1
        1.0,         -- [15] days_in_pipeline      day 1
        0.0          -- [16] pipeline_velocity     stage(0) / day(1) = 0
    ])
};


-- ================================================================
-- STEP 1 — NEW_LEAD + WhatsApp Conversation
--
-- Channel    : WhatsApp (first touch — source channel)
-- Sentiment  : NEUTRAL  ← sentiment #1 of 7
-- Msg Length : SHORT (< 100 chars)
-- days_in_pipeline: 1
-- Expected   : slight uptick; multi-channel not yet active
-- ================================================================

CREATE conversation:hs_conv_whatsapp SET
    lead            = lead:hs_test_lead,
    channel         = channel:whatsapp,
    sentiment       = 'NEUTRAL',
    summary         = 'Initial WhatsApp inquiry. Customer asking about enterprise cooling solutions for data centre.',
    started_at      = time::now(),
    last_message_at = time::now(),
    created_at      = time::now();

-- SHORT message (< 100 chars) → message_quality = short = 3
CREATE message SET
    conversation = conversation:hs_conv_whatsapp,
    content      = 'Hi, need enterprise cooling for our DC. Can you help?',
    sender       = 'CUSTOMER',
    message_type = 'TEXT',
    created_at   = time::now();

SELECT id, state, ai_confidence FROM lead:hs_test_lead;
SELECT id, channel, sentiment FROM conversation:hs_conv_whatsapp;

-- ── ML SCORES after Step 1 ─────────────────────────────────────────

-- consumer_score: NEUTRAL sentiment, stage=0, summary short
RETURN {
    step:  "STEP 1 — WhatsApp (NEUTRAL) short msg",
    model: "consumer_score",
    score: ml::consumer_score<1.0.0>([
        3.0,    -- [0]  primary_sentiment       NEUTRAL = 3
        0.0,    -- [1]  sentiment_score         neutral weight = 0.0
        0.0,    -- [2]  sentiment_combo_score   stage(0) × 0.0 = 0
        7.0,    -- [3]  intent                  new=7
        3.0,    -- [4]  message_quality         SHORT = 3
        85.0,   -- [5]  summary_length          short summary
        0.0,    -- [6]  has_action_milestone    stage < QUOTATION
        0.0,    -- [7]  stage_velocity          stage(0) / day(1)
        5.0,    -- [8]  historical_deals_won
        1.0,    -- [9]  is_repeat_customer
        0.75,   -- [10] historical_avg_sentiment
        0.67    -- [11] industry_close_rate
    ])
};

-- interaction_score: 1 WhatsApp, single channel, neutral engagement
RETURN {
    step:  "STEP 1 — WhatsApp (NEUTRAL) short msg",
    model: "interaction_score",
    score: ml::interaction_score<1.0.0>([
        1.0,    -- [0]  whatsapp_count          1 message
        0.0,    -- [1]  phone_count
        0.0,    -- [2]  email_count
        1.0,    -- [3]  total_interactions      1
        2.0,    -- [4]  dominant_channel        whatsapp = 2
        2.0,    -- [5]  first_channel           whatsapp = 2
        2.0,    -- [6]  last_channel            whatsapp = 2
        0.0,    -- [7]  is_multi_channel        only 1 channel
        0.0,    -- [8]  channel_switch_count
        0.5,    -- [9]  conversation_time_hours ~30 min
        4.0,    -- [10] conv_time_bucket        1 interaction → bucket=4
        2.0,    -- [11] recency_bucket          fresh = 2 (just created)
        0.0,    -- [12] engagement_depth        1 × neutral_weight(0.0) = 0
        0.0,    -- [13] channel_x_stage         whatsapp(2) × stage(0) = 0
        5.0     -- [14] historical_deals_won
    ])
};

-- product_quotation_score: enterprise product, stage=0, no quotation
RETURN {
    step:  "STEP 1 — WhatsApp (NEUTRAL) short msg",
    model: "product_quotation_score",
    score: ml::product_quotation_score<1.0.0>([
        10.0, 1.5, 500000.0, 18.0, 0.0, 20.0, 1.0, 51.0,
        590000.0, 0.0000339,
        0.0,         -- [10] quotation_sent      not yet
        1.0,         -- [11] is_enterprise_deal  ← HIGH
        0.67,        -- [12] industry_close_rate ← HIGHEST
        0.0,         -- [13] pipeline_stage      NEW_LEAD = 0
        1.0, 1.0, 0.0
    ])
};


-- ================================================================
-- STEP 2 — MANUAL_FOLLOW_UP + Email Conversation
--
-- Channel    : Email (2nd channel — multi-channel begins)
-- Sentiment  : INTERESTED  ← sentiment #2 of 7
-- Msg Length : MEDIUM (100–200 chars)
-- days_in_pipeline: 2
-- Expected   : is_multi_channel flips to 1; combo_score rises (stage=1)
-- ================================================================

UPDATE lead:hs_test_lead SET
    state      = 'MANUAL_FOLLOW_UP',
    updated_at = time::now();

CREATE conversation:hs_conv_email SET
    lead            = lead:hs_test_lead,
    channel         = channel:email,
    sentiment       = 'INTERESTED',
    summary         = 'Follow-up email from customer. Very interested in enterprise chiller. Requested specs, pricing, and delivery timelines for a 20-ton unit.',
    started_at      = time::now(),
    last_message_at = time::now(),
    created_at      = time::now();

-- MEDIUM message (100–200 chars)
CREATE message SET
    conversation = conversation:hs_conv_email,
    content      = 'Very interested in the Enterprise Precision Chiller 20T. Please send full specs, pricing, and delivery schedule. We are ready to move forward quickly.',
    sender       = 'CUSTOMER',
    message_type = 'TEXT',
    created_at   = time::now();

SELECT id, state, ai_confidence FROM lead:hs_test_lead;
SELECT id, channel, sentiment FROM conversation:hs_conv_email;

-- ── ML SCORES after Step 2 ─────────────────────────────────────────

RETURN {
    step:  "STEP 2 — MANUAL_FOLLOW_UP + Email (INTERESTED) medium msg",
    model: "consumer_score",
    score: ml::consumer_score<1.0.0>([
        5.0,    -- [0]  primary_sentiment       INTERESTED = 5
        0.60,   -- [1]  sentiment_score         interested weight
        0.60,   -- [2]  sentiment_combo_score   stage(1) × 0.60
        5.0,    -- [3]  intent                  interested = 5
        2.0,    -- [4]  message_quality         MEDIUM = 2
        180.0,  -- [5]  summary_length          medium summary
        0.0,    -- [6]  has_action_milestone    stage < QUOTATION
        0.50,   -- [7]  stage_velocity          stage(1) / day(2)
        5.0,    -- [8]  historical_deals_won
        1.0,    -- [9]  is_repeat_customer
        0.75,   -- [10] historical_avg_sentiment
        0.67    -- [11] industry_close_rate
    ])
};

RETURN {
    step:  "STEP 2 — MANUAL_FOLLOW_UP + Email (INTERESTED) medium msg",
    model: "interaction_score",
    score: ml::interaction_score<1.0.0>([
        1.0,    -- [0]  whatsapp_count          1 msg
        0.0,    -- [1]  phone_count
        1.0,    -- [2]  email_count             1 msg (email added)
        2.0,    -- [3]  total_interactions      1+0+1=2
        2.0,    -- [4]  dominant_channel        whatsapp=2 (tied, first wins)
        2.0,    -- [5]  first_channel           whatsapp=2
        0.0,    -- [6]  last_channel            email=0
        1.0,    -- [7]  is_multi_channel        YES ← key change
        1.0,    -- [8]  channel_switch_count    2 channels - 1 = 1
        24.0,   -- [9]  conversation_time_hours ~1 day span
        2.0,    -- [10] conv_time_bucket        2 interactions, fast → 2
        2.0,    -- [11] recency_bucket          fresh = 2
        1.20,   -- [12] engagement_depth        2 × 0.60
        2.0,    -- [13] channel_x_stage         whatsapp(2) × stage(1) = 2
        5.0     -- [14] historical_deals_won
    ])
};

RETURN {
    step:  "STEP 2 — MANUAL_FOLLOW_UP + Email (INTERESTED) medium msg",
    model: "product_quotation_score",
    score: ml::product_quotation_score<1.0.0>([
        10.0, 1.5, 500000.0, 18.0, 0.0, 20.0, 1.0, 51.0,
        590000.0, 0.0000339,
        0.0, 1.0, 0.67,
        1.0,         -- [13] pipeline_stage      MANUAL_FOLLOW_UP = 1
        1.0,
        2.0,         -- [15] days_in_pipeline    2 days
        0.50         -- [16] pipeline_velocity   stage(1) / day(2) = 0.50
    ])
};


-- ================================================================
-- STEP 3 — SALES_FOLLOW_UP + Voice/Phone Call
--
-- Channel    : Voice/Phone (3rd channel)
-- Sentiment  : CURIOUS  ← sentiment #3 of 7
-- Msg Length : LONG (> 200 chars)
-- days_in_pipeline: 4
-- Expected   : 3 distinct channels → is_multi_channel=1, switch_count=2
--              consumer rising (stage=2, CURIOUS=4, strong summary)
-- ================================================================

UPDATE lead:hs_test_lead SET
    state      = 'SALES_FOLLOW_UP',
    updated_at = time::now();

CREATE conversation:hs_conv_voice SET
    lead            = lead:hs_test_lead,
    channel         = channel:voice,
    sentiment       = 'CURIOUS',
    summary         = 'Phone call summary: Customer deeply interested and asked many detailed technical questions. Curious about integration with existing data centre HVAC. Wants to understand total cost of ownership, SLA guarantees, and maintenance schedule before deciding.',
    started_at      = time::now(),
    last_message_at = time::now(),
    created_at      = time::now();

-- LONG message (> 200 chars)
CREATE message SET
    conversation = conversation:hs_conv_voice,
    content      = 'We are very curious about how your Enterprise Chiller integrates with our existing HVAC system. We also need clarity on total cost of ownership, uptime SLA, and the annual maintenance contract. Can you arrange a technical walkthrough with our infrastructure team next week?',
    sender       = 'CUSTOMER',
    message_type = 'TEXT',
    created_at   = time::now();

SELECT id, state, ai_confidence FROM lead:hs_test_lead;
SELECT id, channel, sentiment FROM conversation:hs_conv_voice;

-- ── ML SCORES after Step 3 ─────────────────────────────────────────

RETURN {
    step:  "STEP 3 — SALES_FOLLOW_UP + Voice (CURIOUS) long msg — 3 channels",
    model: "consumer_score",
    score: ml::consumer_score<1.0.0>([
        4.0,    -- [0]  primary_sentiment       CURIOUS = 4
        0.65,   -- [1]  sentiment_score
        1.30,   -- [2]  sentiment_combo_score   stage(2) × 0.65
        4.0,    -- [3]  intent                  hot = 4
        1.0,    -- [4]  message_quality         LONG = 1
        270.0,  -- [5]  summary_length          long detailed summary
        0.0,    -- [6]  has_action_milestone    stage < QUOTATION
        0.50,   -- [7]  stage_velocity          stage(2) / day(4)
        5.0,    -- [8]  historical_deals_won
        1.0,    -- [9]  is_repeat_customer
        0.75,   -- [10] historical_avg_sentiment
        0.67    -- [11] industry_close_rate
    ])
};

RETURN {
    step:  "STEP 3 — SALES_FOLLOW_UP + Voice (CURIOUS) long msg — 3 channels",
    model: "interaction_score",
    score: ml::interaction_score<1.0.0>([
        1.0,    -- [0]  whatsapp_count
        1.0,    -- [1]  phone_count             voice added ← 3rd channel
        1.0,    -- [2]  email_count
        3.0,    -- [3]  total_interactions      1+1+1=3
        2.0,    -- [4]  dominant_channel        all tied → whatsapp=2
        2.0,    -- [5]  first_channel           whatsapp=2
        1.0,    -- [6]  last_channel            voice/phone=1
        1.0,    -- [7]  is_multi_channel        3 channels
        2.0,    -- [8]  channel_switch_count    3 channels - 1 = 2
        72.0,   -- [9]  conversation_time_hours ~3 days span
        1.0,    -- [10] conv_time_bucket        medium_slow=1 (3 interactions, longer time)
        2.0,    -- [11] recency_bucket          fresh=2
        1.95,   -- [12] engagement_depth        3 × 0.65
        4.0,    -- [13] channel_x_stage         whatsapp(2) × stage(2) = 4
        5.0     -- [14] historical_deals_won
    ])
};

RETURN {
    step:  "STEP 3 — SALES_FOLLOW_UP + Voice (CURIOUS) long msg — 3 channels",
    model: "product_quotation_score",
    score: ml::product_quotation_score<1.0.0>([
        10.0, 1.5, 500000.0, 18.0, 0.0, 20.0, 1.0, 51.0,
        590000.0, 0.0000339,
        0.0, 1.0, 0.67,
        2.0,         -- [13] pipeline_stage      SALES_FOLLOW_UP = 2
        1.0,
        4.0,         -- [15] days_in_pipeline    4 days
        0.50         -- [16] pipeline_velocity   stage(2) / day(4) = 0.50
    ])
};


-- ================================================================
-- STEP 4 — SALES_QUALIFIED + COMPLETE + 2nd WhatsApp Message
--
-- Channel    : WhatsApp (2nd message in same conversation)
-- Sentiment  : POSITIVE  ← sentiment #4 of 7
-- Msg Length : MEDIUM (100–200 chars)
-- completeness : INCOMPLETE → COMPLETE
-- classification: NON-SALES → SALES
-- days_in_pipeline: 7
-- Expected   : strong rise — stage=3, COMPLETE, whatsapp_count=2
-- ================================================================

UPDATE lead:hs_test_lead SET
    state          = 'SALES_QUALIFIED',
    completeness   = 'COMPLETE',
    classification = 'SALES',
    updated_at     = time::now();

-- 2nd WhatsApp message — POSITIVE sentiment update
CREATE message SET
    conversation = conversation:hs_conv_whatsapp,
    content      = 'We had an internal review. The technical team loves the specs. Budget is approved. Please start preparing a formal quotation. Very positive about this.',
    sender       = 'CUSTOMER',
    message_type = 'TEXT',
    created_at   = time::now();

UPDATE conversation:hs_conv_whatsapp SET
    sentiment       = 'POSITIVE',
    last_message_at = time::now(),
    summary         = 'Customer confirmed internal approval. Tech team satisfied with specs. Budget approved. Ready for formal quotation. Strong positive buying signal.';

SELECT id, state, completeness, classification, ai_confidence
FROM lead:hs_test_lead;

-- ── ML SCORES after Step 4 ─────────────────────────────────────────

RETURN {
    step:  "STEP 4 — SALES_QUALIFIED + COMPLETE + WhatsApp (POSITIVE) medium msg",
    model: "consumer_score",
    score: ml::consumer_score<1.0.0>([
        5.0,    -- [0]  primary_sentiment       POSITIVE ≈ interested=5
        0.75,   -- [1]  sentiment_score
        2.25,   -- [2]  sentiment_combo_score   stage(3) × 0.75
        3.0,    -- [3]  intent                  evaluating=3
        2.0,    -- [4]  message_quality         MEDIUM = 2
        190.0,  -- [5]  summary_length
        0.0,    -- [6]  has_action_milestone    stage < QUOTATION (3 < 4)
        0.43,   -- [7]  stage_velocity          stage(3) / day(7)
        5.0,    -- [8]  historical_deals_won
        1.0,    -- [9]  is_repeat_customer
        0.75,   -- [10] historical_avg_sentiment
        0.67    -- [11] industry_close_rate
    ])
};

RETURN {
    step:  "STEP 4 — SALES_QUALIFIED + COMPLETE + WhatsApp (POSITIVE) medium msg",
    model: "interaction_score",
    score: ml::interaction_score<1.0.0>([
        2.0,    -- [0]  whatsapp_count          2nd WhatsApp message
        1.0,    -- [1]  phone_count
        1.0,    -- [2]  email_count
        4.0,    -- [3]  total_interactions      2+1+1=4
        2.0,    -- [4]  dominant_channel        whatsapp=2 (most msgs)
        2.0,    -- [5]  first_channel           whatsapp=2
        2.0,    -- [6]  last_channel            whatsapp=2 (most recent)
        1.0,    -- [7]  is_multi_channel
        2.0,    -- [8]  channel_switch_count
        120.0,  -- [9]  conversation_time_hours ~5 days
        3.0,    -- [10] conv_time_bucket        medium_medium=3
        2.0,    -- [11] recency_bucket          fresh=2
        3.00,   -- [12] engagement_depth        4 × 0.75
        6.0,    -- [13] channel_x_stage         whatsapp(2) × stage(3) = 6
        5.0     -- [14] historical_deals_won
    ])
};

RETURN {
    step:  "STEP 4 — SALES_QUALIFIED + COMPLETE + WhatsApp (POSITIVE) medium msg",
    model: "product_quotation_score",
    score: ml::product_quotation_score<1.0.0>([
        10.0, 1.5, 500000.0, 18.0, 0.0, 20.0, 1.0, 51.0,
        590000.0, 0.0000339,
        0.0, 1.0, 0.67,
        3.0,         -- [13] pipeline_stage      SALES_QUALIFIED = 3
        1.0,
        7.0,         -- [15] days_in_pipeline    7 days
        0.43         -- [16] pipeline_velocity   stage(3) / day(7) = 0.43
    ])
};


-- ================================================================
-- STEP 5 — QUOTATION Sent + 2nd Email Message
--
-- Channel    : Email (2nd message in email conversation)
-- Sentiment  : URGENT  ← sentiment #5 of 7
-- Msg Length : LONG (> 200 chars)
-- quotation_sent = 1, has_action_milestone = 1 ← biggest signal jump
-- days_in_pipeline: 10
-- Expected   : LARGE score jump across all 3 models
--              product_quotation: quotation_sent flips to 1 (biggest feature)
--              consumer: has_action_milestone flips to 1
-- ================================================================

CREATE quotation:hs_quot_01 SET
    lead         = lead:hs_test_lead,
    quote_id     = 'QT-HS-2026-001',
    quotation_no = 'VF-HS-2026-001',
    status       = 'GENERATED',
    currency     = 'INR',
    subtotal     = 500000.00,
    products     = [{
        product    : product:hs_ent_product,
        name       : 'Enterprise Precision Chiller 20T',
        sku        : 'EPC-20T-001',
        quantity   : 1,
        unit_price : 500000.00,
        tax_rate   : 18.0,
        tax_amount : 90000.00,
        total      : 590000.00
    }],
    tax_amount   = 90000.00,
    total_amount = 590000.00,
    notes        = 'Enterprise Precision Chiller 20T for DataCore data centre. Includes 2-year AMC and 24/7 SLA.',
    model        = 'EPC-20T',
    isfeedback   = false,
    generated_at = time::now(),
    created_at   = time::now();

RELATE lead:hs_test_lead->generated_quotation->quotation:hs_quot_01;
RELATE lead:hs_test_lead->generated->quotation:hs_quot_01;

UPDATE quotation:hs_quot_01 SET
    status   = 'SENT',
    sent_via = 'EMAIL',
    sent_at  = time::now();

UPDATE lead:hs_test_lead SET
    state      = 'QUOTATION',
    updated_at = time::now();

-- URGENT 2nd Email message — customer has a hard deadline
-- LONG message (> 200 chars)
CREATE message SET
    conversation = conversation:hs_conv_email,
    content      = 'We received the quotation. We have an URGENT requirement — our current cooling system failed and we need a replacement before end of month or our entire data centre operations are at risk. Please expedite delivery and confirm within 24 hours. We are ready to sign the purchase order today if you confirm availability.',
    sender       = 'CUSTOMER',
    message_type = 'TEXT',
    created_at   = time::now();

UPDATE conversation:hs_conv_email SET
    sentiment       = 'URGENT',
    last_message_at = time::now(),
    summary         = 'Customer has URGENT cooling failure. Needs enterprise chiller before month end. Ready to sign PO today. Critical business impact if not resolved.';

SELECT id, state, ai_confidence FROM lead:hs_test_lead;
SELECT id, quote_id, status, total_amount, sent_at FROM quotation:hs_quot_01;

-- ── ML SCORES after Step 5 ─────────────────────────────────────────

RETURN {
    step:  "STEP 5 — QUOTATION sent + Email (URGENT) long msg",
    model: "consumer_score",
    score: ml::consumer_score<1.0.0>([
        6.0,    -- [0]  primary_sentiment       URGENT = 6 (maximum)
        0.80,   -- [1]  sentiment_score         strong urgency
        3.20,   -- [2]  sentiment_combo_score   stage(4) × 0.80
        2.0,    -- [3]  intent                  closing=2 (urgent = near buy)
        1.0,    -- [4]  message_quality         LONG = 1
        260.0,  -- [5]  summary_length          long urgent summary
        1.0,    -- [6]  has_action_milestone    QUOTATION reached ← flip!
        0.40,   -- [7]  stage_velocity          stage(4) / day(10)
        5.0,    -- [8]  historical_deals_won
        1.0,    -- [9]  is_repeat_customer
        0.75,   -- [10] historical_avg_sentiment
        0.67    -- [11] industry_close_rate
    ])
};

RETURN {
    step:  "STEP 5 — QUOTATION sent + Email (URGENT) long msg",
    model: "interaction_score",
    score: ml::interaction_score<1.0.0>([
        2.0,    -- [0]  whatsapp_count
        1.0,    -- [1]  phone_count
        2.0,    -- [2]  email_count             2nd email message
        5.0,    -- [3]  total_interactions      2+1+2=5
        2.0,    -- [4]  dominant_channel        whatsapp=2 (still most)
        2.0,    -- [5]  first_channel           whatsapp=2
        0.0,    -- [6]  last_channel            email=0 (most recent)
        1.0,    -- [7]  is_multi_channel
        2.0,    -- [8]  channel_switch_count
        168.0,  -- [9]  conversation_time_hours ~7 days
        3.0,    -- [10] conv_time_bucket        medium_medium=3
        2.0,    -- [11] recency_bucket          fresh=2
        4.00,   -- [12] engagement_depth        5 × 0.80
        8.0,    -- [13] channel_x_stage         whatsapp(2) × stage(4) = 8
        5.0     -- [14] historical_deals_won
    ])
};

RETURN {
    step:  "STEP 5 — QUOTATION sent + Email (URGENT) long msg",
    model: "product_quotation_score",
    score: ml::product_quotation_score<1.0.0>([
        10.0, 1.5, 500000.0, 18.0, 0.0, 20.0, 1.0, 51.0,
        590000.0, 0.0000339,
        1.0,         -- [10] quotation_sent      = 1 ← BIGGEST SIGNAL JUMP
        1.0,         -- [11] is_enterprise_deal  ← HIGH
        0.67,        -- [12] industry_close_rate ← HIGHEST
        4.0,         -- [13] pipeline_stage      QUOTATION = 4
        1.0,
        10.0,        -- [15] days_in_pipeline    10 days
        0.40         -- [16] pipeline_velocity   stage(4) / day(10) = 0.40
    ])
};


-- ================================================================
-- STEP 6 — FOLLOW_UP_NEGOTIATION + 2nd Voice Message
--
-- Channel    : Voice (2nd message in voice conversation)
-- Sentiment  : NEGOTIATING  ← sentiment #6 of 7
-- Msg Length : SHORT (< 100 chars)
-- days_in_pipeline: 14
-- Expected   : near-peak scores; negotiating = very strong buy signal
-- ================================================================

UPDATE lead:hs_test_lead SET
    state      = 'FOLLOW_UP_NEGOTIATION',
    updated_at = time::now();

-- SHORT negotiation message
CREATE message SET
    conversation = conversation:hs_conv_voice,
    content      = 'Can you offer a 5% discount? We sign PO today if you agree.',
    sender       = 'CUSTOMER',
    message_type = 'TEXT',
    created_at   = time::now();

UPDATE conversation:hs_conv_voice SET
    sentiment       = 'NEGOTIATING',
    last_message_at = time::now(),
    summary         = 'Customer negotiating 5% discount. Confirmed readiness to sign PO immediately upon agreement. Deal very close to closing.';

SELECT id, state, ai_confidence FROM lead:hs_test_lead;
SELECT id, channel, sentiment FROM conversation:hs_conv_voice;

-- ── ML SCORES after Step 6 ─────────────────────────────────────────

RETURN {
    step:  "STEP 6 — FOLLOW_UP_NEGOTIATION + Voice (NEGOTIATING) short msg",
    model: "consumer_score",
    score: ml::consumer_score<1.0.0>([
        4.0,    -- [0]  primary_sentiment       NEGOTIATING ≈ curious/urgent = 4
        0.70,   -- [1]  sentiment_score
        3.50,   -- [2]  sentiment_combo_score   stage(5) × 0.70
        3.0,    -- [3]  intent                  evaluating/closing=3
        3.0,    -- [4]  message_quality         SHORT = 3
        170.0,  -- [5]  summary_length
        1.0,    -- [6]  has_action_milestone    stage >= QUOTATION → 1
        0.36,   -- [7]  stage_velocity          stage(5) / day(14)
        5.0,    -- [8]  historical_deals_won
        1.0,    -- [9]  is_repeat_customer
        0.75,   -- [10] historical_avg_sentiment
        0.67    -- [11] industry_close_rate
    ])
};

RETURN {
    step:  "STEP 6 — FOLLOW_UP_NEGOTIATION + Voice (NEGOTIATING) short msg",
    model: "interaction_score",
    score: ml::interaction_score<1.0.0>([
        2.0,    -- [0]  whatsapp_count
        2.0,    -- [1]  phone_count             2nd voice message
        2.0,    -- [2]  email_count
        6.0,    -- [3]  total_interactions      2+2+2=6
        2.0,    -- [4]  dominant_channel        all tied → whatsapp=2
        2.0,    -- [5]  first_channel           whatsapp=2
        1.0,    -- [6]  last_channel            voice/phone=1
        1.0,    -- [7]  is_multi_channel
        2.0,    -- [8]  channel_switch_count
        240.0,  -- [9]  conversation_time_hours ~10 days
        3.0,    -- [10] conv_time_bucket        medium_medium=3
        2.0,    -- [11] recency_bucket          fresh=2
        4.20,   -- [12] engagement_depth        6 × 0.70
        10.0,   -- [13] channel_x_stage         whatsapp(2) × stage(5) = 10
        5.0     -- [14] historical_deals_won
    ])
};

RETURN {
    step:  "STEP 6 — FOLLOW_UP_NEGOTIATION + Voice (NEGOTIATING) short msg",
    model: "product_quotation_score",
    score: ml::product_quotation_score<1.0.0>([
        10.0, 1.5, 500000.0, 18.0, 0.0, 20.0, 1.0, 51.0,
        590000.0, 0.0000339,
        1.0, 1.0, 0.67,
        5.0,         -- [13] pipeline_stage      FOLLOW_UP_NEGOTIATION = 5
        1.0,
        14.0,        -- [15] days_in_pipeline    14 days
        0.36         -- [16] pipeline_velocity   stage(5) / day(14)
    ])
};


-- ================================================================
-- STEP 7 — CLOSED + 3rd WhatsApp Message (Deal Won)
--
-- Channel    : WhatsApp (3rd message — closing message)
-- Sentiment  : SATISFIED  ← sentiment #7 of 7 — ALL 7 COVERED ✓
-- Msg Length : LONG (> 200 chars)
-- days_in_pipeline: 16
-- Expected   : ALL 3 models at PEAK (> 0.70 each)
--              This is the state that should produce HIGH lead_qualification
-- ================================================================

-- Final SATISFIED closing message — LONG
CREATE message SET
    conversation = conversation:hs_conv_whatsapp,
    content      = 'We accept the quotation and are completely satisfied with the entire process — from first contact through technical discussion, quotation, and negotiation. Your team was outstanding. Please proceed with the order. We look forward to a long-term partnership with your organisation for all our cooling needs.',
    sender       = 'CUSTOMER',
    message_type = 'TEXT',
    created_at   = time::now();

UPDATE quotation:hs_quot_01 SET
    status         = 'ACCEPTED',
    accepted_at    = time::now(),
    feedbackrating = '5',
    isfeedback     = true;

UPDATE conversation:hs_conv_whatsapp SET
    sentiment       = 'SATISFIED',
    last_message_at = time::now(),
    summary         = 'Customer accepted quotation. Fully satisfied with service, product, and team. Long-term partnership confirmed. Deal closed successfully.';

UPDATE lead:hs_test_lead SET
    state      = 'CLOSED',
    updated_at = time::now();

SELECT id, state, completeness, classification, ai_confidence FROM lead:hs_test_lead;
SELECT id, status, accepted_at, feedbackrating FROM quotation:hs_quot_01;

-- ── ML SCORES at CLOSED — Peak values (should all be > 0.70) ──────

RETURN {
    step:  "STEP 7 — CLOSED + WhatsApp (SATISFIED) long msg — PEAK",
    model: "consumer_score",
    score: ml::consumer_score<1.0.0>([
        5.0,    -- [0]  primary_sentiment       SATISFIED ≈ interested=5
        0.85,   -- [1]  sentiment_score         highest positive
        5.10,   -- [2]  sentiment_combo_score   stage(6) × 0.85 ← maximum
        3.0,    -- [3]  intent                  evaluating/closed
        0.0,    -- [4]  message_quality         DETAILED = 0 (long rich summary)
        300.0,  -- [5]  summary_length          long closing summary
        1.0,    -- [6]  has_action_milestone    stage(6) >= QUOTATION → 1
        0.38,   -- [7]  stage_velocity          stage(6) / day(16)
        5.0,    -- [8]  historical_deals_won    ← HIGH org signal
        1.0,    -- [9]  is_repeat_customer
        0.75,   -- [10] historical_avg_sentiment ← HIGH org signal
        0.67    -- [11] industry_close_rate     ← HIGHEST industry signal
    ])
    -- Expected: > 0.70 → consumer_score_tier = 3 (HIGH)
};

RETURN {
    step:  "STEP 7 — CLOSED + WhatsApp (SATISFIED) long msg — PEAK",
    model: "interaction_score",
    score: ml::interaction_score<1.0.0>([
        3.0,    -- [0]  whatsapp_count          3 msgs total
        2.0,    -- [1]  phone_count
        2.0,    -- [2]  email_count
        7.0,    -- [3]  total_interactions      3+2+2=7 ← strong
        2.0,    -- [4]  dominant_channel        whatsapp=2
        2.0,    -- [5]  first_channel           whatsapp=2
        2.0,    -- [6]  last_channel            whatsapp=2 (closing msg)
        1.0,    -- [7]  is_multi_channel        3 distinct channels ← strong
        2.0,    -- [8]  channel_switch_count    3-1=2
        360.0,  -- [9]  conversation_time_hours ~15 days full span
        3.0,    -- [10] conv_time_bucket        medium_medium=3
        2.0,    -- [11] recency_bucket          fresh=2 (closing msg just now)
        5.95,   -- [12] engagement_depth        7 × 0.85 ← maximum
        12.0,   -- [13] channel_x_stage         whatsapp(2) × stage(6) = 12 ← max
        5.0     -- [14] historical_deals_won    ← HIGH org signal
    ])
    -- Expected: > 0.70 → interaction_score_tier = 3 (HIGH)
};

RETURN {
    step:  "STEP 7 — CLOSED + WhatsApp (SATISFIED) long msg — PEAK",
    model: "product_quotation_score",
    score: ml::product_quotation_score<1.0.0>([
        10.0,        -- [0]  product_type          single=10.0
        1.5,         -- [1]  product_complexity    enterprise → 1.5
        500000.0,    -- [2]  product_base_price    ₹5,00,000 ← ENTERPRISE
        18.0,        -- [3]  product_tax_rate
        0.0,         -- [4]  price_tier            enterprise=0.0
        20.0,        -- [5]  capacity_tons         20T
        1.0,         -- [6]  capacity_bin          11-20T=1
        51.0,        -- [7]  product_x_capacity    10×5+1=51
        590000.0,    -- [8]  total_price_with_tax  500000×1.18 ← HIGH value
        0.0000339,   -- [9]  capacity_price_ratio  20/590000
        1.0,         -- [10] quotation_sent        = 1 ← strong signal
        1.0,         -- [11] is_enterprise_deal    ← HIGH
        0.67,        -- [12] industry_close_rate   ← HIGHEST
        6.0,         -- [13] pipeline_stage        CLOSED = 6 ← max
        1.0,         -- [14] is_repeat_customer
        16.0,        -- [15] days_in_pipeline
        0.38         -- [16] pipeline_velocity     stage(6) / day(16)
    ])
    -- Expected: > 0.70 → product_quotation_score_tier = 3 (HIGH)
};


-- ================================================================
-- ══════════════════════════════════════════════════════════════
--   FINAL HIGH SCORE VALIDATION
--   Objective: Prove that when all 3 sub-models are HIGH (>70%),
--   lead_qualification is also HIGH (>80%)
--
--   Tier mapping: score < 0.40 → tier 1 (LOW)
--                 0.40–0.70   → tier 2 (MEDIUM)
--                 > 0.70      → tier 3 (HIGH)
-- ══════════════════════════════════════════════════════════════
-- ================================================================


-- ──────────────────────────────────────────────────────────────
-- VALIDATION A — consumer_score with ALL HIGH inputs
-- Expected output: > 0.70 → tier 3 (HIGH)
-- If this passes: consumer_score_tier = 3.0 feeds into lead_qualification
-- ──────────────────────────────────────────────────────────────
RETURN {
    validation: "A — consumer_score HIGH inputs",
    expected:   "> 0.70 (tier 3 HIGH)",
    score: ml::consumer_score<1.0.0>([
        5.0,    -- [0]  primary_sentiment       SATISFIED = 5
        0.85,   -- [1]  sentiment_score         peak positive
        5.10,   -- [2]  sentiment_combo_score   stage(6) × 0.85 = 5.10 ← max
        3.0,    -- [3]  intent                  evaluating/near-close = 3
        0.0,    -- [4]  message_quality         DETAILED = 0 (rich summary)
        320.0,  -- [5]  summary_length          long closing summary
        1.0,    -- [6]  has_action_milestone    1 (stage=6 >= QUOTATION)
        3.0,    -- [7]  stage_velocity          stage(6)/day(2) = 3.0 (fast deal)
        5.0,    -- [8]  historical_deals_won    5 ← HIGH ORG
        1.0,    -- [9]  is_repeat_customer      deals_won > 0 → 1
        0.75,   -- [10] historical_avg_sentiment 0.75 ← HIGH ORG
        0.67    -- [11] industry_close_rate     Data Centers ← HIGHEST
    ])
};

-- ──────────────────────────────────────────────────────────────
-- VALIDATION B — interaction_score with ALL HIGH inputs
-- Expected output: > 0.70 → tier 3 (HIGH)
-- If this passes: interaction_score_tier = 3.0 feeds into lead_qualification
-- ──────────────────────────────────────────────────────────────
RETURN {
    validation: "B — interaction_score HIGH inputs",
    expected:   "> 0.70 (tier 3 HIGH)",
    score: ml::interaction_score<1.0.0>([
        3.0,    -- [0]  whatsapp_count          3 msgs (WhatsApp dominant)
        2.0,    -- [1]  phone_count             2 voice calls
        2.0,    -- [2]  email_count             2 emails
        7.0,    -- [3]  total_interactions      3+2+2=7 ← strong engagement
        2.0,    -- [4]  dominant_channel        whatsapp=2
        2.0,    -- [5]  first_channel           whatsapp=2 (first touch)
        2.0,    -- [6]  last_channel            whatsapp=2 (closing msg)
        1.0,    -- [7]  is_multi_channel        3 channels ← strong signal
        2.0,    -- [8]  channel_switch_count    3-1=2 ← multi-channel journey
        480.0,  -- [9]  conversation_time_hours ~20 days engaged
        3.0,    -- [10] conv_time_bucket        medium_medium=3
        2.0,    -- [11] recency_bucket          fresh=2 (last msg today)
        5.95,   -- [12] engagement_depth        7 × 0.85 ← peak
        12.0,   -- [13] channel_x_stage         whatsapp(2) × stage(6) = 12 ← peak
        5.0     -- [14] historical_deals_won    5 ← HIGH ORG
    ])
};

-- ──────────────────────────────────────────────────────────────
-- VALIDATION C — product_quotation_score with ALL HIGH inputs
-- Expected output: > 0.70 → tier 3 (HIGH)
-- If this passes: product_quotation_score_tier = 3.0 feeds into lead_qualification
-- ──────────────────────────────────────────────────────────────
RETURN {
    validation: "C — product_quotation_score HIGH inputs",
    expected:   "> 0.70 (tier 3 HIGH)",
    score: ml::product_quotation_score<1.0.0>([
        10.0,        -- [0]  product_type          single=10.0
        1.5,         -- [1]  product_complexity    enterprise precision chiller
        500000.0,    -- [2]  product_base_price    ₹5,00,000 ← ENTERPRISE
        18.0,        -- [3]  product_tax_rate      18%
        0.0,         -- [4]  price_tier            enterprise=0 (≥ ₹4,00,000)
        20.0,        -- [5]  capacity_tons         20T enterprise
        1.0,         -- [6]  capacity_bin          11-20T = 1
        51.0,        -- [7]  product_x_capacity    10×5+1=51
        590000.0,    -- [8]  total_price_with_tax  500000×1.18 ← HIGH value
        0.0000339,   -- [9]  capacity_price_ratio  20/590000
        1.0,         -- [10] quotation_sent        = 1 ← strong feature
        1.0,         -- [11] is_enterprise_deal    base_price ≥ 400000 → 1 ← HIGH
        0.67,        -- [12] industry_close_rate   Data Centers ← HIGHEST
        6.0,         -- [13] pipeline_stage        CLOSED = 6 ← max
        1.0,         -- [14] is_repeat_customer    5 historical deals > 0 → 1
        2.0,         -- [15] days_in_pipeline      2 days (fast close)
        3.0          -- [16] pipeline_velocity     stage(6)/day(2)=3.0 (fast)
    ])
};

-- ──────────────────────────────────────────────────────────────
-- VALIDATION D — lead_qualification with all 3 sub-model tiers = 3 (HIGH)
--
-- All continuous features are IQR-binned (bins 1/2/3) in this model.
-- Sub-model tier mapping: score < 0.40 → 1, 0.40-0.70 → 2, > 0.70 → 3
-- recency_bucket scale here: 1=cold, 2=stale, 3=active, 4=fresh
-- pipeline_stage: alphabetical label encoding (CLOSED=1)
--
-- Expected output: > 0.80 → HIGH lead qualification
-- This CONFIRMS the model consistency:
--   consumer=HIGH + interaction=HIGH + product_quotation=HIGH → lead_qual=HIGH
-- ──────────────────────────────────────────────────────────────
RETURN {
    validation: "D — lead_qualification (all sub-models HIGH → expected > 0.80)",
    expected:   "> 0.80 (HIGH lead qualification)",
    score: ml::lead_qualification<1.0.0>([
        1.0,    -- [0]  has_action_milestone    stage(6) >= QUOTATION → 1
        3.0,    -- [1]  stage_velocity          bin 3: 6/2=3.0 > 1.86 threshold
        3.0,    -- [2]  historical_deals_won    bin 3: 5 deals (> bin3 threshold)
        1.0,    -- [3]  is_repeat_customer      5 deals > 0 → 1
        3.0,    -- [4]  industry_close_rate     bin 3: 0.67 > 0.594 threshold
        3.0,    -- [5]  historical_avg_sentiment bin 3: 0.75 > 0.48 threshold
        2.0,    -- [6]  intent                  bin 2: evaluating → mid range
        3.0,    -- [7]  total_interactions      bin 3: 7 interactions (> threshold)
        1.0,    -- [8]  is_multi_channel        3 channels used → 1
        4.0,    -- [9]  recency_bucket          fresh=4 (last msg ≤ 3 days)
        3.0,    -- [10] engagement_depth        bin 3: 5.95 > 5.0 threshold
        1.0,    -- [11] quotation_sent          quotation sent → 1
        1.0,    -- [12] is_enterprise_deal      base_price ≥ 400000 → 1
        1.0,    -- [13] pipeline_stage          CLOSED → alphabetical label = 1
        1.0,    -- [14] days_in_pipeline        bin 1: 2 days ≤ 5 day threshold
        3.0,    -- [15] pipeline_velocity       bin 3: 3.0 > 0.50 threshold
        3.0,    -- [16] total_price_with_tax    bin 3: 590000 > 300000 threshold
        3.0,    -- [17] consumer_score_tier     > 0.70 → tier 3 (HIGH) ← from A
        3.0,    -- [18] interaction_score_tier  > 0.70 → tier 3 (HIGH) ← from B
        3.0     -- [19] product_quotation_score_tier > 0.70 → tier 3 (HIGH) ← from C
    ])
};


-- ================================================================
-- STEP 8 — Final Summary: Full lead + conversations + messages
-- ================================================================

-- 1. Lead final state
SELECT
    id, name, state, completeness, classification,
    ai_confidence,
    source_channel,
    organisation.name     AS org_name,
    organisation.industry AS industry
FROM lead:hs_test_lead
FETCH organisation;

-- 2. All conversations — channel, sentiment, summary
SELECT
    id,
    channel.name AS channel,
    sentiment,
    summary,
    started_at,
    last_message_at
FROM conversation
WHERE lead = lead:hs_test_lead
ORDER BY started_at ASC
FETCH channel;

-- 3. All messages — grouped by channel, in order
SELECT
    id,
    conversation.channel.name AS channel,
    sender,
    content,
    created_at
FROM message
WHERE conversation IN (
    SELECT VALUE id FROM conversation WHERE lead = lead:hs_test_lead
)
ORDER BY created_at ASC
FETCH conversation;

-- 4. Quotation details
SELECT
    id, quote_id, quotation_no, status, currency,
    subtotal, total_amount, products,
    sent_via, sent_at, accepted_at, feedbackrating
FROM quotation
WHERE lead = lead:hs_test_lead;

-- 5. Product interest
SELECT ->interested_in->product.* AS interested_products
FROM lead:hs_test_lead;


-- ================================================================
-- SCORE PROGRESSION REFERENCE
-- ================================================================
-- Stage                    | consumer | interaction | product_quotation
-- -------------------------|----------|-------------|------------------
-- STEP 0  NEW_LEAD         | low      | low         | medium (enterprise)
-- STEP 1  WhatsApp NEUTRAL | low+     | low+        | medium
-- STEP 2  Email INTERESTED | rising   | rising      | rising
-- STEP 3  Voice CURIOUS    | rising+  | rising+     | rising+ (3ch)
-- STEP 4  SALES_QUAL POSIT | strong   | strong      | strong
-- STEP 5  QUOTATION URGENT | strong+  | strong+     | PEAK jump (sent=1)
-- STEP 6  NEGOT. NEGOTIAT  | high     | high        | high
-- STEP 7  CLOSED SATISFIED | PEAK     | PEAK        | PEAK (all > 0.70)
-- -------------------------|----------|-------------|------------------
-- VALIDATION D  lead_qual  | all tier=3 → lead_qualification > 0.80 HIGH
-- ================================================================

-- ================================================================
-- SENTIMENT COVERAGE CHECKLIST
-- ================================================================
-- Step 1  WhatsApp  → NEUTRAL      ✓
-- Step 2  Email     → INTERESTED   ✓
-- Step 3  Voice     → CURIOUS      ✓
-- Step 4  WhatsApp  → POSITIVE     ✓
-- Step 5  Email     → URGENT       ✓
-- Step 6  Voice     → NEGOTIATING  ✓
-- Step 7  WhatsApp  → SATISFIED    ✓  ← all 7 covered

-- CHANNEL COVERAGE CHECKLIST
-- WhatsApp : Steps 1, 4, 7  (3 messages)  ✓
-- Email    : Steps 2, 5     (2 messages)  ✓
-- Voice    : Steps 3, 6     (2 messages)  ✓  ← all 3 channels covered

-- MESSAGE LENGTH CHECKLIST
-- SHORT  (< 100 chars)  : Steps 1, 6  ✓
-- MEDIUM (100–200 chars): Steps 2, 4  ✓
-- LONG   (> 200 chars)  : Steps 3, 5, 7  ✓
-- ================================================================
