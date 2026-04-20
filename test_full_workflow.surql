-- ================================================================
-- VITAFI FULL WORKFLOW TEST
-- Covers: Lead Management, AI Scoring, Multi-Channel, Sentiment, Quotation
-- Run each STEP separately and check ai_confidence after each one.
-- Server: http://localhost:8000  |  NS: vitasales  |  DB: vitasales
-- ================================================================

-- ================================================================
-- AUTO CLEANUP — Runs first every time to delete previous test data
-- ================================================================
DELETE FROM message WHERE conversation IN [
    conversation:conv_whatsapp_01,
    conversation:conv_email_01,
    conversation:conv_voice_01,
    conversation:conv_web_01
];
DELETE conversation:conv_whatsapp_01;
DELETE conversation:conv_email_01;
DELETE conversation:conv_voice_01;
DELETE conversation:conv_web_01;
DELETE FROM interested_in WHERE in = lead:test_demo_01;
DELETE FROM generated_quotation WHERE in = lead:test_demo_01;
DELETE FROM generated WHERE in = lead:test_demo_01;
DELETE quotation:quot_demo_01;
DELETE lead:test_demo_01;
DELETE organisation:test_org_demo;


-- ================================================================
-- STEP 0: Setup — Create Test Organisation
-- ================================================================
CREATE organisation:test_org_demo SET
    name    = 'TechCool Pharma Ltd',
    industry = 'Pharmaceuticals',
    country = 'India',
    city    = 'Hyderabad';

-- Verify
SELECT id, name, industry FROM organisation:test_org_demo;


-- ================================================================
-- STEP 1: Create Lead → stage: NEW_LEAD
--         EVENT fires: score_on_lead_change → fn::score_lead()
--         Expected ai_confidence: ~0.02 (low — raw new lead, no data)
-- ================================================================
CREATE lead:test_demo_01 SET
    name           = 'Rahul Sharma',
    email          = 'rahul.sharma@techcoolpharma.in',
    phone          = '+91-9876543210',
    designation    = 'Purchase Manager',
    state          = 'NEW_LEAD',
    completeness   = 'INCOMPLETE',
    classification = 'NON-SALES',
    source_channel = channel:whatsapp,
    organisation   = organisation:test_org_demo,
    created_at     = time::now(),
    updated_at     = time::now();

-- CHECK ai_confidence after Step 1
SELECT id, name, state, completeness, ai_confidence FROM lead:test_demo_01;


-- ================================================================
-- STEP 2: Add Product Interest + WhatsApp Conversation + Message
--         CHANNEL: WhatsApp
--         EVENT fires: infer_sentiment_on_message
--                      → HTTP POST to LLM API
--                      → UPDATE conversation.sentiment (e.g. INTERESTED/CURIOUS)
--                      → score_on_conv_change → fn::score_lead()
--         Expected ai_confidence: slight rise due to sentiment signal
-- ================================================================

-- Link product interest (Chillers — product:p010, ₹75,000)
RELATE lead:test_demo_01->interested_in->product:p010;

-- Create WhatsApp conversation
CREATE conversation:conv_whatsapp_01 SET
    lead           = lead:test_demo_01,
    channel        = channel:whatsapp,
    sentiment      = 'NEUTRAL',
    summary        = 'Customer inquired about industrial chillers for pharmaceutical plant cooling requirements.',
    started_at     = time::now(),
    last_message_at = time::now(),
    created_at     = time::now();

-- Send first message → triggers infer_sentiment_on_message event
CREATE message SET
    conversation = conversation:conv_whatsapp_01,
    content      = 'Hi, I am looking for industrial chillers for our pharma plant. We need cooling for our production line. Can you help?',
    sender       = 'CUSTOMER',
    message_type = 'TEXT',
    created_at   = time::now();

-- CHECK ai_confidence + sentiment after Step 2
SELECT id, state, ai_confidence FROM lead:test_demo_01;
SELECT id, channel, sentiment, summary FROM conversation:conv_whatsapp_01;


-- ================================================================
-- STEP 3: Move → MANUAL_FOLLOW_UP + Email Conversation + Message
--         CHANNEL: Email
--         EVENT fires: score_on_lead_change (state changed)
--                      + infer_sentiment_on_message (new message)
--         Expected ai_confidence: rising (stage 1, positive/interested sentiment)
-- ================================================================
UPDATE lead:test_demo_01 SET
    state      = 'MANUAL_FOLLOW_UP',
    updated_at = time::now();

-- Create Email conversation
CREATE conversation:conv_email_01 SET
    lead           = lead:test_demo_01,
    channel        = channel:email,
    sentiment      = 'NEUTRAL',
    summary        = 'Follow-up email. Customer requested product specs and pricing for chillers.',
    started_at     = time::now(),
    last_message_at = time::now(),
    created_at     = time::now();

-- Send email message → triggers sentiment inference
CREATE message SET
    conversation = conversation:conv_email_01,
    content      = 'Thank you for reaching out! I am very interested in your Chiller product range. Could you please send me the technical specifications and pricing? We are evaluating options for our production facility.',
    sender       = 'CUSTOMER',
    message_type = 'TEXT',
    created_at   = time::now();

-- CHECK ai_confidence + sentiment after Step 3
SELECT id, state, ai_confidence FROM lead:test_demo_01;
SELECT id, channel, sentiment FROM conversation:conv_email_01;


-- ================================================================
-- STEP 4: Move → SALES_FOLLOW_UP + Voice Call Conversation + Message
--         CHANNEL: Voice
--         EVENT fires: score_on_lead_change (state changed)
--                      + infer_sentiment_on_message
--         Expected ai_confidence: rising (stage 2, urgent sentiment boost)
-- ================================================================
UPDATE lead:test_demo_01 SET
    state      = 'SALES_FOLLOW_UP',
    updated_at = time::now();

-- Create Voice call conversation (summary of phone call)
CREATE conversation:conv_voice_01 SET
    lead           = lead:test_demo_01,
    channel        = channel:voice,
    sentiment      = 'NEUTRAL',
    summary        = 'Phone call summary: Customer confirmed requirement, urgent timeline, budget roughly approved, wants demo before final decision.',
    started_at     = time::now(),
    last_message_at = time::now(),
    created_at     = time::now();

-- Call summary message → triggers sentiment inference
CREATE message SET
    conversation = conversation:conv_voice_01,
    content      = 'We need the chiller installed urgently before the end of this quarter. Budget has been approved by management. Please arrange a site visit and demo as soon as possible.',
    sender       = 'CUSTOMER',
    message_type = 'TEXT',
    created_at   = time::now();

-- CHECK ai_confidence + sentiment after Step 4
SELECT id, state, ai_confidence FROM lead:test_demo_01;
SELECT id, channel, sentiment FROM conversation:conv_voice_01;


-- ================================================================
-- STEP 5: Move → SALES_QUALIFIED + Mark COMPLETE + Web Chat Message
--         CHANNEL: Web
--         EVENT fires: score_on_lead_change (state + completeness changed)
--                      + infer_sentiment_on_message
--         Expected ai_confidence: strong rise (stage 3, complete, positive)
-- ================================================================
UPDATE lead:test_demo_01 SET
    state          = 'SALES_QUALIFIED',
    completeness   = 'COMPLETE',
    classification = 'SALES',
    updated_at     = time::now();

-- Create Web chat conversation
CREATE conversation:conv_web_01 SET
    lead           = lead:test_demo_01,
    channel        = channel:web,
    sentiment      = 'NEUTRAL',
    summary        = 'Customer confirmed budget approval. Ready to receive formal quotation and move forward.',
    started_at     = time::now(),
    last_message_at = time::now(),
    created_at     = time::now();

-- Web message → triggers sentiment inference
CREATE message SET
    conversation = conversation:conv_web_01,
    content      = 'The budget has been officially approved by our finance team. We are definitely moving forward with the purchase. Please send us a formal quotation at the earliest. We are very satisfied with your responsiveness.',
    sender       = 'CUSTOMER',
    message_type = 'TEXT',
    created_at   = time::now();

-- CHECK ai_confidence + sentiment after Step 5
SELECT id, state, completeness, ai_confidence FROM lead:test_demo_01;
SELECT id, channel, sentiment FROM conversation:conv_web_01;


-- ================================================================
-- STEP 6: Create Quotation + Link to Lead + Move → QUOTATION stage
--         EVENT fires: score_on_lead_change (state changed)
--                      + score_on_conv_change (quotation_sent flag becomes 1)
--         Expected ai_confidence: higher (stage 4, quotation sent, complete)
-- ================================================================

-- Create the quotation record
CREATE quotation:quot_demo_01 SET
    lead           = lead:test_demo_01,
    quote_id       = 'QT-DEMO-2026-001',
    quotation_no   = 'VF-QN-2026-001',
    status         = 'GENERATED',
    currency       = 'INR',
    subtotal       = 75000.00,
    products       = [
        {
            product      : product:p010,
            product_name : 'Chillers',
            sku          : 'CHILL-001',
            quantity     : 1,
            unit_price   : 75000.00,
            tax_rate     : 18.0,
            tax_amount   : 13500.00,
            total        : 88500.00
        }
    ],
    notes        = 'Industrial Chiller for pharmaceutical production line. Includes 1-year AMC.',
    model        = 'Industrial Chiller',
    isfeedback   = false,
    generated_at = time::now(),
    created_at   = time::now();

-- Link quotation to lead (this is what fn::score_lead checks for has_quotation)
RELATE lead:test_demo_01->generated_quotation->quotation:quot_demo_01;
RELATE lead:test_demo_01->generated->quotation:quot_demo_01;

-- Send the quotation
UPDATE quotation:quot_demo_01 SET
    status   = 'SENT',
    sent_via = 'EMAIL',
    sent_at  = time::now();

-- Move lead to QUOTATION stage (triggers re-score)
UPDATE lead:test_demo_01 SET
    state      = 'QUOTATION',
    updated_at = time::now();

-- CHECK ai_confidence + quotation status after Step 6
SELECT id, state, ai_confidence FROM lead:test_demo_01;
SELECT id, quote_id, status, subtotal, sent_at FROM quotation:quot_demo_01;


-- ================================================================
-- STEP 7: Move → FOLLOW_UP_NEGOTIATION + Negotiation WhatsApp Message
--         CHANNEL: WhatsApp (reusing conv_whatsapp_01)
--         EVENT fires: score_on_lead_change (state changed)
--                      + infer_sentiment_on_message (NEGOTIATING sentiment)
--                      + score_on_conv_change
--         Expected ai_confidence: high (stage 5, negotiating with quotation)
-- ================================================================
UPDATE lead:test_demo_01 SET
    state      = 'FOLLOW_UP_NEGOTIATION',
    updated_at = time::now();

-- Negotiation message → triggers LLM sentiment (expects NEGOTIATING)
CREATE message SET
    conversation = conversation:conv_whatsapp_01,
    content      = 'We reviewed the quotation. The price is slightly above our budget. Could you offer a 10% discount? We are ready to sign the purchase order immediately if you can adjust the price. Looking to close this deal this week.',
    sender       = 'CUSTOMER',
    message_type = 'TEXT',
    created_at   = time::now();

-- Update conversation context
UPDATE conversation:conv_whatsapp_01 SET
    last_message_at = time::now(),
    summary         = 'Customer negotiating 10% discount. Ready to sign PO immediately upon price adjustment. Deal likely to close this week.';

-- CHECK ai_confidence + sentiment after Step 7
SELECT id, state, ai_confidence FROM lead:test_demo_01;
SELECT id, channel, sentiment FROM conversation:conv_whatsapp_01;


-- ================================================================
-- STEP 8: Accept Quotation + Final Message + Move → CLOSED
--         EVENT fires: score_on_lead_change (state = CLOSED)
--                      + infer_sentiment_on_message (SATISFIED / POSITIVE)
--                      + score_on_conv_change
--         Expected ai_confidence: highest value (stage 6, all positive signals)
-- ================================================================

-- Final positive closing message → triggers LLM sentiment
CREATE message SET
    conversation = conversation:conv_whatsapp_01,
    content      = 'We accept the quotation and are very satisfied with the entire process. Please go ahead with the order processing. Looking forward to a long-term partnership.',
    sender       = 'CUSTOMER',
    message_type = 'TEXT',
    created_at   = time::now();

-- Accept the quotation
UPDATE quotation:quot_demo_01 SET
    status         = 'ACCEPTED',
    accepted_at    = time::now(),
    feedbackrating = '5',
    isfeedback     = true;

-- Close the lead (triggers final re-score)
UPDATE lead:test_demo_01 SET
    state      = 'CLOSED',
    updated_at = time::now();

-- CHECK final ai_confidence after Step 8
SELECT id, state, completeness, classification, ai_confidence FROM lead:test_demo_01;
SELECT id, status, accepted_at, feedbackrating FROM quotation:quot_demo_01;


-- ================================================================
-- STEP 9: Final Summary — Complete picture of the entire workflow
-- ================================================================

-- 1. Lead overview
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
FROM lead:test_demo_01
FETCH organisation;

-- 2. All conversations with channel and sentiment
SELECT
    id,
    channel.name AS channel,
    sentiment,
    summary,
    last_message_at,
    started_at
FROM conversation
WHERE lead = lead:test_demo_01
ORDER BY started_at ASC
FETCH channel;

-- 3. All messages across all conversations (full multi-channel thread)
SELECT
    id,
    conversation.channel.name AS channel,
    sender,
    content,
    created_at
FROM message
WHERE conversation IN (
    SELECT VALUE id FROM conversation WHERE lead = lead:test_demo_01
)
ORDER BY created_at ASC
FETCH conversation;

-- 4. Quotation details with product line items
SELECT
    id,
    quote_id,
    quotation_no,
    status,
    currency,
    subtotal,
    products,
    notes,
    sent_via,
    sent_at,
    accepted_at,
    feedbackrating
FROM quotation
WHERE lead = lead:test_demo_01;

-- 5. Product the lead was interested in
SELECT ->interested_in->product.* AS interested_products
FROM lead:test_demo_01;


-- (Cleanup is now at the top of this file — runs automatically each time)
