package com.dure.botbuilder.surreal.newmapperservice;


import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpEntity;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpMethod;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.stereotype.Component;
import org.springframework.stereotype.Service;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.client.RestTemplate;

import com.dure.botbuilder.surreal.config.SurrealDBClient;
import com.dure.botbuilder.surreal.errorlog.ErrorLogService;
import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonInclude;
import com.fasterxml.jackson.annotation.JsonProperty;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

// ════════════════════════════════════════════════════════════════════════════
//  LEAD QUALIFICATION SCORE PIPELINE  —  All logic in one file
//
//  Flow:
//    SurrealDB trigger fires when consumer_score / interaction_score /
//    product_quotation_score changes on lead table (UPDATE event)
//        ↓
//    [1] POST /api/v1/lead-qualification/trigger
//        ↓
//    [2] Fetch raw data from SurrealDB (6 tables + graph edge)
//        Joins: lead + organisation + conversation (channel counts + recency)
//               + generated_quotation + product (via interested_in edge)
//               + lead_state_history (action milestone)
//        Also reads: lead.consumer_score, lead.interaction_score,
//                    lead.product_quotation_score (already computed)
//        ↓
//    [3] Map DB JSON → 20 Normalized integer features
//        (LeadQualificationMapper.normalize)
//        ↓
//    [4] Call ml::lead_qualification<1.0.0>([f0..f19]) in SurrealDB
//        ↓
//    [5] Write lead_qualification_score back to lead record
//
//  Feature order (MUST match training CSV column order):
//    [0]  has_action_milestone       binary 0/1
//    [1]  stage_velocity             IQR bin 1/2/3  (Q1=0.48, Q3=1.86)
//    [2]  historical_deals_won       IQR bin 1/2/3  (Q1=0.0,  Q3=3.0)
//    [3]  is_repeat_customer         binary 0/1
//    [4]  industry_close_rate        IQR bin 1/2/3  (Q1=0.424,Q3=0.594)
//    [5]  historical_avg_sentiment   IQR bin 1/2/3  (Q1=-0.20,Q3=0.48)
//    [6]  intent                     bin 1/2/3      (raw 1-10 rebinned)
//    [7]  total_interactions         IQR bin 1/2/3  (Q1=4,    Q3=10)
//    [8]  is_multi_channel           binary 0/1
//    [9]  recency_bucket             1=cold 2=stale 3=active 4=fresh
//    [10] engagement_depth           IQR bin 1/2/3  (Q1=3.0,  Q3=5.0)
//    [11] quotation_sent             binary 0/1
//    [12] is_enterprise_deal         binary 0/1
//    [13] pipeline_stage             label encoded 1-12 (alphabetical)
//    [14] days_in_pipeline           IQR bin 1/2/3  (Q1=5,    Q3=25)
//    [15] pipeline_velocity          IQR bin 1/2/3  (Q1=0.10, Q3=0.50)
//    [16] total_price_with_tax       IQR bin 1/2/3  (Q1=50000,Q3=300000)
//    [17] consumer_score_tier        tier 1=Low(<40) 2=Mid(40-70) 3=High(>70)
//    [18] interaction_score_tier     tier same thresholds
//    [19] product_quotation_score_tier tier same thresholds
// ════════════════════════════════════════════════════════════════════════════


// ══════════════════════════════════════════════════════════════════════════════
//  MODEL 1 — RawLeadQualInput
//  Deserialized from the SurrealDB SQL query JSON response.
//  Contains raw (un-binned) values from multiple joined tables.
// ══════════════════════════════════════════════════════════════════════════════

@JsonIgnoreProperties(ignoreUnknown = true)
class RawLeadQualInput {

    // ── lead ──────────────────────────────────────────────────────────────────
    // lead.id — carried for DB write-back, dropped from ML payload
    @JsonProperty("lead_id")
    private String leadId;

    // lead.state — pipeline stage as string
    // values: "NEW_LEAD"|"MANUAL_FOLLOW_UP"|"SALES_FOLLOW_UP"|"SALES_QUALIFIED"
    //         |"QUOTATION"|"FOLLOW_UP_NEGOTIATION"|"CLOSED"
    @JsonProperty("pipeline_stage")
    private String pipelineStage;

    // computed in SQL: (now - lead.created_at) / 86400, min=1
    @JsonProperty("days_in_pipeline")
    private Double daysInPipeline;

    // computed in SQL: stage_ordinal(0-6) / days_in_pipeline
    // Used to derive both stage_velocity (Q1=0.48, Q3=1.86) and
    // pipeline_velocity (Q1=0.10, Q3=0.50) — same raw value, different IQR bins
    @JsonProperty("stage_velocity_raw")
    private Double stageVelocityRaw;

    // lead_state_history — 1 if any to_state in [SALES_QUALIFIED, QUOTATION_SENT, CLOSED]
    @JsonProperty("has_action_milestone")
    private Integer hasActionMilestone;

    // lead.classification — AI intent classifier output (string)
    // values: "at_risk"|"churning"|"closing"|"comparison_shopping"|"evaluating"
    //         |"information_seeking"|"negotiating"|"ready_to_buy"
    //         |"upsell_opportunity"|"window_shopping"
    // Will be label-encoded 1-10, then rebinned to 1/2/3
    @JsonProperty("intent")
    private String intent;

    // ── organisation ──────────────────────────────────────────────────────────
    // organisation.historical_deals_won — count of past CLOSED deals for this org
    @JsonProperty("historical_deals_won")
    private Integer historicalDealsWon;

    // organisation.historical_avg_sentiment — org-level avg sentiment, float -1.0 to +1.0
    @JsonProperty("historical_avg_sentiment")
    private Double historicalAvgSentiment;

    // organisation.industry — raw industry string for lookup table
    @JsonProperty("industry")
    private String industry;

    // ── conversation (latest, across all channels) ─────────────────────────────
    // conversation.sentiment — most recent AI sentiment label (string)
    // Used to compute engagement_depth weight
    @JsonProperty("sentiment")
    private String sentiment;

    // sum of whatsapp_count + phone_count + email_count (computed in SQL)
    @JsonProperty("total_interactions")
    private Integer totalInteractions;

    // count of WhatsApp conversations for this lead
    @JsonProperty("whatsapp_count")
    private Integer whatsappCount;

    // count of phone/voice conversations for this lead
    @JsonProperty("phone_count")
    private Integer phoneCount;

    // count of email/web conversations for this lead
    @JsonProperty("email_count")
    private Integer emailCount;

    // (now - last_conv.last_message_at) / 86400 in days (float)
    // Used to derive recency_bucket: ≤3→fresh(4), ≤7→active(3), ≤21→stale(2), >21→cold(1)
    @JsonProperty("days_since_last_message")
    private Double daysSinceLastMessage;

    // ── generated_quotation ───────────────────────────────────────────────────
    // 1 if COUNT(generated_quotation WHERE in = lead_id) > 0, else 0
    @JsonProperty("quotation_sent")
    private Integer quotationSent;

    // ── product (via lead->interested_in->product graph edge) ─────────────────
    // product.base_price — raw price before tax
    @JsonProperty("base_price")
    private Double basePrice;

    // product.base_price × (1 + product.tax_rate/100), computed in SQL
    @JsonProperty("total_price_with_tax")
    private Double totalPriceWithTax;

    // ── lead (already-computed sub-scores, written by earlier events) ──────────
    // lead.consumer_score — 0.0 to 100.0 (from fn::score_consumer)
    @JsonProperty("consumer_score")
    private Double consumerScore;

    // lead.interaction_score — 0.0 to 100.0 (from fn::score_interaction)
    @JsonProperty("interaction_score")
    private Double interactionScore;

    // lead.product_quotation_score — 0.0 to 100.0 (from fn::score_product_quotation)
    @JsonProperty("product_quotation_score")
    private Double productQuotationScore;

    // ── Getters & Setters ─────────────────────────────────────────────────────
    public String  getLeadId()                      { return leadId; }
    public void    setLeadId(String v)               { this.leadId = v; }
    public String  getPipelineStage()                { return pipelineStage; }
    public void    setPipelineStage(String v)        { this.pipelineStage = v; }
    public Double  getDaysInPipeline()               { return daysInPipeline; }
    public void    setDaysInPipeline(Double v)       { this.daysInPipeline = v; }
    public Double  getStageVelocityRaw()             { return stageVelocityRaw; }
    public void    setStageVelocityRaw(Double v)     { this.stageVelocityRaw = v; }
    public Integer getHasActionMilestone()           { return hasActionMilestone; }
    public void    setHasActionMilestone(Integer v)  { this.hasActionMilestone = v; }
    public String  getIntent()                       { return intent; }
    public void    setIntent(String v)               { this.intent = v; }
    public Integer getHistoricalDealsWon()           { return historicalDealsWon; }
    public void    setHistoricalDealsWon(Integer v)  { this.historicalDealsWon = v; }
    public Double  getHistoricalAvgSentiment()       { return historicalAvgSentiment; }
    public void    setHistoricalAvgSentiment(Double v){ this.historicalAvgSentiment = v; }
    public String  getIndustry()                     { return industry; }
    public void    setIndustry(String v)             { this.industry = v; }
    public String  getSentiment()                    { return sentiment; }
    public void    setSentiment(String v)            { this.sentiment = v; }
    public Integer getTotalInteractions()            { return totalInteractions; }
    public void    setTotalInteractions(Integer v)   { this.totalInteractions = v; }
    public Integer getWhatsappCount()                { return whatsappCount; }
    public void    setWhatsappCount(Integer v)       { this.whatsappCount = v; }
    public Integer getPhoneCount()                   { return phoneCount; }
    public void    setPhoneCount(Integer v)          { this.phoneCount = v; }
    public Integer getEmailCount()                   { return emailCount; }
    public void    setEmailCount(Integer v)          { this.emailCount = v; }
    public Double  getDaysSinceLastMessage()         { return daysSinceLastMessage; }
    public void    setDaysSinceLastMessage(Double v) { this.daysSinceLastMessage = v; }
    public Integer getQuotationSent()                { return quotationSent; }
    public void    setQuotationSent(Integer v)       { this.quotationSent = v; }
    public Double  getBasePrice()                    { return basePrice; }
    public void    setBasePrice(Double v)            { this.basePrice = v; }
    public Double  getTotalPriceWithTax()            { return totalPriceWithTax; }
    public void    setTotalPriceWithTax(Double v)    { this.totalPriceWithTax = v; }
    public Double  getConsumerScore()                { return consumerScore; }
    public void    setConsumerScore(Double v)        { this.consumerScore = v; }
    public Double  getInteractionScore()             { return interactionScore; }
    public void    setInteractionScore(Double v)     { this.interactionScore = v; }
    public Double  getProductQuotationScore()        { return productQuotationScore; }
    public void    setProductQuotationScore(Double v){ this.productQuotationScore = v; }
}


// ══════════════════════════════════════════════════════════════════════════════
//  MODEL 2 — NormalizedLeadQualInput
//  All 20 features are integers, ready to be passed as float array to SurrealDB.
//  leadId is carried for DB write-back but stripped from the ML payload.
// ══════════════════════════════════════════════════════════════════════════════

@JsonInclude(JsonInclude.Include.NON_NULL)
class NormalizedLeadQualInput {

    // Carried for DB write-back — NOT included in ml::lead_qualification<1.0.0> call
    private String leadId;

    // ── Binary (kept as-is) ───────────────────────────────────────────────────
    @JsonProperty("has_action_milestone")
    private Integer hasActionMilestone;   // [0]  0 or 1

    @JsonProperty("is_repeat_customer")
    private Integer isRepeatCustomer;     // [3]  0 or 1: derived historical_deals_won > 0

    @JsonProperty("is_multi_channel")
    private Integer isMultiChannel;       // [8]  0 or 1: derived distinct channels > 1

    @JsonProperty("quotation_sent")
    private Integer quotationSent;        // [11] 0 or 1

    @JsonProperty("is_enterprise_deal")
    private Integer isEnterpriseDeal;     // [12] 0 or 1: base_price >= 400,000

    // ── IQR-binned (1=Low / 2=Medium / 3=High) ───────────────────────────────
    @JsonProperty("stage_velocity")
    private Integer stageVelocity;        // [1]  Q1=0.48  Q3=1.86

    @JsonProperty("historical_deals_won")
    private Integer historicalDealsWon;   // [2]  Q1=0.0   Q3=3.0

    @JsonProperty("industry_close_rate")
    private Integer industryCloseRate;    // [4]  Q1=0.424 Q3=0.594

    @JsonProperty("historical_avg_sentiment")
    private Integer historicalAvgSentiment; // [5] Q1=-0.20 Q3=0.48

    @JsonProperty("total_interactions")
    private Integer totalInteractions;    // [7]  Q1=4     Q3=10

    @JsonProperty("engagement_depth")
    private Integer engagementDepth;      // [10] Q1=3.0   Q3=5.0

    @JsonProperty("days_in_pipeline")
    private Integer daysInPipeline;       // [14] Q1=5     Q3=25

    @JsonProperty("pipeline_velocity")
    private Integer pipelineVelocity;     // [15] Q1=0.10  Q3=0.50

    @JsonProperty("total_price_with_tax")
    private Integer totalPriceWithTax;    // [16] Q1=50000 Q3=300000

    // ── Custom encoded ────────────────────────────────────────────────────────
    @JsonProperty("intent")
    private Integer intent;               // [6]  1-10 raw intent → rebinned 1(1-2)/2(3-7)/3(8-10)

    @JsonProperty("recency_bucket")
    private Integer recencyBucket;        // [9]  1=cold(>21d) 2=stale(≤21d) 3=active(≤7d) 4=fresh(≤3d)

    @JsonProperty("pipeline_stage")
    private Integer pipelineStage;        // [13] label encoded 1-12 (alphabetical stage names)

    // ── Score tiers (derived from already-computed lead sub-scores) ───────────
    @JsonProperty("consumer_score_tier")
    private Integer consumerScoreTier;          // [17] <40→1(Low) 40-70→2(Mid) >70→3(High)

    @JsonProperty("interaction_score_tier")
    private Integer interactionScoreTier;       // [18] same thresholds

    @JsonProperty("product_quotation_score_tier")
    private Integer productQuotationScoreTier;  // [19] same thresholds

    // ── Getters & Setters ─────────────────────────────────────────────────────
    public String  getLeadId()                          { return leadId; }
    public void    setLeadId(String v)                   { this.leadId = v; }
    public Integer getHasActionMilestone()               { return hasActionMilestone; }
    public void    setHasActionMilestone(Integer v)      { this.hasActionMilestone = v; }
    public Integer getStageVelocity()                    { return stageVelocity; }
    public void    setStageVelocity(Integer v)           { this.stageVelocity = v; }
    public Integer getHistoricalDealsWon()               { return historicalDealsWon; }
    public void    setHistoricalDealsWon(Integer v)      { this.historicalDealsWon = v; }
    public Integer getIsRepeatCustomer()                 { return isRepeatCustomer; }
    public void    setIsRepeatCustomer(Integer v)        { this.isRepeatCustomer = v; }
    public Integer getIndustryCloseRate()                { return industryCloseRate; }
    public void    setIndustryCloseRate(Integer v)       { this.industryCloseRate = v; }
    public Integer getHistoricalAvgSentiment()           { return historicalAvgSentiment; }
    public void    setHistoricalAvgSentiment(Integer v)  { this.historicalAvgSentiment = v; }
    public Integer getIntent()                           { return intent; }
    public void    setIntent(Integer v)                  { this.intent = v; }
    public Integer getTotalInteractions()                { return totalInteractions; }
    public void    setTotalInteractions(Integer v)       { this.totalInteractions = v; }
    public Integer getIsMultiChannel()                   { return isMultiChannel; }
    public void    setIsMultiChannel(Integer v)          { this.isMultiChannel = v; }
    public Integer getRecencyBucket()                    { return recencyBucket; }
    public void    setRecencyBucket(Integer v)           { this.recencyBucket = v; }
    public Integer getEngagementDepth()                  { return engagementDepth; }
    public void    setEngagementDepth(Integer v)         { this.engagementDepth = v; }
    public Integer getQuotationSent()                    { return quotationSent; }
    public void    setQuotationSent(Integer v)           { this.quotationSent = v; }
    public Integer getIsEnterpriseDeal()                 { return isEnterpriseDeal; }
    public void    setIsEnterpriseDeal(Integer v)        { this.isEnterpriseDeal = v; }
    public Integer getPipelineStage()                    { return pipelineStage; }
    public void    setPipelineStage(Integer v)           { this.pipelineStage = v; }
    public Integer getDaysInPipeline()                   { return daysInPipeline; }
    public void    setDaysInPipeline(Integer v)          { this.daysInPipeline = v; }
    public Integer getPipelineVelocity()                 { return pipelineVelocity; }
    public void    setPipelineVelocity(Integer v)        { this.pipelineVelocity = v; }
    public Integer getTotalPriceWithTax()                { return totalPriceWithTax; }
    public void    setTotalPriceWithTax(Integer v)       { this.totalPriceWithTax = v; }
    public Integer getConsumerScoreTier()                { return consumerScoreTier; }
    public void    setConsumerScoreTier(Integer v)       { this.consumerScoreTier = v; }
    public Integer getInteractionScoreTier()             { return interactionScoreTier; }
    public void    setInteractionScoreTier(Integer v)    { this.interactionScoreTier = v; }
    public Integer getProductQuotationScoreTier()        { return productQuotationScoreTier; }
    public void    setProductQuotationScoreTier(Integer v){ this.productQuotationScoreTier = v; }
}


// ══════════════════════════════════════════════════════════════════════════════
//  MAPPER — LeadQualificationMapper
//
//  Converts RawLeadQualInput → NormalizedLeadQualInput (20 integer features).
//
//  Thresholds taken 1:1 from lead_qualification_normalized.csv IQR analysis
//  and cross-verified against setup_ml.surql fn::score_lead_qualification.
//
//  Transformation strategies:
//    1. BINARY      — 0/1 kept as-is (has_action_milestone, quotation_sent)
//    2. DERIVED BIN — 0/1 computed from raw value (is_repeat_customer, is_multi_channel, is_enterprise)
//    3. LABEL       — string → integer map (pipeline_stage 1-12, intent 1-10)
//    4. IQR BIN     — double → 1(Low)/2(Mid)/3(High)
//    5. INTENT REBIN — intent 1-10 → 1(1-2)/2(3-7)/3(8-10)
//    6. RECENCY     — days_since → 4-level bucket (1/2/3/4)
//    7. TIER        — score 0-100 → 1(<40)/2(40-70)/3(>70)
//    8. INDUSTRY    — string → close rate (double) → IQR bin
//    9. ENGAGEMENT  — total_interactions × sentiment_weight → IQR bin
// ══════════════════════════════════════════════════════════════════════════════

@Component
class LeadQualificationMapper {

    // ── IQR Thresholds — match training-time values from fn::score_lead_qualification ──

    // [1] stage_velocity = stage_ordinal / days_in_pipeline
    private static final double STAGE_VEL_Q1        = 0.48;
    private static final double STAGE_VEL_Q3        = 1.86;

    // [15] pipeline_velocity — same raw value, different IQR cut-offs from training
    private static final double PIPELINE_VEL_Q1     = 0.10;
    private static final double PIPELINE_VEL_Q3     = 0.50;

    // [2] historical_deals_won
    private static final double HIST_DEALS_Q1       = 0.0;
    private static final double HIST_DEALS_Q3       = 3.0;

    // [4] industry_close_rate
    private static final double INDUSTRY_CR_Q1      = 0.424;
    private static final double INDUSTRY_CR_Q3      = 0.594;

    // [5] historical_avg_sentiment (-1.0 to +1.0)
    private static final double HIST_SENTIMENT_Q1   = -0.20;
    private static final double HIST_SENTIMENT_Q3   =  0.48;

    // [7] total_interactions
    private static final double TOTAL_INTER_Q1      = 4.0;
    private static final double TOTAL_INTER_Q3      = 10.0;

    // [10] engagement_depth = total_interactions × (1 + avg_sentiment_scalar)
    private static final double ENGAGEMENT_Q1       = 3.0;
    private static final double ENGAGEMENT_Q3       = 5.0;

    // [14] days_in_pipeline
    private static final double DAYS_PIP_Q1         = 5.0;
    private static final double DAYS_PIP_Q3         = 25.0;

    // [16] total_price_with_tax
    private static final double PRICE_Q1            = 50_000.0;
    private static final double PRICE_Q3            = 300_000.0;

    // ── Score tier thresholds ─────────────────────────────────────────────────
    // Scores from consumer/interaction/product pipelines are stored as 0-100 percentage.
    // Spec: score < 40 → Low (1),  40-70 → Mid (2),  > 70 → High (3)
    private static final double TIER_LOW_MAX        = 40.0;  // < 40  → Low  (1)
    private static final double TIER_MID_MAX        = 70.0;  // 40-70 → Mid  (2)
                                                              // > 70  → High (3)

    // Enterprise deal threshold (from product.base_price in AED)
    private static final double ENTERPRISE_THRESHOLD = 400_000.0;

    // ── Categorical Encoding Maps ──────────────────────────────────────────────

    // pipeline_stage — LABEL ENCODED
    // FIX: Java does toUpperCase().replace(" ","_").replace("/","_") before lookup.
    // Added missing stages: FOLLOW_UP, QUOTATION_IN_DRAFT, and slash variants.
    // Maps SurrealDB lead.state UPPER_SNAKE_CASE values.
    private static final Map<String, Integer> PIPELINE_STAGE_MAP = Map.ofEntries(
        Map.entry("CLOSED",                       1),
        Map.entry("FOLLOW_UP",                    4),   // FIX: was missing
        Map.entry("FOLLOW_UP___NEGOTIATION",      4),   // "FOLLOW UP / NEGOTIATION" normalised
        Map.entry("FOLLOW_UP_NEGOTIATION",        4),
        Map.entry("FOLLOW_UP___NEGOT.",           4),   // legacy short form
        Map.entry("MANUAL_FOLLOW_UP",             6),
        Map.entry("NEW_LEAD",                     7),
        Map.entry("QUOTATION",                   10),
        Map.entry("QUOTATION_IN_DRAFT",          10),   // FIX: was missing
        Map.entry("QUOTATION_SENT",              10),   // DB variant
        Map.entry("SALES_FOLLOW_UP",             11),
        Map.entry("SALES_QUALIFIED",             12)
    );

    // intent — same map as ConsumerScoreMapper
    // FIX: added "non_sales" → information_seeking(6)
    private static final Map<String, Integer> INTENT_MAP = Map.ofEntries(
        Map.entry("at_risk",             1),
        Map.entry("churning",            2),
        Map.entry("closing",             3),
        Map.entry("comparison_shopping", 4),
        Map.entry("evaluating",          5),
        Map.entry("information_seeking", 6),
        Map.entry("negotiating",         7),
        Map.entry("ready_to_buy",        8),
        Map.entry("upsell_opportunity",  9),
        Map.entry("window_shopping",     10),
        Map.entry("non_sales",           6),   // FIX: was missing
        Map.entry("sales",               6)    // legacy alias
    );

    // industry → close_rate lookup (float 0.38–0.67)
    // FIX: added actual master_dataset industries that were falling back to 0.48 default
    private static final Map<String, Double> INDUSTRY_CLOSE_RATE_MAP = Map.ofEntries(
        // Original entries
        Map.entry("Data Centers",                0.67),
        Map.entry("Cold Chain Logistics",        0.62),
        Map.entry("Semiconductor Fabrication",   0.60),
        Map.entry("Dairy Processing",            0.58),
        Map.entry("Breweries & Beverages",       0.55),
        Map.entry("Food Processing",             0.55),
        Map.entry("Defence & Aerospace",         0.53),
        Map.entry("Pharmaceuticals",             0.52),
        Map.entry("Automotive",                  0.50),
        Map.entry("Hospitality",                 0.50),
        Map.entry("Chemicals",                   0.48),
        Map.entry("Real Estate",                 0.47),
        Map.entry("Oil & Gas",                   0.45),
        Map.entry("Power Generation",            0.45),
        Map.entry("Glass Manufacturing",         0.44),
        Map.entry("Paper & Pulp",                0.43),
        Map.entry("Steel Manufacturing",         0.42),
        Map.entry("Rubber & Tyres",              0.41),
        Map.entry("Plastics",                    0.40),
        Map.entry("Textiles",                    0.38),
        // FIX: added master_dataset industries — previously all fell back to 0.48
        Map.entry("Retail & Supermarkets",       0.48),
        Map.entry("Hospitals & Healthcare",      0.52),
        Map.entry("Hotels & Hospitality",        0.50),
        Map.entry("Food & Beverage",             0.55),
        Map.entry("IT / SaaS",                   0.48),
        Map.entry("Education",                   0.48)
    );

    private static final Map<String, Double> SENTIMENT_WEIGHT_MAP =
            Map.ofEntries(
                Map.entry("POSITIVE",      1.0),
                Map.entry("SATISFIED",     1.0),
                Map.entry("INTERESTED",    0.8),
                Map.entry("URGENT",        0.75),
                Map.entry("NEGOTIATING",   0.5),
                Map.entry("CURIOUS",       0.3),
                Map.entry("NEUTRAL",       0.0),
                Map.entry("DISAPPOINTED", -0.5),
                Map.entry("DISSATISFIED", -0.5),  // FIX: was missing — DB uses DISSATISFIED
                Map.entry("FRUSTRATED",   -0.5),
                Map.entry("ANGRY",        -1.0),
                Map.entry("NEGATIVE",     -1.0)
            );


    // ── Main normalize() entry point ──────────────────────────────────────────
    public NormalizedLeadQualInput normalize(RawLeadQualInput raw) {
        // If the entire raw object is null, return a default empty norm
        if (raw == null) return new NormalizedLeadQualInput();

        // FIX: sanitizeDefaults was defined but never called — null fields would throw
        // NormalizationException instead of using safe defaults
        sanitizeDefaults(raw);

        NormalizedLeadQualInput norm = new NormalizedLeadQualInput();
        norm.setLeadId(raw.getLeadId());

        // --- Helper for null-safe unboxing ---
        double basePrice = (raw.getBasePrice() != null) ? raw.getBasePrice() : 0.0;
        int dealsWon = (raw.getHistoricalDealsWon() != null) ? raw.getHistoricalDealsWon() : 0;
        double stageVel = (raw.getStageVelocityRaw() != null) ? raw.getStageVelocityRaw() : 0.0;
        int totalInters = (raw.getTotalInteractions() != null) ? raw.getTotalInteractions() : 0;
        double daysSinceMsg = (raw.getDaysSinceLastMessage() != null) ? raw.getDaysSinceLastMessage() : 99.0;

        // [0] has_action_milestone
        norm.setHasActionMilestone(mapBinary("has_action_milestone", raw.getHasActionMilestone()));

        // [1] stage_velocity
        norm.setStageVelocity(iqrBin("stage_velocity", stageVel, STAGE_VEL_Q1, STAGE_VEL_Q3));

        // [2] historical_deals_won
        norm.setHistoricalDealsWon(iqrBin("historical_deals_won", (double) dealsWon, HIST_DEALS_Q1, HIST_DEALS_Q3));

        // [3] is_repeat_customer (FIX: null-safe check)
        norm.setIsRepeatCustomer(dealsWon > 0 ? 1 : 0);

        // [4] industry_close_rate
        String ind = (raw.getIndustry() != null) ? raw.getIndustry().trim() : "";
        double closeRateRaw = INDUSTRY_CLOSE_RATE_MAP.getOrDefault(ind, 0.48);
        norm.setIndustryCloseRate(iqrBin("industry_close_rate", closeRateRaw, INDUSTRY_CR_Q1, INDUSTRY_CR_Q3));

        // [5] historical_avg_sentiment
        double histSent = (raw.getHistoricalAvgSentiment() != null) ? raw.getHistoricalAvgSentiment() : 0.0;
        norm.setHistoricalAvgSentiment(iqrBin("historical_avg_sentiment", histSent, HIST_SENTIMENT_Q1, HIST_SENTIMENT_Q3));

        // [6] intent
        int intentRaw = encodeLabel("intent", raw.getIntent(), INTENT_MAP);
        norm.setIntent(rebinIntent(intentRaw));

        // [7] total_interactions
        norm.setTotalInteractions(iqrBin("total_interactions", (double) totalInters, TOTAL_INTER_Q1, TOTAL_INTER_Q3));

        // [8] is_multi_channel
        int wa = (raw.getWhatsappCount() != null) ? raw.getWhatsappCount() : 0;
        int ph = (raw.getPhoneCount() != null) ? raw.getPhoneCount() : 0;
        int em = (raw.getEmailCount() != null) ? raw.getEmailCount() : 0;
        norm.setIsMultiChannel((wa > 0 ? 1 : 0) + (ph > 0 ? 1 : 0) + (em > 0 ? 1 : 0) > 1 ? 1 : 0);

        // [9] recency_bucket
        norm.setRecencyBucket(computeRecencyBucket(daysSinceMsg));

        // [10] engagement_depth = total_interactions × (1 + sentiment_scalar)
        // sentWeight is the raw sentiment scalar (-1.0 to +1.0), same as avg_sentiment in Interaction model
        String sentStr = (raw.getSentiment() != null) ? raw.getSentiment().toUpperCase().trim() : "NEUTRAL";
        double sentWeight = SENTIMENT_WEIGHT_MAP.getOrDefault(sentStr, 0.0);
        double engagementRaw = totalInters * (1.0 + sentWeight);
        norm.setEngagementDepth(iqrBin("engagement_depth", engagementRaw, ENGAGEMENT_Q1, ENGAGEMENT_Q3));

        // [11] quotation_sent
        norm.setQuotationSent(mapBinary("quotation_sent", raw.getQuotationSent()));

        // [12] is_enterprise_deal
        norm.setIsEnterpriseDeal(basePrice >= 400000.0 ? 1 : 0);

        // [13] pipeline_stage
        // FIX: normalise to UPPER_SNAKE_CASE — handles "Follow up / Negotiation" → "FOLLOW_UP___NEGOTIATION"
        String stageRaw = (raw.getPipelineStage() != null) ? raw.getPipelineStage() : "NEW_LEAD";
        String stageKey = stageRaw.toUpperCase().trim()
                                  .replace(" ", "_")
                                  .replace("/", "_")
                                  .replaceAll("_+", "_");
        norm.setPipelineStage(PIPELINE_STAGE_MAP.getOrDefault(stageKey, 7));

        // [14] days_in_pipeline
        double daysPip = (raw.getDaysInPipeline() != null) ? raw.getDaysInPipeline() : 1.0;
        norm.setDaysInPipeline(iqrBin("days_in_pipeline", daysPip, DAYS_PIP_Q1, DAYS_PIP_Q3));

        // [15] pipeline_velocity
        norm.setPipelineVelocity(iqrBin("pipeline_velocity", stageVel, PIPELINE_VEL_Q1, PIPELINE_VEL_Q3));

        // [16] total_price_with_tax
        double totalPrice = (raw.getTotalPriceWithTax() != null) ? raw.getTotalPriceWithTax() : 0.0;
        norm.setTotalPriceWithTax(iqrBin("total_price_with_tax", totalPrice, PRICE_Q1, PRICE_Q3));

        // [17-19] Score tiers
        norm.setConsumerScoreTier(computeScoreTier(raw.getConsumerScore()));
        norm.setInteractionScoreTier(computeScoreTier(raw.getInteractionScore()));
        norm.setProductQuotationScoreTier(computeScoreTier(raw.getProductQuotationScore()));

        return norm;
    }


    // ── Transformation helpers ─────────────────────────────────────────────────

    // BINARY: validates 0 or 1
    private int mapBinary(String field, Integer value) {
        if (value == null)
            throw new NormalizationException(field + ": must not be null");
        if (value != 0 && value != 1)
            throw new NormalizationException(field + ": must be 0 or 1, got: " + value);
        return value;
    }

    // LABEL: string → integer via map, trims + uppercases input
    private int encodeLabel(String field, String rawValue, Map<String, Integer> map) {
        if (rawValue == null || rawValue.isBlank())
            throw new NormalizationException(field + ": must not be null or blank");
        Integer encoded = map.get(rawValue.trim().toLowerCase());
        if (encoded == null)
            throw new NormalizationException(
                field + ": unrecognized value '" + rawValue + "'. Valid: " + map.keySet());
        return encoded;
    }

    // IQR BIN: double → 1 / 2 / 3
    private int iqrBin(String field, Double value, double q1, double q3) {
        if (value == null)
            throw new NormalizationException(field + ": must not be null");
        if (value <= q1)      return 1;
        else if (value <= q3) return 2;
        else                  return 3;
    }

    // INTENT REBIN: raw 1-10 → 1(1-2) / 2(3-7) / 3(8-10)
    private int rebinIntent(int intentRaw) {
        if (intentRaw <= 2) return 1;
        if (intentRaw <= 7) return 2;
        return 3;
    }

    // RECENCY BUCKET: days_since → fresh(4) / active(3) / stale(2) / cold(1)
    private int computeRecencyBucket(Double daysSince) {
        if (daysSince == null || daysSince <= 3.0)  return 4; // fresh
        if (daysSince <= 7.0)                        return 3; // active
        if (daysSince <= 21.0)                       return 2; // stale
        return 1;                                              // cold
    }

    // SCORE TIER: 0-100 score → 1(Low) / 2(Mid) / 3(High)
    private int computeScoreTier(Double score) {
        if (score == null || score < TIER_LOW_MAX) return 1;
        if (score <= TIER_MID_MAX)                  return 2;
        return 3;
    }

    // Integer → Double null-safe helper
    private Double toDouble(Integer v) { return v != null ? v.doubleValue() : null; }

    // Set safe defaults for null/missing raw fields to avoid NPE in encode/iqr methods
    private void sanitizeDefaults(RawLeadQualInput raw) {
        Objects.requireNonNull(raw, "RawLeadQualInput must not be null");

        if (raw.getLeadId() == null || raw.getLeadId().isBlank())
            throw new NormalizationException("lead_id is missing");

        if (raw.getPipelineStage()          == null) raw.setPipelineStage("NEW_LEAD");
        if (raw.getDaysInPipeline()         == null) raw.setDaysInPipeline(1.0);
        if (raw.getStageVelocityRaw()       == null) raw.setStageVelocityRaw(0.0);
        if (raw.getHasActionMilestone()     == null) raw.setHasActionMilestone(0);
        if (raw.getIntent()                 == null) raw.setIntent("information_seeking");
        if (raw.getHistoricalDealsWon()     == null) raw.setHistoricalDealsWon(0);
        if (raw.getHistoricalAvgSentiment() == null) raw.setHistoricalAvgSentiment(0.0);
        if (raw.getIndustry()               == null) raw.setIndustry("");
        if (raw.getSentiment()              == null) raw.setSentiment("NEUTRAL");
        if (raw.getTotalInteractions()      == null) raw.setTotalInteractions(0);
        if (raw.getWhatsappCount()          == null) raw.setWhatsappCount(0);
        if (raw.getPhoneCount()             == null) raw.setPhoneCount(0);
        if (raw.getEmailCount()             == null) raw.setEmailCount(0);
        if (raw.getDaysSinceLastMessage()   == null) raw.setDaysSinceLastMessage(99.0);
        if (raw.getQuotationSent()          == null) raw.setQuotationSent(0);
        if (raw.getBasePrice()              == null) raw.setBasePrice(0.0);
        if (raw.getTotalPriceWithTax()      == null) raw.setTotalPriceWithTax(0.0);
        if (raw.getConsumerScore()          == null) raw.setConsumerScore(0.0);
        if (raw.getInteractionScore()       == null) raw.setInteractionScore(0.0);
        if (raw.getProductQuotationScore()  == null) raw.setProductQuotationScore(0.0);
    }

    public static class NormalizationException extends RuntimeException {
        public NormalizationException(String message) { super(message); }
    }
}


// ══════════════════════════════════════════════════════════════════════════════
//  SURREAL DB SERVICE — LeadQualSurrealDbService
//
//  Handles all SurrealDB communication for lead qualification:
//    fetchLeadData()            — joins 6 tables + graph edge, returns RawLeadQualInput
//    callMlPredict()            — calls ml::lead_qualification<1.0.0>([f0..f19])
//    updateLeadWithPrediction() — writes lead_qualification_score to lead record
// ══════════════════════════════════════════════════════════════════════════════

@Service
class LeadQualSurrealDbService {

    private static final Logger log = LoggerFactory.getLogger(LeadQualSurrealDbService.class);

    @Autowired
    public SurrealDBClient db;
    
    @Autowired
    public ErrorLogService errorLog;

    @Value("${surrealdb.url}")                          private String surrealDbUrl;
    @Value("${surrealdb.namespace:db_salesai}")         private String namespace;
    @Value("${surrealdb.database:salesdb2}")            private String database;
    @Value("${surrealdb.username:root}")                private String username;
    @Value("${surrealdb.password:root}")                private String password;

    private final RestTemplate restTemplate;
    private final ObjectMapper  objectMapper;

    LeadQualSurrealDbService(RestTemplate restTemplate, ObjectMapper objectMapper) {
        this.restTemplate = restTemplate;
        this.objectMapper  = objectMapper;
    }


    // ── STEP 2: Fetch raw lead data from SurrealDB ────────────────────────────
    //
    // Joins 6 tables via LET + SELECT in a single SQL batch:
    //   lead, organisation, conversation (3× channel count queries + latest sentiment),
    //   generated_quotation, product (via ->interested_in->product graph edge),
    //   lead_state_history (has_action_milestone check)
    //
    // Also reads lead.consumer_score, lead.interaction_score,
    // lead.product_quotation_score — written by the 3 preceding model events.
    //
    public RawLeadQualInput fetchLeadDataForLeadQualiFication(String leadId) {
        String lid = leadId.startsWith("lead:") ? leadId : "lead:" + leadId;


        
        
        String sql = """
-- [1] Core record refs
LET $lead_rec = type::record('%s');
LET $lid      = type::string($lead_rec);
LET $org      = IF $lead_rec.organisation != NONE THEN (SELECT * FROM ONLY $lead_rec.organisation) ELSE NONE END;
LET $now      = time::now();

-- [2] Cross-channel: resolve all linked leads via contact_id
LET $contact_id = $lead_rec.contact_id;

-- FIX 1: Ensure result is [] if no contact_id or no leads found
LET $linked_leads_raw = IF $contact_id != NONE THEN
    (SELECT VALUE lead_ids FROM customer_contact WHERE $contact_id IN contact_ids LIMIT 1)[0]
    ELSE [] END;

-- FIX 2: Coalesce to [] to prevent array::concat crash
LET $linked_leads = array::distinct(array::concat(($linked_leads_raw ?? []), [$lead_rec]));

-- FIX 3: Coalesce to [] to prevent array::map crash
LET $linked_lids = array::map(($linked_leads ?? []), |$r| type::string($r));

-- [3] Aggregate conversation metrics
LET $convs = SELECT channel.type AS ch_type, sentiment, last_message_at FROM conversation
             WHERE type::string(lead) IN $linked_lids;

-- FIX 4: Use ?? [] for safety if no conversations exist
LET $convs = $convs ?? [];

LET $last_conv = (SELECT sentiment, last_message_at FROM $convs
                  ORDER BY last_message_at DESC LIMIT 1)[0];

-- [4] Pipeline Metrics
LET $days_pip = math::max([
    math::floor(duration::secs($now - ($lead_rec.created_at ?? $now)) / 86400),
    1
]);

LET $state = $lead_rec.state;
LET $stage_ord = IF $state = "NEW_LEAD" THEN 0
    ELSE IF $state = "MANUAL_FOLLOW_UP"       THEN 1
    ELSE IF $state = "SALES_FOLLOW_UP"        THEN 2
    ELSE IF $state = "SALES_QUALIFIED"        THEN 3
    ELSE IF $state = "QUOTATION"
         OR $state = "QUOTATION_IN_DRAFT"
         OR $state = "QUOTATION_SENT"         THEN 4
    ELSE IF $state = "FOLLOW_UP"
         OR $state = "FOLLOW_UP_NEGOTIATION"  THEN 5
    ELSE IF $state = "CLOSED"                 THEN 6
    ELSE 0 END;

-- [5] Product & Quotation Metrics
LET $prod = (SELECT VALUE out FROM interested_in WHERE type::string(in) IN $linked_lids LIMIT 1)[0];
LET $quotation_count = (SELECT count() FROM generated_quotation WHERE type::string(lead) IN $linked_lids GROUP ALL)[0].count ?? 0;

-- [6] Final Data Projection
SELECT
    $lid                                                                AS lead_id,
    $state                                                              AS pipeline_stage,
    type::float($days_pip)                                              AS days_in_pipeline,
    type::float($stage_ord) / type::float($days_pip)                    AS stage_velocity_raw,

    (IF array::len(
        SELECT VALUE id FROM lead_state_history
        WHERE lead_id IN $linked_lids
          AND to_state IN ['SALES_QUALIFIED','QUOTATION_SENT','CLOSED']
    ) > 0 THEN 1 ELSE 0 END)                                            AS has_action_milestone,

    type::int($org.historical_deals_won ?? 0)                           AS historical_deals_won,
    type::float($org.historical_avg_sentiment ?? 0.0)                   AS historical_avg_sentiment,
    ($org.industry ?? "")                                               AS industry,
    ($org.industry ?? "")                                               AS org_industry,
    ($last_conv.sentiment ?? "CURIOUS")                                 AS sentiment,

    array::len($convs)                                                  AS total_interactions,
    array::len(array::filter($convs, |$c| $c.ch_type = 'whatsapp'))      AS whatsapp_count,
    array::len(array::filter($convs, |$c| $c.ch_type = 'voice'
                                       OR $c.ch_type = 'phone'))        AS phone_count,
    array::len(array::filter($convs, |$c| $c.ch_type = 'email'
                                       OR $c.ch_type = 'web'))          AS email_count,

    duration::secs($now - ($last_conv.last_message_at ?? $now)) / 86400.0 AS days_since_last_message,

    (IF $quotation_count > 0 THEN 1 ELSE 0 END)                         AS quotation_sent,

    ($prod.exworks_price_aed ?? 0.0)                                    AS base_price,
    ($prod.exworks_price_aed ?? 0.0) * (1.0 + ($prod.vat_percent ?? 5.0) / 100.0) AS total_price_with_tax,
    ($prod.model ?? "unknown")                                          AS product_name,

    type::float(consumer_score ?? 0.0)                                  AS consumer_score,
    type::float(interaction_score ?? 0.0)                               AS interaction_score,
    type::float(product_quotation_score ?? 0.0)                         AS product_quotation_score,

    (classification ?? "information_seeking")                           AS intent

FROM $lead_rec;
            """.formatted(lid);
        
        try {
            // Option A: If your SurrealDBClient.query() already returns the result of the LAST statement:
            List<Map<String, Object>> results = db.queryMl(sql, Map.of());
            
            if (results != null && !results.isEmpty()) {
                // ObjectMapper.convertValue is the Map equivalent of treeToValue
                return objectMapper.convertValue(results.get(0), RawLeadQualInput.class);
            }
        } catch (Exception e) {
            log.error("Failed to fetch Lead Qualification data for {}: {}", lid, e.getMessage());
        }
        
        return new RawLeadQualInput(); 
    }


    // ── STEP 4: Call lead_qualification model in SurrealDB ────────────────────
    //
    // The ONNX model was trained on normalized_data.csv where ALL features are
    // scaled to [0.0, 1.0].  The NormalizedLeadQualInput stores IQR bins (1/2/3)
    // and other integer-encoded values for human-readable logging, so we must
    // re-scale them back to the 0-1 training range here before calling the model.
    //
    // Scaling rules verified against normalized_data.csv:
    //   bin3()      IQR 3-level bin (1/2/3)       → (bin-1)/2.0  → 0.0, 0.5, 1.0
    //   tier()      score tier     (1=Low/2=Mid/3=High) → same as bin3
    //   recency()   4-level bucket (1/2/3/4)       → (bucket-1)/3.0 → 0.0,0.33,0.67,1.0
    //   stage()     pipeline_stage (1–12)           → (stage-1)/11.0 → 0.0–1.0
    //   binary()    0 or 1                          → unchanged
    //
    private static double bin3(int v)    { return (v - 1) / 2.0; }
    private static double tier(int v)    { return (v - 1) / 2.0; }
    private static double recency(int v) { return (v - 1) / 3.0; }
    private static double stage(int v)   { return (v - 1) / 11.0; }

    public double callMlPredict(NormalizedLeadQualInput norm) {
        // Use Locale.US to ensure decimal points (0.85) instead of commas (0,85)
        String sql = String.format(Locale.US, """
            BEGIN TRANSACTION;

            LET $prediction = ml::lead_qualification<2.0.0>([
                %f,  -- [0]  has_action_milestone       binary 0/1
                %f,  -- [1]  stage_velocity             bin3: 0.0/0.5/1.0
                %f,  -- [2]  historical_deals_won       bin3: 0.0/0.5/1.0
                %f,  -- [3]  is_repeat_customer         binary 0/1
                %f,  -- [4]  industry_close_rate        bin3: 0.0/0.5/1.0
                %f,  -- [5]  historical_avg_sentiment   bin3: 0.0/0.5/1.0
                %f,  -- [6]  intent                     bin3: 0.0/0.5/1.0
                %f,  -- [7]  total_interactions         bin3: 0.0/0.5/1.0
                %f,  -- [8]  is_multi_channel           binary 0/1
                %f,  -- [9]  recency_bucket             0.0/0.33/0.67/1.0
                %f,  -- [10] engagement_depth           bin3: 0.0/0.5/1.0
                %f,  -- [11] quotation_sent             binary 0/1
                %f,  -- [12] is_enterprise_deal         binary 0/1
                %f,  -- [13] pipeline_stage             (label-1)/11 → 0.0–1.0
                %f,  -- [14] days_in_pipeline           bin3: 0.0/0.5/1.0
                %f,  -- [15] pipeline_velocity          bin3: 0.0/0.5/1.0
                %f,  -- [16] total_price_with_tax       bin3: 0.0/0.5/1.0
                %f,  -- [17] consumer_score_tier        0.0/0.5/1.0
                %f,  -- [18] interaction_score_tier     0.0/0.5/1.0
                %f   -- [19] product_quotation_score_tier 0.0/0.5/1.0
            ]);

            RETURN {
                model: "lead_qualification",
                score: $prediction
            };

            COMMIT TRANSACTION;
            """,
            (double) norm.getHasActionMilestone(),        // [0]  binary — no scaling
            bin3(norm.getStageVelocity()),                 // [1]
            bin3(norm.getHistoricalDealsWon()),            // [2]
            (double) norm.getIsRepeatCustomer(),           // [3]  binary — no scaling
            bin3(norm.getIndustryCloseRate()),             // [4]
            bin3(norm.getHistoricalAvgSentiment()),        // [5]
            bin3(norm.getIntent()),                        // [6]
            bin3(norm.getTotalInteractions()),             // [7]
            (double) norm.getIsMultiChannel(),             // [8]  binary — no scaling
            recency(norm.getRecencyBucket()),              // [9]
            bin3(norm.getEngagementDepth()),               // [10]
            (double) norm.getQuotationSent(),              // [11] binary — no scaling
            (double) norm.getIsEnterpriseDeal(),           // [12] binary — no scaling
            stage(norm.getPipelineStage()),                // [13]
            bin3(norm.getDaysInPipeline()),                // [14]
            bin3(norm.getPipelineVelocity()),              // [15]
            bin3(norm.getTotalPriceWithTax()),             // [16]
            tier(norm.getConsumerScoreTier()),             // [17]
            tier(norm.getInteractionScoreTier()),          // [18]
            tier(norm.getProductQuotationScoreTier())      // [19]
        );

        log.debug("[LeadQual ml::predict] lead={} payload=\n{}", norm.getLeadId(), sql);

        try {
            // Using SurrealDBClient instead of restTemplate
            List<Map<String, Object>> results = db.queryMl(sql,Map.of());
            
            return parsePredictionResult(results, norm.getLeadId());
        } catch (Exception e) {
            if (errorLog != null) {
                errorLog.log("ML_LEAD_QUAL_FAILED",
                    "lead_qualification prediction failed for lead=" + norm.getLeadId(),
                    norm.getLeadId(), null, e);
            }
            log.error("[ML lead_qualification] Failed lead={}: {}", norm.getLeadId(), e.getMessage());
            return 0.0;
        }
    }


    // ── STEP 5: Write lead_qualification_score back to lead record ─────────────
    public void updateLeadWithPrediction(String leadId, double score) {
        String sql = String.format(
            "UPDATE type::record('%s') SET lead_qualification_score = %f, updated_at = time::now();",
            leadId, score
        );
        HttpEntity<String> req = new HttpEntity<>(sql, buildHeaders());
        restTemplate.exchange(surrealDbUrl + "/sql", HttpMethod.POST, req, String.class);
    }


    // ── Private helpers ────────────────────────────────────────────────────────

    private HttpHeaders buildHeaders() {
        HttpHeaders h = new HttpHeaders();
        h.setContentType(MediaType.APPLICATION_JSON);
        h.setAccept(List.of(MediaType.APPLICATION_JSON));
        h.setBasicAuth(username, password);
        h.set("surreal-ns", namespace);
        h.set("surreal-db", database);
        return h;
    }

    private HttpHeaders buildHeadersVitasales() {
        HttpHeaders h = new HttpHeaders();
        h.setContentType(MediaType.APPLICATION_JSON);
        h.setAccept(List.of(MediaType.APPLICATION_JSON));
        h.setBasicAuth(username, password);
        h.set("surreal-ns", "vitasales");
        h.set("surreal-db", "vitasales");
        return h;
    }

    private <T> T parseFirstRow(String body, String leadId, Class<T> clazz) {
        try {
            JsonNode root = objectMapper.readTree(body);
            JsonNode last = root.get(root.size() - 1);
            if (last == null || !"OK".equals(last.path("status").asText()))
                throw new RuntimeException("SurrealDB query failed for lead ["
                    + leadId + "]: " + (last != null ? last.path("detail").asText() : "null"));
            JsonNode rows = last.path("result");
            if (!rows.isArray() || rows.isEmpty())
                throw new RuntimeException("No data found for lead [" + leadId + "]");
            return objectMapper.treeToValue(rows.get(0), clazz);
        } catch (Exception e) {
            throw new RuntimeException(
                "Failed to parse SurrealDB response for lead [" + leadId + "]: "
                + e.getMessage(), e);
        }
    }

    private double parsePredictionResult(List<Map<String, Object>> results, String leadId) {
        if (results == null || results.isEmpty()) {
            return 0.0;
        }

        try {
            // Since it's a transaction with a RETURN, find the map containing our model key
            for (Map<String, Object> row : results) {
                if (row != null && "lead_qualification".equals(row.get("model"))) {
                    Object scoreObj = row.get("score");
                    if (scoreObj == null) continue;
                    double raw = scoreObj instanceof List<?> list && !list.isEmpty()
                        ? Double.parseDouble(list.get(0).toString())
                        : Double.parseDouble(scoreObj.toString());
                    // Convert 0-1 probability → 0-100 percentage (spec: round(raw × 10000) / 100)
                   // return Math.round(raw * 10000.0) / 100.0;
                    return raw;
                }
            }
        } catch (Exception e) {
            log.error("Failed to parse lead_qualification ML result for lead {}: {}",
                leadId, e.getMessage());
        }
        return 0.0;
    }


// ══════════════════════════════════════════════════════════════════════════════
//  PIPELINE ORCHESTRATOR — LeadQualificationPipelineService
//  Ties steps 2-5 together for one lead.
// ══════════════════════════════════════════════════════════════════════════════

@Service
class LeadQualificationPipelineService {

    private static final Logger log = LoggerFactory.getLogger(LeadQualificationPipelineService.class);

    private final LeadQualSurrealDbService    surrealDbService;
    private final LeadQualificationMapper     mapper;

    LeadQualificationPipelineService(LeadQualSurrealDbService surrealDbService,
                                      LeadQualificationMapper mapper) {
        this.surrealDbService = surrealDbService;
        this.mapper           = mapper;
    }

    public void scoreLeadById(String leadId) {
        log.info("[LeadQual Pipeline] START lead={}", leadId);
        try {
            // Step 2: Fetch raw data (6 tables + graph edge)
            RawLeadQualInput raw = surrealDbService.fetchLeadDataForLeadQualiFication(leadId);
            log.debug("[Step 2] stage={} interactions={} consumerScore={} interactionScore={} pqScore={}",
                raw.getPipelineStage(), raw.getTotalInteractions(),
                raw.getConsumerScore(), raw.getInteractionScore(), raw.getProductQuotationScore());

            // Step 3: Normalize to 20 integer features
            NormalizedLeadQualInput normalized = mapper.normalize(raw);
            log.debug("[Step 3] pipelineStage={} stageVel={} pipelineVel={} recency={} tiers=[{},{},{}]",
                normalized.getPipelineStage(), normalized.getStageVelocity(),
                normalized.getPipelineVelocity(), normalized.getRecencyBucket(),
                normalized.getConsumerScoreTier(), normalized.getInteractionScoreTier(),
                normalized.getProductQuotationScoreTier());

            // Step 4: Call ml::lead_qualification<1.0.0> via SurrealDB
            double score = surrealDbService.callMlPredict(normalized);
            log.info("[Step 4] lead_qualification_score={}", String.format("%.4f", score));

            // Step 5: Write back to lead record
            surrealDbService.updateLeadWithPrediction(leadId, score);
            log.info("[LeadQual Pipeline] DONE lead={} score={}", leadId, String.format("%.4f", score));

        } catch (LeadQualificationMapper.NormalizationException e) {
            log.error("[LeadQual Pipeline] NORMALIZATION ERROR lead={}: {}", leadId, e.getMessage());
            throw new PipelineException("Normalization failed for lead [" + leadId + "]", e);
        } catch (Exception e) {
            log.error("[LeadQual Pipeline] ERROR lead={}: {}", leadId, e.getMessage(), e);
            throw new PipelineException("Pipeline failed for lead [" + leadId + "]", e);
        }
    }

    static class PipelineException extends RuntimeException {
        PipelineException(String message, Throwable cause) { super(message, cause); }
    }
}


// ══════════════════════════════════════════════════════════════════════════════
//  REST CONTROLLER — LeadQualificationController
//
//  Receives the SurrealDB trigger webhook and starts the pipeline.
//
//  SurrealDB event already defined in setup_ml.surql:
//    DEFINE EVENT score_lead_qualification_on_lead_change ON TABLE lead
//      WHEN $event = "UPDATE" AND (
//        $before.consumer_score          != $value.consumer_score  OR
//        $before.interaction_score       != $value.interaction_score OR
//        $before.product_quotation_score != $value.product_quotation_score OR
//        $before.state                   != $value.state
//      ) THEN { ... }
//
//  If calling this Java API instead of the SurrealDB internal function,
//  add an http::post() call inside that event body pointing to this endpoint.
// ══════════════════════════════════════════════════════════════════════════════

@RestController
@RequestMapping("/api/v1/lead-qualification")
class LeadQualificationController {

    private static final Logger log = LoggerFactory.getLogger(LeadQualificationController.class);

    private final LeadQualificationPipelineService pipelineService;

    LeadQualificationController(LeadQualificationPipelineService pipelineService) {
        this.pipelineService = pipelineService;
    }

    // SurrealDB trigger POSTs: { "lead_id": "lead:abc123", "event": "UPDATE" }
    @PostMapping("/trigger")
    public ResponseEntity<Map<String, Object>> handleTrigger(
            @RequestBody Map<String, String> payload) {
        String leadId = payload.get("lead_id");
        String event  = payload.getOrDefault("event", "UNKNOWN");
        log.info("[Trigger] event={} lead={}", event, leadId);
        if (leadId == null || leadId.isBlank())
            return ResponseEntity.badRequest().body(
                Map.of("status", "error", "message", "lead_id is required"));
        pipelineService.scoreLeadById(leadId);
        return ResponseEntity.ok(
            Map.of("status", "scored", "lead_id", leadId, "event", event));
    }

    // Manual trigger: POST /api/v1/lead-qualification/score/lead:abc123
    @PostMapping("/score/{leadId}")
    public ResponseEntity<Map<String, Object>> scoreById(@PathVariable String leadId) {
        log.info("[Manual] Scoring lead={}", leadId);
        pipelineService.scoreLeadById(leadId);
        return ResponseEntity.ok(Map.of("status", "scored", "lead_id", leadId));
    }

    // Health check
    @GetMapping("/health")
    public ResponseEntity<Map<String, String>> health() {
        return ResponseEntity.ok(Map.of("status", "UP"));
    }
}
}
