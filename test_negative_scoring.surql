-- ================================================================
-- VITAFI NEGATIVE TESTING SCRIPT
-- ================================================================
-- Purpose : Verify that LOW / negative input signals produce LOW
--           scores across all 4 ML models.
-- Tests   : 20 per model × 4 models = 80 total queries
--
-- What "negative" means per model:
--   consumer_score        → angry/dissatisfied, poor history, no milestone
--   interaction_score     → cold/stale, zero engagement, single channel
--   product_quotation_score → budget product, no quotation, early stage
--   lead_qualification    → all sub-model tiers = 1, cold, no enterprise
--
-- Tier mapping (sub-model scores fed into lead_qualification):
--   tier 1 = LOW   (score < 0.40)
--   tier 2 = MED   (0.40 – 0.70)
--   tier 3 = HIGH  (score > 0.70)
--
-- Server: http://localhost:8000  |  NS: vitasales  |  DB: vitasales
-- ================================================================


-- ════════════════════════════════════════════════════════════════
-- SECTION 1 — consumer_score NEGATIVE TESTS  (NC-01 to NC-20)
-- Features [12]: primary_sentiment, sentiment_score,
--   sentiment_combo_score, intent, message_quality, summary_length,
--   has_action_milestone, stage_velocity, historical_deals_won,
--   is_repeat_customer, historical_avg_sentiment, industry_close_rate
-- Negative signals: ANGRY=0, NEGATIVE=1, DISSATISFIED=2
--   at_risk intent=0, window_shopping=9, no history, poor industry
-- ════════════════════════════════════════════════════════════════

-- NC-01: Pure ANGRY new lead — all worst signals, no history
-- Scenario: Customer angry on first contact, no org history at all
RETURN {
    test: "NC-01 — ANGRY new lead, no org history, worst industry",
    model: "consumer_score",
    expected: "LOW (< 0.20)",
    score: ml::consumer_score<1.0.0>([
        0.0,    -- [0]  primary_sentiment       ANGRY = 0 (worst)
        -1.0,   -- [1]  sentiment_score         angry = -1.0
        0.0,    -- [2]  sentiment_combo_score   stage(0) × -1.0 = 0
        0.0,    -- [3]  intent                  at_risk = 0 (worst)
        3.0,    -- [4]  message_quality         SHORT = 3
        0.0,    -- [5]  summary_length          no summary
        0.0,    -- [6]  has_action_milestone    stage < QUOTATION
        0.0,    -- [7]  stage_velocity          no progress
        0.0,    -- [8]  historical_deals_won    no deals won
        0.0,    -- [9]  is_repeat_customer      not a repeat customer
        -1.0,   -- [10] historical_avg_sentiment worst org history
        0.38    -- [11] industry_close_rate     lowest rate
    ])
};

-- NC-02: Window shopping intent, zero org history
-- Scenario: Browser who never buys, no engagement
RETURN {
    test: "NC-02 — Window shopping, no org history, short message",
    model: "consumer_score",
    expected: "LOW (< 0.20)",
    score: ml::consumer_score<1.0.0>([
        3.0,    -- [0]  primary_sentiment       NEUTRAL = 3
        0.0,    -- [1]  sentiment_score         neutral = 0
        0.0,    -- [2]  sentiment_combo_score   stage(0) × 0 = 0
        9.0,    -- [3]  intent                  window_shopping = 9 (worst)
        3.0,    -- [4]  message_quality         SHORT = 3
        20.0,   -- [5]  summary_length          minimal summary
        0.0,    -- [6]  has_action_milestone    0
        0.0,    -- [7]  stage_velocity          no velocity
        0.0,    -- [8]  historical_deals_won    0
        0.0,    -- [9]  is_repeat_customer      0
        0.0,    -- [10] historical_avg_sentiment neutral history
        0.38    -- [11] industry_close_rate     lowest
    ])
};

-- NC-03: DISSATISFIED at early stage, poor history
-- Scenario: Customer unhappy from the start, low-value org
RETURN {
    test: "NC-03 — DISSATISFIED at MANUAL_FOLLOW_UP, no deals won",
    model: "consumer_score",
    expected: "LOW (< 0.22)",
    score: ml::consumer_score<1.0.0>([
        2.0,    -- [0]  primary_sentiment       DISSATISFIED = 2
        -0.5,   -- [1]  sentiment_score         dissatisfied weight
        -0.5,   -- [2]  sentiment_combo_score   stage(1) × -0.5
        0.0,    -- [3]  intent                  at_risk = 0
        3.0,    -- [4]  message_quality         SHORT = 3
        60.0,   -- [5]  summary_length
        0.0,    -- [6]  has_action_milestone    stage 1 < QUOTATION
        0.33,   -- [7]  stage_velocity          1/3 days
        0.0,    -- [8]  historical_deals_won    0
        0.0,    -- [9]  is_repeat_customer      0
        -0.3,   -- [10] historical_avg_sentiment negative org avg
        0.40    -- [11] industry_close_rate     low
    ])
};

-- NC-04: ANGRY at CLOSED stage (churned deal — worst combo)
-- Scenario: Deal reached CLOSED but customer is furious (contract dispute)
RETURN {
    test: "NC-04 — ANGRY at CLOSED stage, churned deal (combo=-5 clamped)",
    model: "consumer_score",
    expected: "LOW (< 0.25)",
    score: ml::consumer_score<1.0.0>([
        0.0,    -- [0]  primary_sentiment       ANGRY = 0
        -1.0,   -- [1]  sentiment_score         angry = -1.0
        -5.0,   -- [2]  sentiment_combo_score   stage(6) × -1 = -6 → clamped to -5
        0.0,    -- [3]  intent                  at_risk = 0 (churning)
        3.0,    -- [4]  message_quality         SHORT complaint
        80.0,   -- [5]  summary_length
        1.0,    -- [6]  has_action_milestone    reached CLOSED (milestone=1)
        0.24,   -- [7]  stage_velocity          6/25 days
        0.0,    -- [8]  historical_deals_won    no prior deals
        0.0,    -- [9]  is_repeat_customer      0
        -0.5,   -- [10] historical_avg_sentiment org has negative history
        0.40    -- [11] industry_close_rate     low
    ])
};

-- NC-05: NEGATIVE sentiment, window shopping, worst industry
RETURN {
    test: "NC-05 — NEGATIVE sentiment, window_shopping intent, worst industry",
    model: "consumer_score",
    expected: "LOW (< 0.20)",
    score: ml::consumer_score<1.0.0>([
        1.0,    -- [0]  primary_sentiment       NEGATIVE = 1
        -0.8,   -- [1]  sentiment_score
        -0.8,   -- [2]  sentiment_combo_score   stage(1) × -0.8
        9.0,    -- [3]  intent                  window_shopping = 9
        2.0,    -- [4]  message_quality         MEDIUM = 2
        90.0,   -- [5]  summary_length
        0.0,    -- [6]  has_action_milestone    0
        0.33,   -- [7]  stage_velocity
        0.0,    -- [8]  historical_deals_won    0
        0.0,    -- [9]  is_repeat_customer      0
        -0.3,   -- [10] historical_avg_sentiment
        0.38    -- [11] industry_close_rate     worst
    ])
};

-- NC-06: No org data, neutral, zero velocity, new lead
-- Scenario: Completely blank lead — no org, no history, no progress
RETURN {
    test: "NC-06 — No org data, zero velocity, new lead baseline",
    model: "consumer_score",
    expected: "LOW (< 0.20)",
    score: ml::consumer_score<1.0.0>([
        3.0,    -- [0]  primary_sentiment       NEUTRAL = 3
        0.0,    -- [1]  sentiment_score
        0.0,    -- [2]  sentiment_combo_score
        7.0,    -- [3]  intent                  new = 7
        2.0,    -- [4]  message_quality         MEDIUM = 2
        50.0,   -- [5]  summary_length
        0.0,    -- [6]  has_action_milestone    0
        0.0,    -- [7]  stage_velocity
        0.0,    -- [8]  historical_deals_won    0
        0.0,    -- [9]  is_repeat_customer      0
        0.0,    -- [10] historical_avg_sentiment no org history
        0.48    -- [11] industry_close_rate     mid rate
    ])
};

-- NC-07: Window shopping, short message, no summary, poor industry
RETURN {
    test: "NC-07 — Window shopping, no summary, short msg, poor industry",
    model: "consumer_score",
    expected: "LOW (< 0.18)",
    score: ml::consumer_score<1.0.0>([
        3.0,    -- [0]  primary_sentiment       NEUTRAL = 3
        0.0,    -- [1]  sentiment_score
        0.0,    -- [2]  sentiment_combo_score
        9.0,    -- [3]  intent                  window_shopping = 9
        3.0,    -- [4]  message_quality         SHORT = 3
        0.0,    -- [5]  summary_length          no summary
        0.0,    -- [6]  has_action_milestone    0
        0.0,    -- [7]  stage_velocity
        0.0,    -- [8]  historical_deals_won    0
        0.0,    -- [9]  is_repeat_customer      0
        0.30,   -- [10] historical_avg_sentiment poor
        0.38    -- [11] industry_close_rate     worst
    ])
};

-- NC-08: DISSATISFIED, very slow pipeline, no milestone
-- Scenario: Stale deal with unhappy customer, stuck at SALES_FOLLOW_UP
RETURN {
    test: "NC-08 — DISSATISFIED, slow velocity (2/20), stuck at stage 2",
    model: "consumer_score",
    expected: "LOW (< 0.22)",
    score: ml::consumer_score<1.0.0>([
        2.0,    -- [0]  primary_sentiment       DISSATISFIED = 2
        -0.5,   -- [1]  sentiment_score
        -1.0,   -- [2]  sentiment_combo_score   stage(2) × -0.5
        0.0,    -- [3]  intent                  at_risk = 0
        3.0,    -- [4]  message_quality         SHORT = 3
        70.0,   -- [5]  summary_length
        0.0,    -- [6]  has_action_milestone    0
        0.10,   -- [7]  stage_velocity          2/20 = very slow
        0.0,    -- [8]  historical_deals_won    0
        0.0,    -- [9]  is_repeat_customer      0
        0.30,   -- [10] historical_avg_sentiment poor
        0.42    -- [11] industry_close_rate     low
    ])
};

-- NC-09: ANGRY + worst industry + no history + zero velocity
RETURN {
    test: "NC-09 — ANGRY, worst industry (0.38), zero velocity, no history",
    model: "consumer_score",
    expected: "LOW (< 0.20)",
    score: ml::consumer_score<1.0.0>([
        0.0,    -- [0]  primary_sentiment       ANGRY = 0
        -1.0,   -- [1]  sentiment_score
        -2.0,   -- [2]  sentiment_combo_score   stage(2) × -1
        0.0,    -- [3]  intent                  at_risk = 0
        3.0,    -- [4]  message_quality         SHORT = 3
        0.0,    -- [5]  summary_length          no summary
        0.0,    -- [6]  has_action_milestone    0
        0.15,   -- [7]  stage_velocity          slow
        0.0,    -- [8]  historical_deals_won    0
        0.0,    -- [9]  is_repeat_customer      0
        -0.8,   -- [10] historical_avg_sentiment very negative
        0.38    -- [11] industry_close_rate     worst
    ])
};

-- NC-10: DISSATISFIED at QUOTATION stage (likely to lose despite progress)
-- Scenario: Lead progressed to quotation but customer is dissatisfied
RETURN {
    test: "NC-10 — DISSATISFIED at QUOTATION stage, combo=-2.0",
    model: "consumer_score",
    expected: "LOW-MEDIUM (< 0.30)",
    score: ml::consumer_score<1.0.0>([
        2.0,    -- [0]  primary_sentiment       DISSATISFIED = 2
        -0.5,   -- [1]  sentiment_score
        -2.0,   -- [2]  sentiment_combo_score   stage(4) × -0.5
        0.0,    -- [3]  intent                  at_risk = 0
        2.0,    -- [4]  message_quality         MEDIUM = 2
        120.0,  -- [5]  summary_length
        1.0,    -- [6]  has_action_milestone    stage 4 >= QUOTATION → 1
        0.20,   -- [7]  stage_velocity          4/20
        1.0,    -- [8]  historical_deals_won    minimal
        1.0,    -- [9]  is_repeat_customer      1 (but still dissatisfied)
        0.35,   -- [10] historical_avg_sentiment poor
        0.42    -- [11] industry_close_rate     low
    ])
};

-- NC-11: Window shopping, neutral, poor quality, zero history
RETURN {
    test: "NC-11 — Window shopping, NEUTRAL, poor quality, zero history",
    model: "consumer_score",
    expected: "LOW (< 0.18)",
    score: ml::consumer_score<1.0.0>([
        3.0,    -- [0]  primary_sentiment       NEUTRAL = 3
        0.0,    -- [1]  sentiment_score
        0.0,    -- [2]  sentiment_combo_score
        9.0,    -- [3]  intent                  window_shopping = 9
        3.0,    -- [4]  message_quality         SHORT = 3
        15.0,   -- [5]  summary_length          very short
        0.0,    -- [6]  has_action_milestone    0
        0.0,    -- [7]  stage_velocity
        0.0,    -- [8]  historical_deals_won    0
        0.0,    -- [9]  is_repeat_customer      0
        0.20,   -- [10] historical_avg_sentiment very poor
        0.40    -- [11] industry_close_rate     low
    ])
};

-- NC-12: Poor org, NEUTRAL, negative historical sentiment, worst industry
RETURN {
    test: "NC-12 — Poor org, negative avg_sentiment, worst industry close rate",
    model: "consumer_score",
    expected: "LOW (< 0.20)",
    score: ml::consumer_score<1.0.0>([
        3.0,    -- [0]  primary_sentiment       NEUTRAL = 3
        0.0,    -- [1]  sentiment_score
        0.0,    -- [2]  sentiment_combo_score
        7.0,    -- [3]  intent                  new = 7
        2.0,    -- [4]  message_quality         MEDIUM = 2
        40.0,   -- [5]  summary_length
        0.0,    -- [6]  has_action_milestone    0
        0.0,    -- [7]  stage_velocity
        0.0,    -- [8]  historical_deals_won    0
        0.0,    -- [9]  is_repeat_customer      0
        -0.5,   -- [10] historical_avg_sentiment negative history
        0.38    -- [11] industry_close_rate     worst
    ])
};

-- NC-13: At_risk intent, DISSATISFIED, no milestone, slow
RETURN {
    test: "NC-13 — At_risk intent, DISSATISFIED, stage 3, no milestone",
    model: "consumer_score",
    expected: "LOW (< 0.22)",
    score: ml::consumer_score<1.0.0>([
        2.0,    -- [0]  primary_sentiment       DISSATISFIED = 2
        -0.5,   -- [1]  sentiment_score
        -1.5,   -- [2]  sentiment_combo_score   stage(3) × -0.5
        0.0,    -- [3]  intent                  at_risk = 0
        3.0,    -- [4]  message_quality         SHORT = 3
        80.0,   -- [5]  summary_length
        0.0,    -- [6]  has_action_milestone    0
        0.15,   -- [7]  stage_velocity          3/20
        0.0,    -- [8]  historical_deals_won    0
        0.0,    -- [9]  is_repeat_customer      0
        -0.3,   -- [10] historical_avg_sentiment
        0.42    -- [11] industry_close_rate
    ])
};

-- NC-14: NEGATIVE sentiment, very poor historical org, worst industry
RETURN {
    test: "NC-14 — NEGATIVE sentiment, org avg_sentiment=-0.8, worst industry",
    model: "consumer_score",
    expected: "LOW (< 0.20)",
    score: ml::consumer_score<1.0.0>([
        1.0,    -- [0]  primary_sentiment       NEGATIVE = 1
        -0.8,   -- [1]  sentiment_score
        -4.0,   -- [2]  sentiment_combo_score   stage(5) × -0.8
        0.0,    -- [3]  intent                  at_risk = 0
        2.0,    -- [4]  message_quality         MEDIUM = 2
        100.0,  -- [5]  summary_length
        1.0,    -- [6]  has_action_milestone    stage 5 >= QUOTATION → 1
        0.25,   -- [7]  stage_velocity
        0.0,    -- [8]  historical_deals_won    0
        0.0,    -- [9]  is_repeat_customer      0
        -0.8,   -- [10] historical_avg_sentiment very negative org
        0.38    -- [11] industry_close_rate     worst
    ])
};

-- NC-15: ANGRY at NEGOTIATION stage (high churn risk, combo=-5 clamped)
RETURN {
    test: "NC-15 — ANGRY at FOLLOW_UP_NEGOTIATION, combo=-5 (clamped), no history",
    model: "consumer_score",
    expected: "LOW (< 0.22)",
    score: ml::consumer_score<1.0.0>([
        0.0,    -- [0]  primary_sentiment       ANGRY = 0
        -1.0,   -- [1]  sentiment_score
        -5.0,   -- [2]  sentiment_combo_score   stage(5) × -1 = -5 (clamped)
        0.0,    -- [3]  intent                  at_risk = 0
        3.0,    -- [4]  message_quality         SHORT = 3
        50.0,   -- [5]  summary_length
        1.0,    -- [6]  has_action_milestone    stage 5 >= QUOTATION → 1
        0.25,   -- [7]  stage_velocity
        0.0,    -- [8]  historical_deals_won    0
        0.0,    -- [9]  is_repeat_customer      0
        -0.5,   -- [10] historical_avg_sentiment
        0.40    -- [11] industry_close_rate
    ])
};

-- NC-16: No repeat customer, worst industry, DISSATISFIED stage 1
RETURN {
    test: "NC-16 — DISSATISFIED, no repeat, worst industry, stage 1",
    model: "consumer_score",
    expected: "LOW (< 0.20)",
    score: ml::consumer_score<1.0.0>([
        2.0,    -- [0]  primary_sentiment       DISSATISFIED = 2
        -0.5,   -- [1]  sentiment_score
        -0.5,   -- [2]  sentiment_combo_score   stage(1) × -0.5
        0.0,    -- [3]  intent                  at_risk = 0
        2.0,    -- [4]  message_quality         MEDIUM = 2
        100.0,  -- [5]  summary_length
        0.0,    -- [6]  has_action_milestone    0
        0.25,   -- [7]  stage_velocity
        0.0,    -- [8]  historical_deals_won    0
        0.0,    -- [9]  is_repeat_customer      0
        -0.4,   -- [10] historical_avg_sentiment
        0.38    -- [11] industry_close_rate     worst
    ])
};

-- NC-17: Window shopping, no summary, no milestone, no deals, poor industry
RETURN {
    test: "NC-17 — Window shopping, zero summary, zero velocity, zero history",
    model: "consumer_score",
    expected: "LOW (< 0.18)",
    score: ml::consumer_score<1.0.0>([
        3.0, 0.0, 0.0,
        9.0,    -- [3]  intent   window_shopping = 9
        3.0,    -- [4]  quality  SHORT
        0.0,    -- [5]  length   0
        0.0,    -- [6]  milestone 0
        0.0,    -- [7]  velocity 0
        0.0, 0.0, 0.30, 0.38
    ])
};

-- NC-18: ANGRY, very negative historical sentiment, stage 3, no repeat
RETURN {
    test: "NC-18 — ANGRY, org avg_sentiment=-0.9, stage 3 combo=-3",
    model: "consumer_score",
    expected: "LOW (< 0.20)",
    score: ml::consumer_score<1.0.0>([
        0.0,    -- [0]  primary_sentiment       ANGRY = 0
        -1.0,   -- [1]  sentiment_score
        -3.0,   -- [2]  sentiment_combo_score   stage(3) × -1
        0.0,    -- [3]  intent                  at_risk = 0
        3.0,    -- [4]  message_quality         SHORT = 3
        40.0,   -- [5]  summary_length
        0.0,    -- [6]  has_action_milestone    0
        0.10,   -- [7]  stage_velocity          slow
        0.0,    -- [8]  historical_deals_won    0
        0.0,    -- [9]  is_repeat_customer      0
        -0.9,   -- [10] historical_avg_sentiment very negative
        0.38    -- [11] industry_close_rate     worst
    ])
};

-- NC-19: At_risk + NEGATIVE + very slow velocity (1/30)
RETURN {
    test: "NC-19 — At_risk, NEGATIVE, very slow velocity (1/30 days), poor industry",
    model: "consumer_score",
    expected: "LOW (< 0.20)",
    score: ml::consumer_score<1.0.0>([
        1.0,    -- [0]  primary_sentiment       NEGATIVE = 1
        -0.8,   -- [1]  sentiment_score
        -0.8,   -- [2]  sentiment_combo_score   stage(1) × -0.8
        0.0,    -- [3]  intent                  at_risk = 0
        2.0,    -- [4]  message_quality         MEDIUM = 2
        60.0,   -- [5]  summary_length
        0.0,    -- [6]  has_action_milestone    0
        0.03,   -- [7]  stage_velocity          1/30 = very slow
        0.0,    -- [8]  historical_deals_won    0
        0.0,    -- [9]  is_repeat_customer      0
        -0.5,   -- [10] historical_avg_sentiment
        0.42    -- [11] industry_close_rate
    ])
};

-- NC-20: Maximum negative — every feature at its absolute worst
RETURN {
    test: "NC-20 — ALL WORST: ANGRY, at_risk, combo=-5, no history, worst industry",
    model: "consumer_score",
    expected: "VERY LOW (< 0.15)",
    score: ml::consumer_score<1.0.0>([
        0.0,    -- [0]  primary_sentiment       ANGRY = 0
        -1.0,   -- [1]  sentiment_score         -1.0 (worst)
        -5.0,   -- [2]  sentiment_combo_score   clamped minimum
        0.0,    -- [3]  intent                  at_risk = 0 (worst)
        3.0,    -- [4]  message_quality         SHORT = 3
        0.0,    -- [5]  summary_length          0
        0.0,    -- [6]  has_action_milestone    0
        0.0,    -- [7]  stage_velocity          0
        0.0,    -- [8]  historical_deals_won    0 (no deals)
        0.0,    -- [9]  is_repeat_customer      0
        -1.0,   -- [10] historical_avg_sentiment -1.0 (worst)
        0.38    -- [11] industry_close_rate     0.38 (lowest)
    ])
};


-- ════════════════════════════════════════════════════════════════
-- SECTION 2 — interaction_score NEGATIVE TESTS  (NI-01 to NI-20)
-- Features [15]: whatsapp_count, phone_count, email_count,
--   total_interactions, dominant_channel, first_channel,
--   last_channel, is_multi_channel, channel_switch_count,
--   conversation_time_hours, conv_time_bucket, recency_bucket,
--   engagement_depth, channel_x_stage, historical_deals_won
-- Negative: cold/stale recency, zero interactions, no multi-channel,
--   negative engagement_depth, no org history
-- ════════════════════════════════════════════════════════════════

-- NI-01: Zero interactions — completely untouched lead
-- Scenario: Lead created, nobody ever contacted them
RETURN {
    test: "NI-01 — Zero interactions, cold recency, no org history",
    model: "interaction_score",
    expected: "LOW (< 0.50)",
    score: ml::interaction_score<1.0.0>([
        0.0,    -- [0]  whatsapp_count          0
        0.0,    -- [1]  phone_count             0
        0.0,    -- [2]  email_count             0
        0.0,    -- [3]  total_interactions      0
        0.0,    -- [4]  dominant_channel        email=0 (default)
        0.0,    -- [5]  first_channel           email=0
        0.0,    -- [6]  last_channel            email=0
        0.0,    -- [7]  is_multi_channel        0
        0.0,    -- [8]  channel_switch_count    0
        0.0,    -- [9]  conversation_time_hours 0
        4.0,    -- [10] conv_time_bucket        medium_medium=4 (default)
        1.0,    -- [11] recency_bucket          cold = 1
        0.0,    -- [12] engagement_depth        0
        0.0,    -- [13] channel_x_stage         email(0) × stage(0) = 0
        0.0     -- [14] historical_deals_won    0
    ])
};

-- NI-02: Single email, stale (30+ days old), no org history
RETURN {
    test: "NI-02 — Single old email, stale recency, no history",
    model: "interaction_score",
    expected: "LOW (< 0.45)",
    score: ml::interaction_score<1.0.0>([
        0.0,    -- [0]  whatsapp_count          0
        0.0,    -- [1]  phone_count             0
        1.0,    -- [2]  email_count             1 old email
        1.0,    -- [3]  total_interactions      1
        0.0,    -- [4]  dominant_channel        email=0
        0.0,    -- [5]  first_channel           email=0
        0.0,    -- [6]  last_channel            email=0
        0.0,    -- [7]  is_multi_channel        0
        0.0,    -- [8]  channel_switch_count    0
        720.0,  -- [9]  conversation_time_hours 30 days (stale)
        3.0,    -- [10] conv_time_bucket        medium_slow=3
        3.0,    -- [11] recency_bucket          stale = 3
        0.0,    -- [12] engagement_depth        1 × neutral(0) = 0
        0.0,    -- [13] channel_x_stage         email(0) × stage(0) = 0
        0.0     -- [14] historical_deals_won    0
    ])
};

-- NI-03: Stale lead — 90-day-old single email, zero engagement
RETURN {
    test: "NI-03 — 90-day-old email, stale=3, zero engagement depth",
    model: "interaction_score",
    expected: "LOW (< 0.40)",
    score: ml::interaction_score<1.0.0>([
        0.0, 0.0, 1.0, 1.0,
        0.0,    -- [4]  dominant_channel  email=0
        0.0,    -- [5]  first_channel     email=0
        0.0,    -- [6]  last_channel      email=0
        0.0,    -- [7]  is_multi_channel  0
        0.0,    -- [8]  channel_switch    0
        2160.0, -- [9]  conv_time_hours   90 days
        1.0,    -- [10] conv_time_bucket  high_slow=1 (1 interaction, very long)
        3.0,    -- [11] recency_bucket    stale = 3
        0.0,    -- [12] engagement_depth  0
        0.0,    -- [13] channel_x_stage   0
        0.0     -- [14] historical_deals  0
    ])
};

-- NI-04: Zero interactions, stale recency, email source
RETURN {
    test: "NI-04 — Zero interactions, stale recency, email source",
    model: "interaction_score",
    expected: "LOW (< 0.45)",
    score: ml::interaction_score<1.0.0>([
        0.0, 0.0, 0.0, 0.0,
        0.0,    -- [4]  dominant_channel  email=0
        0.0,    -- [5]  first_channel     email=0
        0.0,    -- [6]  last_channel      email=0
        0.0, 0.0, 0.0,
        4.0,    -- [10] conv_time_bucket  medium_medium=4 (default)
        3.0,    -- [11] recency_bucket    stale = 3 (worst)
        0.0, 0.0, 0.0
    ])
};

-- NI-05: Single WhatsApp, cold, NEGATIVE engagement depth
-- Scenario: One WhatsApp contact with angry customer = negative engagement
RETURN {
    test: "NI-05 — Single WhatsApp, cold recency, NEGATIVE engagement_depth=-1.0",
    model: "interaction_score",
    expected: "LOW (< 0.45)",
    score: ml::interaction_score<1.0.0>([
        1.0,    -- [0]  whatsapp_count    1
        0.0, 0.0,
        1.0,    -- [3]  total_interactions 1
        2.0,    -- [4]  dominant_channel  whatsapp=2
        2.0,    -- [5]  first_channel     whatsapp=2
        2.0,    -- [6]  last_channel      whatsapp=2
        0.0,    -- [7]  is_multi_channel  0
        0.0,    -- [8]  channel_switch    0
        0.5,    -- [9]  conv_time_hours   30 min
        4.0,    -- [10] conv_time_bucket  bucket=4
        1.0,    -- [11] recency_bucket    cold = 1
        -1.0,   -- [12] engagement_depth  1 × (-1.0) ANGRY weight
        0.0,    -- [13] channel_x_stage   whatsapp(2) × stage(0) = 0
        0.0     -- [14] historical_deals  0
    ])
};

-- NI-06: Email only, 20-day-old contact, stale, no org history
RETURN {
    test: "NI-06 — Email only, 20-day-old (stale=3), no multi-channel, no history",
    model: "interaction_score",
    expected: "LOW (< 0.42)",
    score: ml::interaction_score<1.0.0>([
        0.0, 0.0, 2.0, 2.0,
        0.0,    -- [4]  dominant_channel  email=0
        0.0,    -- [5]  first_channel     email=0
        0.0,    -- [6]  last_channel      email=0
        0.0,    -- [7]  is_multi_channel  0
        0.0,    -- [8]  channel_switch    0
        480.0,  -- [9]  conv_time_hours   20 days
        3.0,    -- [10] conv_time_bucket  medium_slow=3
        3.0,    -- [11] recency_bucket    stale = 3
        0.0,    -- [12] engagement_depth  neutral (0)
        0.0,    -- [13] channel_x_stage   email(0) × any_stage = 0
        0.0     -- [14] historical_deals  0
    ])
};

-- NI-07: 3-channel attempt but all cold, zero engagement
-- Scenario: Team tried all channels but customer never responded
RETURN {
    test: "NI-07 — 3 channels tried but cold recency, zero engagement depth",
    model: "interaction_score",
    expected: "LOW-MEDIUM (< 0.52)",
    score: ml::interaction_score<1.0.0>([
        1.0, 1.0, 1.0,
        3.0,    -- [3]  total_interactions  3 (but all unresponded)
        2.0,    -- [4]  dominant_channel    whatsapp=2
        2.0,    -- [5]  first_channel       whatsapp=2
        0.0,    -- [6]  last_channel        email=0
        1.0,    -- [7]  is_multi_channel    1
        2.0,    -- [8]  channel_switch      3-1=2
        360.0,  -- [9]  conv_time_hours     15 days spread
        3.0,    -- [10] conv_time_bucket    medium_slow=3
        1.0,    -- [11] recency_bucket      cold = 1 (no recent response)
        0.0,    -- [12] engagement_depth    3 × neutral(0) = 0
        0.0,    -- [13] channel_x_stage     whatsapp(2) × stage(0) = 0
        0.0     -- [14] historical_deals    0
    ])
};

-- NI-08: Zero interactions, stale, phone source (low-value channel)
RETURN {
    test: "NI-08 — Zero interactions, stale recency, phone/email source",
    model: "interaction_score",
    expected: "LOW (< 0.43)",
    score: ml::interaction_score<1.0.0>([
        0.0, 0.0, 0.0, 0.0,
        1.0,    -- [4]  dominant_channel  phone=1
        1.0,    -- [5]  first_channel     phone=1
        1.0,    -- [6]  last_channel      phone=1
        0.0, 0.0, 0.0,
        4.0,    -- [10] conv_time_bucket  default=4
        3.0,    -- [11] recency_bucket    stale = 3
        0.0, 0.0, 0.0
    ])
};

-- NI-09: 1 phone interaction, 30-day-old, stale, DISSATISFIED engagement
RETURN {
    test: "NI-09 — Single phone, stale=3, 30-day-old, negative engagement=-0.5",
    model: "interaction_score",
    expected: "LOW (< 0.40)",
    score: ml::interaction_score<1.0.0>([
        0.0, 1.0, 0.0,
        1.0,    -- [3]  total_interactions  1
        1.0,    -- [4]  dominant_channel    phone=1
        1.0,    -- [5]  first_channel       phone=1
        1.0,    -- [6]  last_channel        phone=1
        0.0, 0.0,
        720.0,  -- [9]  conv_time_hours     30 days
        1.0,    -- [10] conv_time_bucket    high_slow=1
        3.0,    -- [11] recency_bucket      stale = 3
        -0.5,   -- [12] engagement_depth    1 × (-0.5) DISSATISFIED
        0.0,    -- [13] channel_x_stage     phone(1) × stage(0) = 0
        0.0     -- [14] historical_deals    0
    ])
};

-- NI-10: Negative engagement depth — angry customer, even if multi-channel
RETURN {
    test: "NI-10 — Multi-channel but ANGRY engagement depth=-3.0 (3 × -1.0)",
    model: "interaction_score",
    expected: "LOW-MEDIUM (< 0.48)",
    score: ml::interaction_score<1.0.0>([
        1.0, 1.0, 1.0,
        3.0,    -- [3]  total_interactions  3
        2.0,    -- [4]  dominant_channel    whatsapp=2
        2.0,    -- [5]  first_channel       whatsapp=2
        0.0,    -- [6]  last_channel        email=0
        1.0,    -- [7]  is_multi_channel    1
        2.0,    -- [8]  channel_switch      2
        72.0,   -- [9]  conv_time_hours     3 days
        1.0,    -- [10] conv_time_bucket    medium_slow=1
        2.0,    -- [11] recency_bucket      fresh=2 (recent but angry)
        -3.0,   -- [12] engagement_depth    3 × (-1.0) ANGRY = -3.0
        0.0,    -- [13] channel_x_stage     whatsapp(2) × stage(0) = 0
        0.0     -- [14] historical_deals    0
    ])
};

-- NI-11: High channel switches but zero total engagement value
RETURN {
    test: "NI-11 — 3 channels, 3 switches but zero engagement depth (neutral customer)",
    model: "interaction_score",
    expected: "LOW-MEDIUM (< 0.52)",
    score: ml::interaction_score<1.0.0>([
        1.0, 1.0, 1.0,
        3.0,    -- [3]  total_interactions  3
        1.0,    -- [4]  dominant_channel    phone=1
        2.0,    -- [5]  first_channel       whatsapp=2
        0.0,    -- [6]  last_channel        email=0
        1.0,    -- [7]  is_multi_channel    1
        2.0,    -- [8]  channel_switch      3-1=2
        48.0,   -- [9]  conv_time_hours     2 days
        2.0,    -- [10] conv_time_bucket    medium_fast=2
        1.0,    -- [11] recency_bucket      cold = 1
        0.0,    -- [12] engagement_depth    3 × neutral(0) = 0
        0.0,    -- [13] channel_x_stage     phone(1) × stage(0) = 0
        0.0     -- [14] historical_deals    0
    ])
};

-- NI-12: Phone only, cold, zero deals won
RETURN {
    test: "NI-12 — Phone only, cold recency, zero org history",
    model: "interaction_score",
    expected: "LOW (< 0.48)",
    score: ml::interaction_score<1.0.0>([
        0.0, 1.0, 0.0,
        1.0,    -- [3]  total_interactions  1
        1.0,    -- [4]  dominant_channel    phone=1
        1.0,    -- [5]  first_channel       phone=1
        1.0,    -- [6]  last_channel        phone=1
        0.0, 0.0,
        0.5,    -- [9]  conv_time_hours
        4.0,    -- [10] conv_time_bucket    bucket=4
        1.0,    -- [11] recency_bucket      cold = 1
        0.0,    -- [12] engagement_depth    0
        0.0,    -- [13] channel_x_stage     phone(1) × stage(0) = 0
        0.0     -- [14] historical_deals    0
    ])
};

-- NI-13: Very long conversation span but single interaction (stale account)
RETURN {
    test: "NI-13 — 1 email across 60-day span, stale, no deals won",
    model: "interaction_score",
    expected: "LOW (< 0.40)",
    score: ml::interaction_score<1.0.0>([
        0.0, 0.0, 1.0, 1.0,
        0.0,    -- [4]  dominant_channel    email=0
        0.0,    -- [5]  first_channel       email=0
        0.0,    -- [6]  last_channel        email=0
        0.0, 0.0,
        1440.0, -- [9]  conv_time_hours     60 days!
        1.0,    -- [10] conv_time_bucket    high_slow=1
        3.0,    -- [11] recency_bucket      stale = 3
        0.0,    -- [12] engagement_depth    0
        0.0,    -- [13] channel_x_stage     0
        0.0     -- [14] historical_deals    0
    ])
};

-- NI-14: Cold recency + email only + no org history
RETURN {
    test: "NI-14 — Email only, cold=1, very old, no org history",
    model: "interaction_score",
    expected: "LOW (< 0.42)",
    score: ml::interaction_score<1.0.0>([
        0.0, 0.0, 1.0, 1.0,
        0.0,    -- [4]  dominant_channel    email=0
        0.0, 0.0,
        0.0, 0.0,
        360.0,  -- [9]  conv_time_hours     15 days
        3.0,    -- [10] conv_time_bucket    medium_slow=3
        1.0,    -- [11] recency_bucket      cold = 1
        0.0,    -- [12] engagement_depth    0
        0.0, 0.0
    ])
};

-- NI-15: 3 stale email interactions with negative engagement
RETURN {
    test: "NI-15 — 3 stale emails, negative engagement (-1.5), no history",
    model: "interaction_score",
    expected: "LOW (< 0.40)",
    score: ml::interaction_score<1.0.0>([
        0.0, 0.0, 3.0, 3.0,
        0.0,    -- [4]  dominant_channel    email=0
        0.0, 0.0,
        0.0, 0.0,
        480.0,  -- [9]  conv_time_hours     20 days
        3.0,    -- [10] conv_time_bucket    medium_slow=3
        3.0,    -- [11] recency_bucket      stale = 3
        -1.5,   -- [12] engagement_depth    3 × (-0.5) DISSATISFIED
        0.0,    -- [13] channel_x_stage     email × stage(0) = 0
        0.0     -- [14] historical_deals    0
    ])
};

-- NI-16: Low org history, single email, cold recency
RETURN {
    test: "NI-16 — Single email, cold=1, zero org deals won",
    model: "interaction_score",
    expected: "LOW (< 0.43)",
    score: ml::interaction_score<1.0.0>([
        0.0, 0.0, 1.0, 1.0,
        0.0, 0.0, 0.0,
        0.0, 0.0,
        168.0,  -- [9]  conv_time_hours     7 days
        3.0,    -- [10] conv_time_bucket    medium_slow=3
        1.0,    -- [11] recency_bucket      cold = 1
        0.0,    -- [12] engagement_depth    0
        0.0,
        0.0     -- [14] historical_deals    0
    ])
};

-- NI-17: No engagement depth, cold, zero org history, email source
RETURN {
    test: "NI-17 — Zero engagement depth, cold=1, email source, no deals",
    model: "interaction_score",
    expected: "LOW (< 0.45)",
    score: ml::interaction_score<1.0.0>([
        0.0, 0.0, 1.0, 1.0,
        0.0, 0.0, 0.0,
        0.0, 0.0,
        2.0,    -- [9]  conv_time_hours     2 hours
        4.0,    -- [10] conv_time_bucket    medium_medium=4
        1.0,    -- [11] recency_bucket      cold = 1
        0.0,    -- [12] engagement_depth    0
        0.0,
        0.0     -- [14] historical_deals    0
    ])
};

-- NI-18: 2 stale emails + negative engagement (DISSATISFIED)
RETURN {
    test: "NI-18 — 2 stale emails, stale=3, engagement=-1.0, no deals",
    model: "interaction_score",
    expected: "LOW (< 0.38)",
    score: ml::interaction_score<1.0.0>([
        0.0, 0.0, 2.0, 2.0,
        0.0, 0.0, 0.0,
        0.0, 0.0,
        480.0,  -- [9]  conv_time_hours     20 days
        3.0,    -- [10] conv_time_bucket    medium_slow=3
        3.0,    -- [11] recency_bucket      stale = 3
        -1.0,   -- [12] engagement_depth    2 × (-0.5) DISSATISFIED
        0.0, 0.0
    ])
};

-- NI-19: Maximum staleness — old, negative engagement, no history
RETURN {
    test: "NI-19 — 90-day-old email, stale=3, negative engagement=-1, no deals",
    model: "interaction_score",
    expected: "VERY LOW (< 0.35)",
    score: ml::interaction_score<1.0.0>([
        0.0, 0.0, 1.0, 1.0,
        0.0, 0.0, 0.0,
        0.0, 0.0,
        2160.0, -- [9]  conv_time_hours     90 days (ancient)
        1.0,    -- [10] conv_time_bucket    high_slow=1
        3.0,    -- [11] recency_bucket      stale = 3 (worst)
        -1.0,   -- [12] engagement_depth    angry weight
        0.0,
        0.0     -- [14] historical_deals    0
    ])
};

-- NI-20: All-zero or worst — maximum negative interaction scenario
RETURN {
    test: "NI-20 — ALL WORST: zero interactions, stale=3, negative depth, no deals",
    model: "interaction_score",
    expected: "VERY LOW (< 0.35)",
    score: ml::interaction_score<1.0.0>([
        0.0,    -- [0]  whatsapp_count       0
        0.0,    -- [1]  phone_count          0
        0.0,    -- [2]  email_count          0
        0.0,    -- [3]  total_interactions   0
        0.0,    -- [4]  dominant_channel     email=0 (weakest)
        0.0,    -- [5]  first_channel        email=0
        0.0,    -- [6]  last_channel         email=0
        0.0,    -- [7]  is_multi_channel     0
        0.0,    -- [8]  channel_switch       0
        0.0,    -- [9]  conv_time_hours      0
        4.0,    -- [10] conv_time_bucket     medium_medium=4 (default)
        3.0,    -- [11] recency_bucket       stale = 3 (worst)
        0.0,    -- [12] engagement_depth     0
        0.0,    -- [13] channel_x_stage      0
        0.0     -- [14] historical_deals_won 0 (worst)
    ])
};


-- ════════════════════════════════════════════════════════════════
-- SECTION 3 — product_quotation_score NEGATIVE TESTS (NP-01..20)
-- Features [17 — reference format]:
--   product_type, product_complexity, product_base_price,
--   product_tax_rate, price_tier, capacity_tons, capacity_bin,
--   product_x_capacity, total_price_with_tax, capacity_price_ratio,
--   quotation_sent, is_enterprise_deal, industry_close_rate,
--   pipeline_stage, is_repeat_customer, days_in_pipeline,
--   pipeline_velocity
-- Negative: budget product, no quotation, early stage, poor industry
-- ════════════════════════════════════════════════════════════════

-- NP-01: Budget portable unit, no quotation, new lead, worst industry
RETURN {
    test: "NP-01 — Portable unit ₹5,000, no quotation, NEW_LEAD, worst industry",
    model: "product_quotation_score",
    expected: "LOW (< 0.35)",
    score: ml::product_quotation_score<1.0.0>([
        7.0,        -- [0]  product_type       portable=7
        1.0,        -- [1]  product_complexity low
        5000.0,     -- [2]  product_base_price ₹5,000 (budget)
        18.0,       -- [3]  product_tax_rate
        2.0,        -- [4]  price_tier         low=2
        0.5,        -- [5]  capacity_tons      very small
        0.0,        -- [6]  capacity_bin       1-5T=0
        35.0,       -- [7]  product_x_capacity 7×5+0=35
        5900.0,     -- [8]  total_price_with_tax 5000×1.18
        0.0000847,  -- [9]  capacity_price_ratio 0.5/5900
        0.0,        -- [10] quotation_sent     NOT sent
        0.0,        -- [11] is_enterprise_deal NOT enterprise (<400k)
        0.38,       -- [12] industry_close_rate worst
        0.0,        -- [13] pipeline_stage     NEW_LEAD=0
        0.0,        -- [14] is_repeat_customer 0
        1.0,        -- [15] days_in_pipeline   1 day
        0.0         -- [16] pipeline_velocity  0
    ])
};

-- NP-02: Economy product, no quotation, poor industry, no repeat
RETURN {
    test: "NP-02 — Economy ₹15,000, no quotation, stage=0, no repeat customer",
    model: "product_quotation_score",
    expected: "LOW (< 0.35)",
    score: ml::product_quotation_score<1.0.0>([
        2.0,        -- [0]  product_type       economy=2
        1.0,        -- [1]  product_complexity
        15000.0,    -- [2]  product_base_price  ₹15,000
        18.0,
        2.0,        -- [4]  price_tier         low=2
        2.0,        -- [5]  capacity_tons
        0.0,        -- [6]  capacity_bin       1-5T=0
        10.0,       -- [7]  product_x_capacity 2×5+0=10
        17700.0,    -- [8]  total_price_with_tax
        0.000113,   -- [9]  capacity_price_ratio
        0.0,        -- [10] quotation_sent     0
        0.0,        -- [11] is_enterprise_deal 0
        0.38,       -- [12] industry_close_rate worst
        0.0,        -- [13] pipeline_stage     0
        0.0,        -- [14] is_repeat_customer 0
        1.0,        -- [15] days_in_pipeline
        0.0         -- [16] pipeline_velocity  0
    ])
};

-- NP-03: No quotation, 60-day stale pipeline, zero velocity
RETURN {
    test: "NP-03 — Standard product, 60-day stale pipeline, zero velocity, no quotation",
    model: "product_quotation_score",
    expected: "LOW (< 0.40)",
    score: ml::product_quotation_score<1.0.0>([
        10.0, 1.0, 50000.0, 18.0, 2.0, 5.0, 0.0, 50.0,
        59000.0, 0.0000847,
        0.0,        -- [10] quotation_sent     0
        0.0,        -- [11] is_enterprise_deal 0
        0.42,       -- [12] industry_close_rate
        0.0,        -- [13] pipeline_stage     0
        0.0,        -- [14] is_repeat_customer 0
        60.0,       -- [15] days_in_pipeline   60 days (stale!)
        0.0         -- [16] pipeline_velocity  0/60 = 0
    ])
};

-- NP-04: Very slow pipeline velocity (1/30), non-enterprise, no quotation
RETURN {
    test: "NP-04 — Slow velocity 1/30, non-enterprise, no quotation",
    model: "product_quotation_score",
    expected: "LOW (< 0.40)",
    score: ml::product_quotation_score<1.0.0>([
        4.0,        -- [0]  product_type   industrial=4
        2.0, 75000.0, 18.0, 2.0, 5.0, 0.0,
        20.0,       -- [7]  product_x_capacity 4×5+0=20
        88500.0, 0.0000565,
        0.0,        -- [10] quotation_sent     0
        0.0,        -- [11] is_enterprise_deal 0
        0.48,       -- [12] industry_close_rate mid
        1.0,        -- [13] pipeline_stage     MANUAL_FOLLOW_UP=1
        0.0,        -- [14] is_repeat_customer 0
        30.0,       -- [15] days_in_pipeline   30 days
        0.033       -- [16] pipeline_velocity  1/30
    ])
};

-- NP-05: Non-enterprise, worst industry, no repeat, no quotation, new lead
RETURN {
    test: "NP-05 — Non-enterprise, worst industry (0.38), no repeat, no quotation",
    model: "product_quotation_score",
    expected: "LOW (< 0.35)",
    score: ml::product_quotation_score<1.0.0>([
        10.0, 1.0, 50000.0, 18.0, 2.0, 5.0, 0.0, 50.0,
        59000.0, 0.0000847,
        0.0,        -- [10] quotation_sent     0
        0.0,        -- [11] is_enterprise_deal 0
        0.38,       -- [12] industry_close_rate WORST
        0.0,        -- [13] pipeline_stage     0
        0.0,        -- [14] is_repeat_customer 0
        1.0, 0.0
    ])
};

-- NP-06: Portable unit (cheapest product type), no quotation
RETURN {
    test: "NP-06 — Portable ₹8,000, no enterprise, no quotation, no repeat",
    model: "product_quotation_score",
    expected: "LOW (< 0.35)",
    score: ml::product_quotation_score<1.0.0>([
        7.0,        -- [0]  product_type   portable=7
        1.0, 8000.0, 18.0, 2.0, 1.0, 0.0,
        35.0,       -- [7]  7×5+0=35
        9440.0, 0.000106,
        0.0,        -- [10] quotation_sent     0
        0.0,        -- [11] is_enterprise_deal 0
        0.40,       -- [12] industry_close_rate low
        0.0,        -- [13] pipeline_stage     0
        0.0,        -- [14] is_repeat_customer 0
        1.0, 0.0
    ])
};

-- NP-07: Economy product, no enterprise, stale pipeline, low velocity
RETURN {
    test: "NP-07 — Economy product, stale 45-day pipeline, low velocity 0.044",
    model: "product_quotation_score",
    expected: "LOW (< 0.40)",
    score: ml::product_quotation_score<1.0.0>([
        2.0, 1.0, 12000.0, 18.0, 2.0, 1.5, 0.0,
        10.0,       -- [7]  2×5+0=10
        14160.0, 0.000106,
        0.0,        -- [10] quotation_sent     0
        0.0,        -- [11] is_enterprise_deal 0
        0.42,       -- [12] industry_close_rate
        2.0,        -- [13] pipeline_stage     SALES_FOLLOW_UP=2
        0.0,        -- [14] is_repeat_customer 0
        45.0,       -- [15] days_in_pipeline   45 days stale
        0.044       -- [16] pipeline_velocity  2/45
    ])
};

-- NP-08: Standard product, 90-day stale pipeline, no quotation
RETURN {
    test: "NP-08 — Standard ₹75,000, 90-day stale, no quotation, velocity=0.011",
    model: "product_quotation_score",
    expected: "LOW (< 0.38)",
    score: ml::product_quotation_score<1.0.0>([
        10.0, 1.5, 75000.0, 18.0, 2.0, 5.0, 0.0, 50.0,
        88500.0, 0.0000565,
        0.0,        -- [10] quotation_sent     0
        0.0,        -- [11] is_enterprise_deal 0
        0.48,       -- [12] industry_close_rate
        1.0,        -- [13] pipeline_stage     1
        1.0,        -- [14] is_repeat_customer 1 (even repeat fails with stale)
        90.0,       -- [15] days_in_pipeline   90 days very stale!
        0.011       -- [16] pipeline_velocity  1/90
    ])
};

-- NP-09: Small capacity, budget price, non-enterprise, no quotation
RETURN {
    test: "NP-09 — Small portable ₹6,000, 0.5T, non-enterprise, no quotation",
    model: "product_quotation_score",
    expected: "LOW (< 0.35)",
    score: ml::product_quotation_score<1.0.0>([
        7.0, 1.0, 6000.0, 18.0, 2.0, 0.5, 0.0,
        35.0,       -- [7]  7×5+0=35
        7080.0, 0.0000706,
        0.0,        -- [10] quotation_sent     0
        0.0,        -- [11] is_enterprise_deal 0
        0.40,       -- [12] industry_close_rate
        0.0,        -- [13] pipeline_stage     0
        0.0,        -- [14] is_repeat_customer 0
        2.0, 0.0
    ])
};

-- NP-10: Economy product, NEW_LEAD, no quotation, non-enterprise
RETURN {
    test: "NP-10 — Economy ₹20,000, NEW_LEAD, no quotation, non-enterprise",
    model: "product_quotation_score",
    expected: "LOW (< 0.38)",
    score: ml::product_quotation_score<1.0.0>([
        2.0, 1.0, 20000.0, 18.0, 2.0, 2.0, 0.0,
        10.0,       -- [7]  2×5+0=10
        23600.0, 0.0000847,
        0.0,        -- [10] quotation_sent     0
        0.0,        -- [11] is_enterprise_deal 0
        0.42,       -- [12] industry_close_rate
        0.0,        -- [13] pipeline_stage     0
        0.0,        -- [14] is_repeat_customer 0
        1.0, 0.0
    ])
};

-- NP-11: Modular product, slow velocity 0.044, no quotation, non-enterprise
RETURN {
    test: "NP-11 — Modular ₹80,000, slow velocity 2/45, no quotation",
    model: "product_quotation_score",
    expected: "LOW (< 0.40)",
    score: ml::product_quotation_score<1.0.0>([
        5.0,        -- [0]  product_type   modular=5
        2.0, 80000.0, 18.0, 2.0,
        8.0,        -- [5]  capacity_tons  8T
        4.0,        -- [6]  capacity_bin   6-10T=4
        29.0,       -- [7]  5×5+4=29
        94400.0, 0.0000847,
        0.0,        -- [10] quotation_sent     0
        0.0,        -- [11] is_enterprise_deal 0
        0.44,       -- [12] industry_close_rate
        2.0,        -- [13] pipeline_stage     2
        0.0,        -- [14] is_repeat_customer 0
        45.0,       -- [15] days_in_pipeline
        0.044       -- [16] pipeline_velocity
    ])
};

-- NP-12: Budget product, worst industry, no repeat
RETURN {
    test: "NP-12 — Portable ₹5,000, worst industry (0.38), no repeat, no quotation",
    model: "product_quotation_score",
    expected: "LOW (< 0.33)",
    score: ml::product_quotation_score<1.0.0>([
        7.0, 1.0, 5000.0, 18.0, 2.0, 0.5, 0.0,
        35.0, 5900.0, 0.0000847,
        0.0,        -- [10] quotation_sent     0
        0.0,        -- [11] is_enterprise_deal 0
        0.38,       -- [12] industry_close_rate WORST
        0.0,        -- [13] pipeline_stage     0
        0.0,        -- [14] is_repeat_customer 0
        1.0, 0.0
    ])
};

-- NP-13: Non-enterprise, no quotation, 45-day stale, no repeat
RETURN {
    test: "NP-13 — Non-enterprise ₹60,000, 45-day stale, no quotation, no repeat",
    model: "product_quotation_score",
    expected: "LOW (< 0.38)",
    score: ml::product_quotation_score<1.0.0>([
        10.0, 1.0, 60000.0, 18.0, 2.0, 5.0, 0.0, 50.0,
        70800.0, 0.0000706,
        0.0,        -- [10] quotation_sent     0
        0.0,        -- [11] is_enterprise_deal 0
        0.42,       -- [12] industry_close_rate
        0.0,        -- [13] pipeline_stage     0
        0.0,        -- [14] is_repeat_customer 0
        45.0,       -- [15] days_in_pipeline
        0.0         -- [16] pipeline_velocity  0
    ])
};

-- NP-14: Very long pipeline (120 days), near-zero velocity, non-enterprise
RETURN {
    test: "NP-14 — 120-day stale pipeline, velocity=0.008, non-enterprise",
    model: "product_quotation_score",
    expected: "LOW (< 0.38)",
    score: ml::product_quotation_score<1.0.0>([
        4.0, 2.0, 95000.0, 18.0, 2.0, 7.0,
        4.0,        -- [6]  capacity_bin   6-10T=4
        24.0,       -- [7]  4×5+4=24
        112100.0, 0.0000624,
        0.0,        -- [10] quotation_sent     0
        0.0,        -- [11] is_enterprise_deal 0
        0.44,
        1.0,        -- [13] pipeline_stage     1
        0.0,        -- [14] is_repeat_customer 0
        120.0,      -- [15] days_in_pipeline   120 days very stale
        0.008       -- [16] pipeline_velocity  1/120
    ])
};

-- NP-15: Portable cooler, non-enterprise, no quotation, no repeat
RETURN {
    test: "NP-15 — Portable cooler ₹7,500, non-enterprise, no quotation, no repeat",
    model: "product_quotation_score",
    expected: "LOW (< 0.35)",
    score: ml::product_quotation_score<1.0.0>([
        7.0, 1.0, 7500.0, 18.0, 2.0, 1.0, 0.0,
        35.0, 8850.0, 0.000113,
        0.0,        -- [10] quotation_sent     0
        0.0,        -- [11] is_enterprise_deal 0
        0.40,       -- [12] industry_close_rate
        0.0,        -- [13] pipeline_stage     0
        0.0,        -- [14] is_repeat_customer 0
        3.0, 0.0
    ])
};

-- NP-16: All worst product signals + worst org + no quotation + early stage
RETURN {
    test: "NP-16 — All worst product: portable ₹5,000, worst industry, no repeat",
    model: "product_quotation_score",
    expected: "VERY LOW (< 0.30)",
    score: ml::product_quotation_score<1.0.0>([
        7.0, 1.0, 5000.0, 18.0, 2.0, 0.5, 0.0,
        35.0, 5900.0, 0.0000847,
        0.0,        -- [10] quotation_sent     0
        0.0,        -- [11] is_enterprise_deal 0
        0.38,       -- [12] industry_close_rate WORST
        0.0,        -- [13] pipeline_stage     0
        0.0,        -- [14] is_repeat_customer 0
        1.0, 0.0
    ])
};

-- NP-17: Economy product, stage=0, no enterprise, worst industry, no repeat
RETURN {
    test: "NP-17 — Economy ₹10,000, stage=0, no enterprise, worst industry",
    model: "product_quotation_score",
    expected: "VERY LOW (< 0.30)",
    score: ml::product_quotation_score<1.0.0>([
        2.0, 1.0, 10000.0, 18.0, 2.0, 1.0, 0.0,
        10.0, 11800.0, 0.0000847,
        0.0,        -- [10] quotation_sent     0
        0.0,        -- [11] is_enterprise_deal 0
        0.38,       -- [12] industry_close_rate WORST
        0.0,        -- [13] pipeline_stage     0
        0.0,        -- [14] is_repeat_customer 0
        1.0, 0.0
    ])
};

-- NP-18: Economy ₹8,000, worst close rate, no repeat, no enterprise
RETURN {
    test: "NP-18 — Economy ₹8,000, worst close rate, no quotation, no enterprise",
    model: "product_quotation_score",
    expected: "VERY LOW (< 0.30)",
    score: ml::product_quotation_score<1.0.0>([
        2.0, 1.0, 8000.0, 18.0, 2.0, 0.8, 0.0,
        10.0, 9440.0, 0.0000847,
        0.0, 0.0, 0.38,
        0.0, 0.0, 1.0, 0.0
    ])
};

-- NP-19: Budget product, 120-day stale, worst industry, no enterprise, no quotation
RETURN {
    test: "NP-19 — Budget ₹5,000, 120-day stale, worst industry, zero velocity",
    model: "product_quotation_score",
    expected: "VERY LOW (< 0.28)",
    score: ml::product_quotation_score<1.0.0>([
        7.0, 1.0, 5000.0, 18.0, 2.0, 0.5, 0.0,
        35.0, 5900.0, 0.0000847,
        0.0,        -- [10] quotation_sent     0
        0.0,        -- [11] is_enterprise_deal 0
        0.38,       -- [12] industry_close_rate WORST
        0.0,        -- [13] pipeline_stage     0
        0.0,        -- [14] is_repeat_customer 0
        120.0,      -- [15] days_in_pipeline   120 days stale
        0.0         -- [16] pipeline_velocity  0
    ])
};

-- NP-20: Maximum negative — all lowest possible inputs
RETURN {
    test: "NP-20 — ALL WORST: ₹1,000 economy, zero velocity, worst industry, no quotation",
    model: "product_quotation_score",
    expected: "VERY LOW (< 0.25)",
    score: ml::product_quotation_score<1.0.0>([
        2.0,        -- [0]  product_type       economy=2
        1.0,        -- [1]  product_complexity 1.0 (lowest)
        1000.0,     -- [2]  product_base_price ₹1,000 (absolute minimum)
        0.0,        -- [3]  product_tax_rate   0% (unusual but minimum)
        2.0,        -- [4]  price_tier         low=2
        0.1,        -- [5]  capacity_tons      0.1T (minimum)
        0.0,        -- [6]  capacity_bin       1-5T=0
        10.0,       -- [7]  product_x_capacity 2×5+0=10
        1000.0,     -- [8]  total_price_with_tax (no tax applied)
        0.0001,     -- [9]  capacity_price_ratio 0.1/1000
        0.0,        -- [10] quotation_sent     NOT sent
        0.0,        -- [11] is_enterprise_deal NOT enterprise
        0.38,       -- [12] industry_close_rate WORST
        0.0,        -- [13] pipeline_stage     NEW_LEAD=0
        0.0,        -- [14] is_repeat_customer 0
        1.0,        -- [15] days_in_pipeline   1 day
        0.0         -- [16] pipeline_velocity  0
    ])
};


-- ════════════════════════════════════════════════════════════════
-- SECTION 4 — lead_qualification NEGATIVE TESTS (NL-01..20)
-- Features [20 — all IQR-binned]:
--   has_action_milestone, stage_velocity(bin), historical_deals_won(bin),
--   is_repeat_customer, industry_close_rate(bin), historical_avg_sentiment(bin),
--   intent(bin), total_interactions(bin), is_multi_channel, recency_bucket,
--   engagement_depth(bin), quotation_sent, is_enterprise_deal,
--   pipeline_stage(alpha), days_in_pipeline(bin), pipeline_velocity(bin),
--   total_price_with_tax(bin), consumer_score_tier, interaction_score_tier,
--   product_quotation_score_tier
-- Negative: all sub-model tiers=1, cold recency, no milestone, no quotation
-- pipeline_stage alphabetical: CLOSED=1, FOLLOW_UP=2, MANUAL=3, NEW_LEAD=4
-- ════════════════════════════════════════════════════════════════

-- NL-01: All worst — all flags=0, all bins=1, all tiers=1
-- The absolute worst-case lead_qualification scenario
RETURN {
    test: "NL-01 — ALL WORST: all tiers=1, all bins=1, all flags=0",
    model: "lead_qualification",
    expected: "VERY LOW (< 0.10)",
    score: ml::lead_qualification<1.0.0>([
        0.0,    -- [0]  has_action_milestone    0 (no quotation reached)
        1.0,    -- [1]  stage_velocity          bin 1 (slow)
        1.0,    -- [2]  historical_deals_won    bin 1 (no deals)
        0.0,    -- [3]  is_repeat_customer      0
        1.0,    -- [4]  industry_close_rate     bin 1 (worst industry)
        1.0,    -- [5]  historical_avg_sentiment bin 1 (negative org history)
        1.0,    -- [6]  intent                  bin 1 (at_risk/low intent)
        1.0,    -- [7]  total_interactions      bin 1 (very few)
        0.0,    -- [8]  is_multi_channel        0
        1.0,    -- [9]  recency_bucket          cold = 1 (worst)
        1.0,    -- [10] engagement_depth        bin 1 (low/negative)
        0.0,    -- [11] quotation_sent          0
        0.0,    -- [12] is_enterprise_deal      0
        4.0,    -- [13] pipeline_stage          NEW_LEAD = 4 (alphabetical)
        3.0,    -- [14] days_in_pipeline        bin 3 (very long/stale)
        1.0,    -- [15] pipeline_velocity       bin 1 (slow)
        1.0,    -- [16] total_price_with_tax    bin 1 (low value)
        1.0,    -- [17] consumer_score_tier     LOW (< 40%)
        1.0,    -- [18] interaction_score_tier  LOW (< 40%)
        1.0     -- [19] product_quotation_score_tier LOW (< 40%)
    ])
};

-- NL-02: All sub-model tiers=1, early stage, no milestone, cold
RETURN {
    test: "NL-02 — All tiers=1, NEW_LEAD, no milestone, stale days (bin 3)",
    model: "lead_qualification",
    expected: "VERY LOW (< 0.10)",
    score: ml::lead_qualification<1.0.0>([
        0.0, 1.0, 1.0, 0.0, 1.0, 1.0, 1.0, 1.0, 0.0,
        1.0,    -- [9]  recency_bucket          cold=1
        1.0, 0.0, 0.0,
        4.0,    -- [13] pipeline_stage          NEW_LEAD=4
        3.0,    -- [14] days_in_pipeline        bin 3 (stale)
        1.0, 1.0, 1.0, 1.0, 1.0
    ])
};

-- NL-03: consumer=1, interaction=1, product=1, no quotation, cold
RETURN {
    test: "NL-03 — All tiers=1, cold recency, no quotation, no enterprise",
    model: "lead_qualification",
    expected: "VERY LOW (< 0.10)",
    score: ml::lead_qualification<1.0.0>([
        0.0, 1.0, 1.0, 0.0, 1.0, 1.0, 1.0, 1.0, 0.0,
        1.0,    -- [9]  recency_bucket          cold=1
        1.0,
        0.0,    -- [11] quotation_sent          0
        0.0,    -- [12] is_enterprise_deal      0
        4.0, 2.0, 1.0, 1.0, 1.0, 1.0, 1.0
    ])
};

-- NL-04: Poor org history + cold + low interactions + all tiers=1
RETURN {
    test: "NL-04 — Poor org (deals bin=1, sentiment bin=1), cold, tiers=1",
    model: "lead_qualification",
    expected: "VERY LOW (< 0.10)",
    score: ml::lead_qualification<1.0.0>([
        0.0,
        1.0,    -- [1]  stage_velocity  bin 1 (slow)
        1.0,    -- [2]  historical_deals_won bin 1 (no deals)
        0.0,    -- [3]  is_repeat_customer  0
        1.0,    -- [4]  industry_close_rate bin 1
        1.0,    -- [5]  historical_avg_sentiment bin 1 (negative)
        1.0, 1.0, 0.0,
        1.0,    -- [9]  recency_bucket  cold=1
        1.0, 0.0, 0.0,
        4.0, 2.0, 1.0, 1.0, 1.0, 1.0, 1.0
    ])
};

-- NL-05: All tiers=1, stale recency, no enterprise, no quotation
RETURN {
    test: "NL-05 — All tiers=1, stale pipeline (bin 3), no enterprise, cold=1",
    model: "lead_qualification",
    expected: "VERY LOW (< 0.10)",
    score: ml::lead_qualification<1.0.0>([
        0.0, 1.0, 1.0, 0.0, 1.0, 1.0, 1.0, 1.0, 0.0,
        1.0,    -- [9]  recency_bucket  cold=1 (worst)
        1.0, 0.0, 0.0,
        4.0,    -- [13] pipeline_stage  NEW_LEAD=4
        3.0,    -- [14] days_in_pipeline bin 3 (stale)
        1.0,
        1.0,    -- [16] total_price_with_tax bin 1 (low value)
        1.0, 1.0, 1.0
    ])
};

-- NL-06: Low stage velocity (bin 1), no milestone, cold, all tiers=1
RETURN {
    test: "NL-06 — Slow velocity bin 1, no milestone, cold, all tiers=1",
    model: "lead_qualification",
    expected: "VERY LOW (< 0.10)",
    score: ml::lead_qualification<1.0.0>([
        0.0,    -- [0]  has_action_milestone 0
        1.0,    -- [1]  stage_velocity       bin 1 (very slow progress)
        1.0, 0.0, 1.0, 1.0,
        2.0,    -- [6]  intent               bin 2 (slightly better intent)
        1.0, 0.0,
        1.0,    -- [9]  recency_bucket       cold=1
        1.0, 0.0, 0.0,
        3.0,    -- [13] pipeline_stage       MANUAL_FOLLOW_UP=3
        2.0, 1.0, 1.0, 1.0, 1.0, 1.0
    ])
};

-- NL-07: No multi-channel, no engagement, no quotation, tiers=1
RETURN {
    test: "NL-07 — Single channel, cold, no engagement, no quotation, tiers=1",
    model: "lead_qualification",
    expected: "VERY LOW (< 0.10)",
    score: ml::lead_qualification<1.0.0>([
        0.0, 1.0, 1.0, 0.0,
        2.0,    -- [4]  industry_close_rate  bin 2 (medium)
        1.0, 1.0, 1.0,
        0.0,    -- [8]  is_multi_channel     0 (single channel)
        1.0,    -- [9]  recency_bucket       cold=1
        1.0,
        0.0,    -- [11] quotation_sent       0
        0.0,    -- [12] is_enterprise_deal   0
        4.0, 2.0, 1.0, 1.0, 1.0, 1.0, 1.0
    ])
};

-- NL-08: consumer_score_tier=2 (medium) but interaction=1, product=1
-- Tests whether one medium sub-model still results in LOW overall
RETURN {
    test: "NL-08 — consumer=MEDIUM(2), interaction=LOW(1), product=LOW(1)",
    model: "lead_qualification",
    expected: "LOW (< 0.25)",
    score: ml::lead_qualification<1.0.0>([
        0.0, 1.0, 1.0, 0.0, 1.0, 1.0, 1.0, 1.0, 0.0,
        1.0,    -- [9]  recency_bucket  cold=1
        1.0, 0.0, 0.0,
        4.0, 2.0, 1.0, 1.0,
        2.0,    -- [17] consumer_score_tier  MEDIUM=2
        1.0,    -- [18] interaction_score_tier LOW=1
        1.0     -- [19] product_quotation_score_tier LOW=1
    ])
};

-- NL-09: Cold, no enterprise, no repeat, no quotation — all signals bad
RETURN {
    test: "NL-09 — Cold lead, no enterprise, no repeat, no quotation, tiers=1",
    model: "lead_qualification",
    expected: "VERY LOW (< 0.10)",
    score: ml::lead_qualification<1.0.0>([
        0.0, 1.0, 1.0,
        0.0,    -- [3]  is_repeat_customer  0
        1.0, 1.0, 1.0, 1.0,
        0.0,    -- [8]  is_multi_channel    0
        1.0,    -- [9]  recency_bucket      cold=1
        1.0,
        0.0,    -- [11] quotation_sent      0
        0.0,    -- [12] is_enterprise_deal  0
        4.0, 3.0, 1.0, 1.0, 1.0, 1.0, 1.0
    ])
};

-- NL-10: Very high days in pipeline (bin 3 = stale deal), low engagement
RETURN {
    test: "NL-10 — Stale deal (days bin=3), low engagement bin=1, all tiers=1",
    model: "lead_qualification",
    expected: "VERY LOW (< 0.10)",
    score: ml::lead_qualification<1.0.0>([
        0.0, 1.0, 1.0, 0.0, 1.0, 1.0, 1.0, 1.0, 0.0,
        2.0,    -- [9]  recency_bucket  stale=2
        1.0, 0.0, 0.0,
        4.0,
        3.0,    -- [14] days_in_pipeline bin 3 (very long, stale)
        1.0, 1.0, 1.0, 1.0, 1.0
    ])
};

-- NL-11: consumer=1, interaction=2, product=1 — interaction slightly better
RETURN {
    test: "NL-11 — consumer=LOW(1), interaction=MEDIUM(2), product=LOW(1)",
    model: "lead_qualification",
    expected: "LOW (< 0.25)",
    score: ml::lead_qualification<1.0.0>([
        0.0, 1.0, 1.0, 0.0, 1.0, 1.0, 1.0,
        2.0,    -- [7]  total_interactions  bin 2 (moderate)
        0.0,
        2.0,    -- [9]  recency_bucket      stale=2
        1.0, 0.0, 0.0,
        3.0,    -- [13] pipeline_stage      MANUAL_FOLLOW_UP=3
        2.0, 1.0, 1.0,
        1.0,    -- [17] consumer_score_tier      LOW=1
        2.0,    -- [18] interaction_score_tier   MEDIUM=2
        1.0     -- [19] product_quotation_tier   LOW=1
    ])
};

-- NL-12: consumer=1, interaction=1, product=2 — product slightly better
RETURN {
    test: "NL-12 — consumer=LOW(1), interaction=LOW(1), product=MEDIUM(2)",
    model: "lead_qualification",
    expected: "LOW (< 0.25)",
    score: ml::lead_qualification<1.0.0>([
        0.0, 1.0, 1.0, 0.0, 1.0, 1.0, 1.0, 1.0, 0.0,
        2.0,    -- [9]  recency_bucket  stale=2
        1.0,
        0.0,    -- [11] quotation_sent  0 (no quotation despite medium product)
        0.0,
        3.0, 2.0, 1.0,
        2.0,    -- [16] total_price_with_tax bin 2 (medium value)
        1.0,    -- [17] consumer_score_tier       LOW=1
        1.0,    -- [18] interaction_score_tier    LOW=1
        2.0     -- [19] product_quotation_tier    MEDIUM=2
    ])
};

-- NL-13: consumer=2, interaction=1, product=1 — only consumer medium
RETURN {
    test: "NL-13 — consumer=MEDIUM(2), interaction=LOW(1), product=LOW(1) again",
    model: "lead_qualification",
    expected: "LOW (< 0.20)",
    score: ml::lead_qualification<1.0.0>([
        0.0, 1.0, 2.0, 0.0, 1.0,
        2.0,    -- [5]  historical_avg_sentiment bin 2
        1.0, 1.0, 0.0,
        1.0,    -- [9]  recency_bucket  cold=1
        1.0, 0.0, 0.0,
        3.0, 2.0, 1.0, 1.0,
        2.0,    -- [17] consumer_score_tier       MEDIUM=2
        1.0,    -- [18] interaction_score_tier    LOW=1
        1.0     -- [19] product_quotation_tier    LOW=1
    ])
};

-- NL-14: All stage signals bad — stale, slow, no milestone, no quotation
RETURN {
    test: "NL-14 — Stale stage signals: no milestone, slow velocity, long pipeline",
    model: "lead_qualification",
    expected: "VERY LOW (< 0.10)",
    score: ml::lead_qualification<1.0.0>([
        0.0,    -- [0]  has_action_milestone    0
        1.0,    -- [1]  stage_velocity          bin 1 (slow)
        1.0, 0.0, 1.0, 1.0, 1.0, 1.0, 0.0,
        1.0,    -- [9]  recency_bucket          cold=1
        1.0,
        0.0,    -- [11] quotation_sent          0
        0.0,
        4.0,    -- [13] pipeline_stage          NEW_LEAD=4 (early)
        3.0,    -- [14] days_in_pipeline        bin 3 (very long)
        1.0,    -- [15] pipeline_velocity       bin 1 (slow)
        1.0, 1.0, 1.0, 1.0
    ])
};

-- NL-15: Cold recency, no multi-channel, low total interactions, all tiers=1
RETURN {
    test: "NL-15 — Cold recency=1, single channel, low interactions bin=1, tiers=1",
    model: "lead_qualification",
    expected: "VERY LOW (< 0.10)",
    score: ml::lead_qualification<1.0.0>([
        0.0, 1.0, 1.0, 0.0, 1.0, 1.0, 1.0,
        1.0,    -- [7]  total_interactions  bin 1 (very few)
        0.0,    -- [8]  is_multi_channel    0 (single channel only)
        1.0,    -- [9]  recency_bucket      cold=1
        1.0,    -- [10] engagement_depth    bin 1 (no engagement)
        0.0, 0.0,
        4.0, 2.0, 1.0, 1.0, 1.0, 1.0, 1.0
    ])
};

-- NL-16: No enterprise, no repeat, poor industry, no milestone, tiers=1
RETURN {
    test: "NL-16 — No enterprise, no repeat, poor industry (bin=1), no milestone",
    model: "lead_qualification",
    expected: "VERY LOW (< 0.10)",
    score: ml::lead_qualification<1.0.0>([
        0.0, 1.0, 1.0,
        0.0,    -- [3]  is_repeat_customer    0
        1.0,    -- [4]  industry_close_rate   bin 1 (worst industry)
        1.0, 1.0,
        2.0,    -- [7]  total_interactions    bin 2 (some interaction)
        0.0,
        2.0,    -- [9]  recency_bucket        stale=2
        1.0,
        0.0,    -- [11] quotation_sent        0
        0.0,    -- [12] is_enterprise_deal    0
        3.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0
    ])
};

-- NL-17: Stage=NEW_LEAD (alpha=4), minimum signals everywhere
RETURN {
    test: "NL-17 — NEW_LEAD stage, minimum velocity, cold, all tiers=1",
    model: "lead_qualification",
    expected: "VERY LOW (< 0.10)",
    score: ml::lead_qualification<1.0.0>([
        0.0,    -- [0]  has_action_milestone    0
        1.0,    -- [1]  stage_velocity          bin 1
        1.0,    -- [2]  historical_deals_won    bin 1
        0.0,    -- [3]  is_repeat_customer      0
        1.0,    -- [4]  industry_close_rate     bin 1
        1.0,    -- [5]  historical_avg_sentiment bin 1
        1.0,    -- [6]  intent                  bin 1
        1.0,    -- [7]  total_interactions      bin 1
        0.0,    -- [8]  is_multi_channel        0
        1.0,    -- [9]  recency_bucket          cold=1
        1.0,    -- [10] engagement_depth        bin 1
        0.0,    -- [11] quotation_sent          0
        0.0,    -- [12] is_enterprise_deal      0
        4.0,    -- [13] pipeline_stage          NEW_LEAD=4
        1.0,    -- [14] days_in_pipeline        bin 1 (fast but stuck at stage 0)
        1.0,    -- [15] pipeline_velocity       bin 1 (no stage progress)
        1.0,    -- [16] total_price_with_tax    bin 1 (low value)
        1.0,    -- [17] consumer_score_tier     LOW=1
        1.0,    -- [18] interaction_score_tier  LOW=1
        1.0     -- [19] product_quotation_tier  LOW=1
    ])
};

-- NL-18: Mixed moderate but sub-model tiers all still LOW (tier=1)
-- Some pipeline/org signals slightly better, but all 3 sub-models are LOW
RETURN {
    test: "NL-18 — Some medium org signals but all sub-model tiers still LOW=1",
    model: "lead_qualification",
    expected: "LOW (< 0.20)",
    score: ml::lead_qualification<1.0.0>([
        0.0,
        1.0,    -- [1]  stage_velocity          bin 1
        2.0,    -- [2]  historical_deals_won    bin 2 (some deals)
        0.0,
        1.0,    -- [4]  industry_close_rate     bin 1
        2.0,    -- [5]  historical_avg_sentiment bin 2 (medium org sentiment)
        2.0,    -- [6]  intent                  bin 2
        1.0,    -- [7]  total_interactions      bin 1 (still low)
        0.0,
        2.0,    -- [9]  recency_bucket          stale=2
        1.0,
        0.0,    -- [11] quotation_sent          0
        0.0,
        3.0, 2.0, 1.0,
        2.0,    -- [16] total_price_with_tax    bin 2
        1.0,    -- [17] consumer_score_tier     LOW=1 (still low!)
        1.0,    -- [18] interaction_score_tier  LOW=1
        1.0     -- [19] product_quotation_tier  LOW=1
    ])
};

-- NL-19: Low pipeline velocity (bin 1), cold, no enterprise, no quotation
RETURN {
    test: "NL-19 — Slow velocity bin 1, cold=1, no enterprise, no quotation, tiers=1",
    model: "lead_qualification",
    expected: "VERY LOW (< 0.10)",
    score: ml::lead_qualification<1.0.0>([
        0.0,
        1.0,    -- [1]  stage_velocity          bin 1 (slow)
        1.0, 0.0,
        2.0,    -- [4]  industry_close_rate     bin 2 (medium industry)
        1.0, 1.0, 1.0, 0.0,
        1.0,    -- [9]  recency_bucket          cold=1
        1.0,
        0.0,    -- [11] quotation_sent          0
        0.0,    -- [12] is_enterprise_deal      0
        4.0,    -- [13] pipeline_stage          NEW_LEAD=4
        3.0,    -- [14] days_in_pipeline        bin 3 (long/stale)
        1.0,    -- [15] pipeline_velocity       bin 1 (slow)
        1.0, 1.0, 1.0, 1.0
    ])
};

-- NL-20: ULTIMATE NEGATIVE — every single feature at its absolute minimum
RETURN {
    test: "NL-20 — ULTIMATE NEGATIVE: every feature at absolute worst value",
    model: "lead_qualification",
    expected: "MINIMUM POSSIBLE score",
    score: ml::lead_qualification<1.0.0>([
        0.0,    -- [0]  has_action_milestone    0 (no milestone)
        1.0,    -- [1]  stage_velocity          bin 1 (slowest possible)
        1.0,    -- [2]  historical_deals_won    bin 1 (no deals)
        0.0,    -- [3]  is_repeat_customer      0 (never bought before)
        1.0,    -- [4]  industry_close_rate     bin 1 (worst industry)
        1.0,    -- [5]  historical_avg_sentiment bin 1 (negative org history)
        1.0,    -- [6]  intent                  bin 1 (at_risk / browsing)
        1.0,    -- [7]  total_interactions      bin 1 (barely any contact)
        0.0,    -- [8]  is_multi_channel        0 (single channel only)
        1.0,    -- [9]  recency_bucket          cold=1 (no recent contact)
        1.0,    -- [10] engagement_depth        bin 1 (zero/negative)
        0.0,    -- [11] quotation_sent          0 (never quoted)
        0.0,    -- [12] is_enterprise_deal      0 (budget product)
        4.0,    -- [13] pipeline_stage          NEW_LEAD=4 (earliest stage)
        3.0,    -- [14] days_in_pipeline        bin 3 (very long / stale)
        1.0,    -- [15] pipeline_velocity       bin 1 (no progress)
        1.0,    -- [16] total_price_with_tax    bin 1 (low value deal)
        1.0,    -- [17] consumer_score_tier     LOW=1 (< 40%)
        1.0,    -- [18] interaction_score_tier  LOW=1 (< 40%)
        1.0     -- [19] product_quotation_score_tier LOW=1 (< 40%)
    ])
};


-- ================================================================
-- NEGATIVE TEST SUMMARY TABLE
-- ================================================================
-- SECTION 1: consumer_score (NC-01 to NC-20)
--   Signals tested: ANGRY(0), NEGATIVE(1), DISSATISFIED(2),
--   at_risk intent(0), window_shopping(9), zero org history,
--   negative combo scores, worst industry (0.38)
--
-- SECTION 2: interaction_score (NI-01 to NI-20)
--   Signals tested: zero interactions, cold recency(1),
--   stale recency(3), email-only channel, negative engagement_depth,
--   90-day-old contacts, zero org history
--
-- SECTION 3: product_quotation_score (NP-01 to NP-20)
--   Signals tested: budget products (₹1,000–₹15,000),
--   no quotation sent, non-enterprise, 60–120 day stale pipeline,
--   worst industry close rate (0.38), zero pipeline velocity
--
-- SECTION 4: lead_qualification (NL-01 to NL-20)
--   Signals tested: all sub-model tiers=1, cold recency,
--   no milestone, no quotation, no enterprise, slow pipeline,
--   mixed partial tiers (one=2 while others=1)
-- ================================================================
-- TOTAL QUERIES: 80  (20 × 4 models)
-- ================================================================
