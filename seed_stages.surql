-- Use same namespace and database as the ML setup
USE NS vitasales;
USE DB vitasales;

-- ==============================================================================
-- SETUP DEPENDENCIES
-- Create dummy products and orgs to satisfy ML model's lookup queries
-- ==============================================================================

CREATE product:p_centrifugal SET 
    name = "Centrifugal Chiller", 
    sku = "CHIL-001", 
    base_price = 120000.0, 
    tax_rate = 18.0, 
    attributes = { type: "centrifugal" };

CREATE organisation:org_auto SET 
    name = "AutoCorp", 
    industry = "Automotive";

CREATE organisation:org_pharma SET 
    name = "PharmaLife", 
    industry = "Pharmaceuticals";


-- ==============================================================================
-- Scenario 1: NEW_LEAD / CURIOUS
-- ==============================================================================

CREATE lead:1 SET 
    state = "NEW_LEAD", 
    completeness = "INCOMPLETE", 
    source_channel = "channel:email",
    organisation = organisation:org_auto,
    created_at = time::now();

-- Link lead to the product they are interested in
RELATE lead:1->interested_in->product:p_centrifugal;

CREATE conversation:1 SET 
    lead = lead:1, 
    sentiment = "CURIOUS", 
    summary = "Customer is asking about basic features.",
    created_at = time::now(),
    last_message_at = time::now();

CREATE message:1_1 SET 
    conversation = conversation:1, 
    content = "Hi, I am curious about your new centrifugal chillers. Can you tell me more?",
    created_at = time::now();


-- ==============================================================================
-- Scenario 2: MANUAL_FOLLOW_UP / INTERESTED
-- ==============================================================================

CREATE lead:2 SET 
    state = "MANUAL_FOLLOW_UP", 
    completeness = "PARTIAL", 
    source_channel = "channel:phone",
    created_at = time::now() - 2d;

RELATE lead:2->interested_in->product:p_centrifugal;

CREATE conversation:2 SET 
    lead = lead:2, 
    sentiment = "INTERESTED", 
    summary = "Customer showed high interest during initial call.",
    created_at = time::now() - 2d,
    last_message_at = time::now() - 1d;

CREATE message:2_1 SET 
    conversation = conversation:2, 
    content = "Thanks for the call yesterday. We are definitely interested in the specs you mentioned.",
    created_at = time::now() - 1d;


-- ==============================================================================
-- Scenario 3: SALES_FOLLOW_UP / ANGRY
-- ==============================================================================

CREATE lead:3 SET 
    state = "SALES_FOLLOW_UP", 
    completeness = "PARTIAL", 
    source_channel = "channel:whatsapp",
    created_at = time::now() - 5d;

RELATE lead:3->interested_in->product:p_centrifugal;

CREATE conversation:3 SET 
    lead = lead:3, 
    sentiment = "ANGRY", 
    summary = "Customer is upset because nobody called back.",
    created_at = time::now() - 5d,
    last_message_at = time::now() - 1h;

CREATE message:3_1 SET 
    conversation = conversation:3, 
    content = "I have been waiting for a callback for 5 days! This is terrible customer service. Someone better contact me today.",
    created_at = time::now() - 1h;


-- ==============================================================================
-- Scenario 4: SALES_QUALIFIED / URGENT
-- ==============================================================================

CREATE lead:4 SET 
    state = "SALES_QUALIFIED", 
    completeness = "COMPLETE", 
    source_channel = "channel:phone",
    organisation = organisation:org_pharma,
    created_at = time::now() - 10d;

RELATE lead:4->interested_in->product:p_centrifugal;

CREATE conversation:4 SET 
    lead = lead:4, 
    sentiment = "URGENT", 
    summary = "Customer needs product set up by end of month.",
    created_at = time::now() - 10d,
    last_message_at = time::now();

CREATE message:4_1 SET 
    conversation = conversation:4, 
    content = "We have an emergency. Our current chiller broke down and we need a replacement URGENTLY within this week.",
    created_at = time::now();


-- ==============================================================================
-- Scenario 5: QUOTATION / SATISFIED
-- ==============================================================================

CREATE lead:5 SET 
    state = "QUOTATION", 
    completeness = "COMPLETE", 
    source_channel = "channel:email",
    created_at = time::now() - 15d;

RELATE lead:5->interested_in->product:p_centrifugal;

-- In QUOTATION stage, we generate a quote which influences the AI Score positively 
CREATE generated_quotation:5_1 SET 
    lead = lead:5,
    amount = 141600.0,
    created_at = time::now() - 1d;

CREATE conversation:5 SET 
    lead = lead:5, 
    sentiment = "SATISFIED", 
    summary = "Customer is happy with the quotation provided.",
    created_at = time::now() - 15d,
    last_message_at = time::now() - 2h;

CREATE message:5_1 SET 
    conversation = conversation:5, 
    content = "Thank you for the quick turnaround on the quote. The pricing looks very reasonable. We are highly satisfied.",
    created_at = time::now() - 2h;


-- ==============================================================================
-- Scenario 6: FOLLOW_UP_NEGOTIATION / NEGOTIATING
-- ==============================================================================

CREATE lead:6 SET 
    state = "FOLLOW_UP_NEGOTIATION", 
    completeness = "COMPLETE", 
    source_channel = "channel:whatsapp",
    created_at = time::now() - 20d;

RELATE lead:6->interested_in->product:p_centrifugal;

CREATE generated_quotation:6_1 SET 
    lead = lead:6,
    amount = 141600.0,
    created_at = time::now() - 5d;

CREATE conversation:6 SET 
    lead = lead:6, 
    sentiment = "NEGOTIATING", 
    summary = "Customer is asking for a 10% discount to finalize.",
    created_at = time::now() - 20d,
    last_message_at = time::now() - 10m;

CREATE message:6_1 SET 
    conversation = conversation:6, 
    content = "We like the product, but the quoted price is slightly above budget. Could you offer a 10% discount? We can sign today if so.",
    created_at = time::now() - 10m;


-- ==============================================================================
-- Scenario 7: CLOSED / DISSATISFIED
-- ==============================================================================

CREATE lead:7 SET 
    state = "CLOSED", 
    completeness = "COMPLETE", 
    source_channel = "channel:email",
    created_at = time::now() - 30d;

RELATE lead:7->interested_in->product:p_centrifugal;

CREATE generated_quotation:7_1 SET 
    lead = lead:7,
    amount = 141600.0,
    created_at = time::now() - 10d;

CREATE conversation:7 SET 
    lead = lead:7, 
    sentiment = "DISSATISFIED", 
    summary = "Customer chose a competitor due to high lead time.",
    created_at = time::now() - 30d,
    last_message_at = time::now() - 1d;

CREATE message:7_1 SET 
    conversation = conversation:7, 
    content = "Unfortunately, we are going with another vendor. Your delivery timeline was too long, keeping us dissatisfied with the offering.",
    created_at = time::now() - 1d;
