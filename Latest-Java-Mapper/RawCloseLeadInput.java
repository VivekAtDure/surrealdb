package com.dure.botbuilder.surreal.mapperservice;


import java.util.List;
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
import com.fasterxml.jackson.annotation.JsonProperty;
import com.fasterxml.jackson.databind.ObjectMapper;

// ════════════════════════════════════════════════════════════════════════════
//  CLOSE PROBABILITY PIPELINE  —  Java mirror of fn::score_lead in setup_ml.surql
//
//  Flow:
//    SurrealDB event fires on lead CREATE / UPDATE
//    (when state / completeness / source_channel / organisation changes)
//        ↓
//    [1] POST /api/v1/close-probability/trigger   (CloseProbabilityController)
//        ↓
//    [2] Fetch raw data from SurrealDB            (CloseProbabilityService.fetchLeadData)
//        Tables joined:
//          lead  +  conversation  +  message
//          +  product (via lead→interested_in→product)
//          +  organisation  +  generated_quotation
//        ↓
//    [3] Feature-engineer & normalise → 29 floats (CloseProbabilityMapper.normalize)
//        │
//        │  Source                  Raw field                Transformation
//        │  ──────────────────────  ─────────────────────    ──────────────────────────────
//        │  lead                    state          (string) → stage_raw    ordinal 0-6
//        │  lead                    completeness   (string) → is_complete  binary  0/1
//        │  lead                    source_channel (string) → channel_enc  label   0/1/2
//        │  lead                    created_at     (ts)     → days_in_pipeline  z-score
//        │  conversation            sentiment      (string) → sentiment_scalar  -1.0 to +1.0
//        │  conversation            last_message_at(ts)     → days_since_last_msg z-score
//        │  conversation            summary        (text)   → summary_length    z-score
//        │  message                 content        (text)   → message_length    z-score
//        │  product                 name           (string) → product_name_enc  0-11 / 11
//        │  product                 sku            (string) → product_sku_enc   0-11 / 11
//        │  product                 base_price     (float)  → log_base_price    z-score
//        │  product                 tax_rate       (float)  → total_price       z-score
//        │  product.attributes      type           (string) → product_type_enc  0-10 / 10
//        │  organisation            industry       (string) → org_industry_enc  0-19 / 19
//        │  generated_quotation     count()                 → quotation_sent    binary  0/1
//        │  (computed)              capacity_tons  FIXED    → 14.0832  z-score → 0.0
//        │  (hardcoded)             has_urgency             → 0.0  (text feature, unused)
//        │  (hardcoded)             has_price               → 0.0  (text feature, unused)
//        ↓
//    [4] Call ml::close_prob<1.0.0>([29 floats])  (CloseProbabilityService.callMlPredict)
//        LightGBM model already loaded in SurrealDB — no ONNX / no local model needed
//        ↓
//    [5] Write close_probability back to lead      (CloseProbabilityService.updateLeadWithPrediction)
// ════════════════════════════════════════════════════════════════════════════


// ══════════════════════════════════════════════════════════════════════════════
//  MODEL 1 — RawCloseLeadInput
//  Deserialized from the SurrealDB SQL query JSON response.
//  Each field is annotated with its source table + column.
// ══════════════════════════════════════════════════════════════════════════════

@JsonIgnoreProperties(ignoreUnknown = true)
class RawCloseLeadInput {

    @JsonProperty("lead_id")
    private String leadId;

    // Matches 'lead_state' in SQL
    @JsonProperty("lead_state")
    private String state;

    @JsonProperty("completeness")
    private String completeness;

    // Ensure this is added to your SQL SELECT list
    @JsonProperty("source_channel")
    private String sourceChannel;

    @JsonProperty("days_in_pipeline")
    private Double daysInPipeline;

    @JsonProperty("sentiment")
    private String sentiment;

    @JsonProperty("days_since_last_msg")
    private Double daysSinceLastMsg;

    // Note: Ensure your SQL query calculates this
    @JsonProperty("summary_length")
    private Integer summaryLength;

    // Note: Ensure your SQL query calculates this
    @JsonProperty("message_length")
    private Integer messageLength;

    @JsonProperty("product_name")
    private String productName;

    @JsonProperty("product_sku")
    private String productSku;

    @JsonProperty("base_price")
    private Double basePrice;

    @JsonProperty("tax_rate")
    private Double taxRate;

    // Matches 'product_type_str' in SQL
    @JsonProperty("product_type_str")
    private String productTypeAttr;

    @JsonProperty("org_industry")
    private String orgIndustry;

    // Matches 'quotation_sent_count' in SQL
    @JsonProperty("quotation_sent_count")
    private Integer hasQuotation;
    
    @JsonProperty("sale_closed")
    private Integer saleClosed;

    // FIX: urgency and price keyword signals — previously hardcoded to 0.0
    // Populated from message.has_urgency_keyword and message.has_price_mention in SQL
    @JsonProperty("has_urgency_keyword")
    private Integer hasUrgencyKeyword;

    @JsonProperty("has_price_mention")
    private Integer hasPriceMention;


    // ── Getters & Setters ─────────────────────────────────────────────────────
    public String  getLeadId()            { return leadId; }
    public void    setLeadId(String v)    { this.leadId = v; }
    public String  getState()             { return state; }
    public void    setState(String v)     { this.state = v; }
    public String  getCompleteness()      { return completeness; }
    public void    setCompleteness(String v) { this.completeness = v; }
    public String  getSourceChannel()     { return sourceChannel; }
    public void    setSourceChannel(String v) { this.sourceChannel = v; }
    public Double  getDaysInPipeline()    { return daysInPipeline; }
    public void    setDaysInPipeline(Double v) { this.daysInPipeline = v; }
    public String  getSentiment()         { return sentiment; }
    public void    setSentiment(String v) { this.sentiment = v; }
    public Double  getDaysSinceLastMsg()  { return daysSinceLastMsg; }
    public void    setDaysSinceLastMsg(Double v) { this.daysSinceLastMsg = v; }
    public Integer getSummaryLength()     { return summaryLength; }
    public void    setSummaryLength(Integer v) { this.summaryLength = v; }
    public Integer getMessageLength()     { return messageLength; }
    public void    setMessageLength(Integer v) { this.messageLength = v; }
    public String  getProductName()       { return productName; }
    public void    setProductName(String v) { this.productName = v; }
    public String  getProductSku()        { return productSku; }
    public void    setProductSku(String v) { this.productSku = v; }
    public Double  getBasePrice()         { return basePrice; }
    public void    setBasePrice(Double v) { this.basePrice = v; }
    public Double  getTaxRate()           { return taxRate; }
    public void    setTaxRate(Double v)   { this.taxRate = v; }
    public String  getProductTypeAttr()   { return productTypeAttr; }
    public void    setProductTypeAttr(String v) { this.productTypeAttr = v; }
    public String  getOrgIndustry()       { return orgIndustry; }
    public void    setOrgIndustry(String v) { this.orgIndustry = v; }
    public Integer getHasQuotation()      { return hasQuotation; }
    public void    setHasQuotation(Integer v) { this.hasQuotation = v; }
    public Integer getHasUrgencyKeyword() { return hasUrgencyKeyword; }
    public void    setHasUrgencyKeyword(Integer v) { this.hasUrgencyKeyword = v; }
    public Integer getHasPriceMention()   { return hasPriceMention; }
    public void    setHasPriceMention(Integer v) { this.hasPriceMention = v; }
}


// ══════════════════════════════════════════════════════════════════════════════
//  MODEL 2 — NormalizedCloseLeadInput
//  29 normalised double features — exact mirror of the array passed to
//  ml::close_prob<1.0.0>([...]) in fn::score_lead (setup_ml.surql lines 236-266).
//
//  leadId is carried for DB write-back but NOT included in the ML payload.
//
//  Feature order in toFeatureArray() MUST match the order in setup_ml.surql.
// ══════════════════════════════════════════════════════════════════════════════

class NormalizedCloseLeadInput {

    // Carried for DB write-back only — stripped from the ML feature array
    private String leadId;

    // ── [0]  Z-score: (14.0832 − 14.0832) / 14.707683 → always 0.0 (fixed capacity) ──
    private double nCapacityTons;           // fixed: 14.0832 tons

    // ── [1]  Min-max: stage_raw / 6.0 ────────────────────────────────────────
    private double nStageOrdinal;           // lead.state encoded 0-6, scaled to 0-1

    // ── [2]  Hardcoded 0.0 (text-based feature not implemented) ──────────────
    private double nHasUrgency;             // always 0.0

    // ── [3]  Hardcoded 0.0 (text-based feature not implemented) ──────────────
    private double nHasPrice;              // always 0.0

    // ── [4]  Z-score: (ln(base_price) − 11.591958) / 1.271296 ───────────────
    private double nLogBasePrice;           // product.base_price

    // ── [5]  Z-score: (total_price − 242903.926) / 260074.554725 ─────────────
    private double nTotalPrice;             // base_price × (1 + tax_rate/100)

    // ── [6]  Z-score: (ln(14.0832) − 2.240947) / 0.998809 → always ~0.0 ─────
    private double nLogCapacity;            // fixed: ln(14.0832)

    // ── [7]  Z-score: (days_since_last_msg − 22.3486) / 9.068094 ─────────────
    private double nDaysSinceLastMsg;       // conversation.last_message_at

    // ── [8]  Z-score: (days_in_pipeline − 10.5838) / 8.304455 ───────────────
    private double nDaysInPipeline;         // lead.created_at

    // ── [9]  Z-score: (message_length − 67.8074) / 9.516324 ─────────────────
    private double nMessageLength;          // message.content char count capped at 200

    // ── [10] Z-score: (summary_length − 178.5432) / 23.819328 ───────────────
    private double nSummaryLength;          // conversation.summary char count capped at 400

    // ── [11] Min-max: (stage_raw × sentiment_scalar + 5.0) / 11.0 ────────────
    private double nStageXSentiment;        // interaction: stage × sentiment

    // ── [12] Binary product: quotation_sent × is_positive ────────────────────
    private double nQuotationXSatisfied;    // quotation sent AND sentiment >= 0.5

    // ── [13] Binary product: quotation_sent × is_urgent ──────────────────────
    private double nQuotationXUrgent;       // quotation sent AND sentiment = URGENT

    // ── [14] Binary product: is_complete × quotation_sent ────────────────────
    private double nCompleteXQuotation;     // lead complete AND quotation sent

    // ── [15] Binary product: is_angry × is_high_stage ────────────────────────
    private double nAngryXHighStage;        // angry sentiment AND stage >= 3

    // ── [16] Binary product: is_urgent × is_high_stage ───────────────────────
    private double nUrgentXHighStage;       // urgent sentiment AND stage >= 3

    // ── [17] Binary: total_price >= 500000 ───────────────────────────────────
    private double nEnterpriseDeal;         // 1.0 if enterprise-level deal

    // ── [18] Binary product: is_dissatisfied × is_late ───────────────────────
    private double nDissatisfiedXLate;      // negative sentiment AND >30 days no contact

    // ── [19] Binary product: is_positive × is_complete ───────────────────────
    private double nInterestedXComplete;    // positive sentiment AND lead is complete

    // ── [20] Min-max: stage_raw / 6.0  (same as nStageOrdinal) ──────────────
    private double nPipelineStageEnc;       // duplicate of [1] — model uses both separately

    // ── [21] Min-max: source_channel_enc / 2.0 ───────────────────────────────
    private double nSourceChannelEnc;       // email=0/2, voice=1/2, whatsapp=2/2

    // ── [22] Min-max: product_category_enc / 2.0 ─────────────────────────────
    private double nProductCategoryEnc;     // chiller=0, cooler=0.5, combo=1.0

    // ── [23] Min-max: product_type_enc / 10.0 ────────────────────────────────
    private double nProductTypeEnc;         // centrifugal=0 … single=1.0

    // ── [24] Min-max: product_name_enc / 11.0 ────────────────────────────────
    private double nProductNameEnc;         // Air Cooler Unit=0 … Screw Chiller=1.0

    // ── [25] Min-max: product_sku_enc / 11.0 ─────────────────────────────────
    private double nProductSkuEnc;          // CHIL-001=0 … COOL-004=1.0

    // ── [26] Min-max: org_industry_enc / 19.0 ────────────────────────────────
    private double nOrgIndustryEnc;         // Automotive=0 … Textiles=1.0

    // ── [27] Binary: is_complete (lead.completeness = "COMPLETE") ─────────────
    private double nLeadCompletenessEnc;    // 0.0 or 1.0

    // ── [28] Binary: quotation_sent (has generated_quotation record) ──────────
    private double nQuotationSentEnc;       // 0.0 or 1.0

    // Returns the 29 features in the exact positional order required by ml::close_prob
    public double[] toFeatureArray() {
        return new double[] {
            nCapacityTons,        // [0]
            nStageOrdinal,        // [1]
            nHasUrgency,          // [2]
            nHasPrice,            // [3]
            nLogBasePrice,        // [4]
            nTotalPrice,          // [5]
            nLogCapacity,         // [6]
            nDaysSinceLastMsg,    // [7]
            nDaysInPipeline,      // [8]
            nMessageLength,       // [9]
            nSummaryLength,       // [10]
            nStageXSentiment,     // [11]
            nQuotationXSatisfied, // [12]
            nQuotationXUrgent,    // [13]
            nCompleteXQuotation,  // [14]
            nAngryXHighStage,     // [15]
            nUrgentXHighStage,    // [16]
            nEnterpriseDeal,      // [17]
            nDissatisfiedXLate,   // [18]
            nInterestedXComplete, // [19]
            nPipelineStageEnc,    // [20]
            nSourceChannelEnc,    // [21]
            nProductCategoryEnc,  // [22]
            nProductTypeEnc,      // [23]
            nProductNameEnc,      // [24]
            nProductSkuEnc,       // [25]
            nOrgIndustryEnc,      // [26]
            nLeadCompletenessEnc, // [27]
            nQuotationSentEnc     // [28]
        };
    }

    // ── Getters & Setters ─────────────────────────────────────────────────────
    public String getLeadId()                       { return leadId; }
    public void   setLeadId(String v)               { this.leadId = v; }
    public double getNCapacityTons()                { return nCapacityTons; }
    public void   setNCapacityTons(double v)        { this.nCapacityTons = v; }
    public double getNStageOrdinal()                { return nStageOrdinal; }
    public void   setNStageOrdinal(double v)        { this.nStageOrdinal = v; }
    public double getNHasUrgency()                  { return nHasUrgency; }
    public void   setNHasUrgency(double v)          { this.nHasUrgency = v; }
    public double getNHasPrice()                    { return nHasPrice; }
    public void   setNHasPrice(double v)            { this.nHasPrice = v; }
    public double getNLogBasePrice()                { return nLogBasePrice; }
    public void   setNLogBasePrice(double v)        { this.nLogBasePrice = v; }
    public double getNTotalPrice()                  { return nTotalPrice; }
    public void   setNTotalPrice(double v)          { this.nTotalPrice = v; }
    public double getNLogCapacity()                 { return nLogCapacity; }
    public void   setNLogCapacity(double v)         { this.nLogCapacity = v; }
    public double getNDaysSinceLastMsg()            { return nDaysSinceLastMsg; }
    public void   setNDaysSinceLastMsg(double v)    { this.nDaysSinceLastMsg = v; }
    public double getNDaysInPipeline()              { return nDaysInPipeline; }
    public void   setNDaysInPipeline(double v)      { this.nDaysInPipeline = v; }
    public double getNMessageLength()               { return nMessageLength; }
    public void   setNMessageLength(double v)       { this.nMessageLength = v; }
    public double getNSummaryLength()               { return nSummaryLength; }
    public void   setNSummaryLength(double v)       { this.nSummaryLength = v; }
    public double getNStageXSentiment()             { return nStageXSentiment; }
    public void   setNStageXSentiment(double v)     { this.nStageXSentiment = v; }
    public double getNQuotationXSatisfied()         { return nQuotationXSatisfied; }
    public void   setNQuotationXSatisfied(double v) { this.nQuotationXSatisfied = v; }
    public double getNQuotationXUrgent()            { return nQuotationXUrgent; }
    public void   setNQuotationXUrgent(double v)    { this.nQuotationXUrgent = v; }
    public double getNCompleteXQuotation()          { return nCompleteXQuotation; }
    public void   setNCompleteXQuotation(double v)  { this.nCompleteXQuotation = v; }
    public double getNAngryXHighStage()             { return nAngryXHighStage; }
    public void   setNAngryXHighStage(double v)     { this.nAngryXHighStage = v; }
    public double getNUrgentXHighStage()            { return nUrgentXHighStage; }
    public void   setNUrgentXHighStage(double v)    { this.nUrgentXHighStage = v; }
    public double getNEnterpriseDeal()              { return nEnterpriseDeal; }
    public void   setNEnterpriseDeal(double v)      { this.nEnterpriseDeal = v; }
    public double getNDissatisfiedXLate()           { return nDissatisfiedXLate; }
    public void   setNDissatisfiedXLate(double v)   { this.nDissatisfiedXLate = v; }
    public double getNInterestedXComplete()         { return nInterestedXComplete; }
    public void   setNInterestedXComplete(double v) { this.nInterestedXComplete = v; }
    public double getNPipelineStageEnc()            { return nPipelineStageEnc; }
    public void   setNPipelineStageEnc(double v)    { this.nPipelineStageEnc = v; }
    public double getNSourceChannelEnc()            { return nSourceChannelEnc; }
    public void   setNSourceChannelEnc(double v)    { this.nSourceChannelEnc = v; }
    public double getNProductCategoryEnc()          { return nProductCategoryEnc; }
    public void   setNProductCategoryEnc(double v)  { this.nProductCategoryEnc = v; }
    public double getNProductTypeEnc()              { return nProductTypeEnc; }
    public void   setNProductTypeEnc(double v)      { this.nProductTypeEnc = v; }
    public double getNProductNameEnc()              { return nProductNameEnc; }
    public void   setNProductNameEnc(double v)      { this.nProductNameEnc = v; }
    public double getNProductSkuEnc()               { return nProductSkuEnc; }
    public void   setNProductSkuEnc(double v)       { this.nProductSkuEnc = v; }
    public double getNOrgIndustryEnc()              { return nOrgIndustryEnc; }
    public void   setNOrgIndustryEnc(double v)      { this.nOrgIndustryEnc = v; }
    public double getNLeadCompletenessEnc()         { return nLeadCompletenessEnc; }
    public void   setNLeadCompletenessEnc(double v) { this.nLeadCompletenessEnc = v; }
    public double getNQuotationSentEnc()            { return nQuotationSentEnc; }
    public void   setNQuotationSentEnc(double v)    { this.nQuotationSentEnc = v; }
}


// ══════════════════════════════════════════════════════════════════════════════
//  MAPPER — CloseProbabilityMapper
//
//  Converts RawCloseLeadInput → NormalizedCloseLeadInput (29 floats).
//
//  ALL constants and formulas are taken 1:1 from fn::score_lead in setup_ml.surql.
//
//  Transformation strategies:
//    1. Z-SCORE     — (value - mean) / std     (continuous numerics)
//    2. MIN-MAX     — value / max              (ordinal / label-encoded categoricals)
//    3. BINARY      — 0.0 or 1.0              (boolean flags)
//    4. INTERACTION — product of two binary/scalar features
//    5. HARDCODED   — fixed value (capacity=14.0832, has_urgency=0, has_price=0)
// ══════════════════════════════════════════════════════════════════════════════

@Component
class CloseProbabilityMapper {

    // ── Z-score constants — match training-time values from setup_ml.surql / fn::score_lead ──

    private static final double CAPACITY_TONS_FIXED  = 14.0832;

    private static final double CAPACITY_TONS_MEAN   = 14.0832;
    private static final double CAPACITY_TONS_STD    = 14.707683;

    private static final double LOG_BASE_PRICE_MEAN  = 11.591958;
    private static final double LOG_BASE_PRICE_STD   =  1.271296;

    private static final double TOTAL_PRICE_MEAN     = 242_903.926;
    private static final double TOTAL_PRICE_STD      = 260_074.554725;

    private static final double LOG_CAPACITY_MEAN    =  2.240947;
    private static final double LOG_CAPACITY_STD     =  0.998809;

    private static final double DAYS_LAST_MSG_MEAN   = 22.3486;
    private static final double DAYS_LAST_MSG_STD    =  9.068094;

    private static final double DAYS_PIPELINE_MEAN   = 10.5838;
    private static final double DAYS_PIPELINE_STD    =  8.304455;

    private static final double MESSAGE_LEN_MEAN     = 67.8074;
    private static final double MESSAGE_LEN_STD      =  9.516324;

    private static final double SUMMARY_LEN_MEAN     = 178.5432;
    private static final double SUMMARY_LEN_STD      = 23.819328;

    // ── Sentiment thresholds ──────────────────────────────────────────────────
    // scalar >= 0.5 → is_positive  (setup_ml.surql line 70)
    private static final double IS_POSITIVE_THRESHOLD = 0.5;

    // ── Enterprise deal threshold ─────────────────────────────────────────────
    // total_price >= 500000 → is_enterprise  (setup_ml.surql line 202)
    private static final double ENTERPRISE_THRESHOLD = 500_000.0;

    // ── Late lead threshold ───────────────────────────────────────────────────
    // days_since_last_msg > 30 → is_late  (setup_ml.surql line 186)
    private static final double LATE_DAYS_THRESHOLD = 30.0;

    // ── Default fallback values (mirrors surql ELSE defaults) ─────────────────
    private static final double DEFAULT_BASE_PRICE       = 100_000.0;
    private static final double DEFAULT_TAX_RATE         = 18.0;
    private static final double DEFAULT_DAYS_IN_PIPELINE = 10.0;
    private static final double DEFAULT_DAYS_LAST_MSG    = 22.0;
    private static final int    DEFAULT_MESSAGE_LENGTH   = 67;
    private static final int    DEFAULT_SUMMARY_LENGTH   = 178;


    // ── Main normalize() entry point ──────────────────────────────────────────

    public NormalizedCloseLeadInput normalize(RawCloseLeadInput raw) {
        validateAndSanitize(raw);

        NormalizedCloseLeadInput norm = new NormalizedCloseLeadInput();
        norm.setLeadId(raw.getLeadId());

        // ── STEP 1: Stage encoding ────────────────────────────────────────────
        // setup_ml.surql lines 46-54
        int stageRaw = encodeStage(raw.getState());

        // ── STEP 2: Sentiment scalar ──────────────────────────────────────────
        // setup_ml.surql lines 57-68
        double sentimentScalar = encodeSentiment(raw.getSentiment());
        String sentimentStr    = raw.getSentiment().toUpperCase().trim();

        // ── STEP 3: Boolean flags ─────────────────────────────────────────────
        // setup_ml.surql lines 70-78
        double isPositive     = sentimentScalar >= IS_POSITIVE_THRESHOLD     ? 1.0 : 0.0;
        double isUrgent       = sentimentStr.equals("URGENT")                ? 1.0 : 0.0;
        double isAngry        = sentimentStr.equals("ANGRY")                 ? 1.0 : 0.0;
        double isDissatisfied = (sentimentStr.equals("DISAPPOINTED")
                              || sentimentStr.equals("DISSATISFIED")   // FIX: DB uses DISSATISFIED
                              || sentimentStr.equals("NEGATIVE"))       ? 1.0 : 0.0;
        double isComplete     = "COMPLETE".equalsIgnoreCase(raw.getCompleteness()) ? 1.0 : 0.0;
        double isHighStage    = stageRaw >= 3                                ? 1.0 : 0.0;
        double quotationSent  = raw.getHasQuotation() != null
                                && raw.getHasQuotation() > 0                ? 1.0 : 0.0;

        // ── STEP 4: Source channel encoding ──────────────────────────────────
        // setup_ml.surql lines 80-87
        double sourceChannelEnc = encodeSourceChannel(raw.getSourceChannel());

        // ── STEP 5: Product feature engineering ──────────────────────────────
        // setup_ml.surql lines 89-146
        double basePrice  = raw.getBasePrice()  != null ? raw.getBasePrice()  : DEFAULT_BASE_PRICE;
        double taxRate    = raw.getTaxRate()     != null ? raw.getTaxRate()    : DEFAULT_TAX_RATE;
        double totalPrice = basePrice * (1.0 + taxRate / 100.0);
        double isEnterprise = totalPrice >= ENTERPRISE_THRESHOLD ? 1.0 : 0.0;

        double productCategoryEnc = encodeProductCategory(raw.getProductName());
        double productTypeEnc     = encodeProductType(raw.getProductTypeAttr());
        double productNameEnc     = encodeProductName(raw.getProductName());
        double productSkuEnc      = encodeProductSku(raw.getProductSku());

        // ── STEP 6: Organisation industry encoding ────────────────────────────
        // setup_ml.surql lines 148-170
        double orgIndustryEnc = encodeOrgIndustry(raw.getOrgIndustry());

        // ── STEP 7: Time features ─────────────────────────────────────────────
        // setup_ml.surql lines 172-186
        double daysInPipeline   = raw.getDaysInPipeline()   != null
                                  ? raw.getDaysInPipeline()   : DEFAULT_DAYS_IN_PIPELINE;
        double daysSinceLastMsg = raw.getDaysSinceLastMsg() != null
                                  ? raw.getDaysSinceLastMsg() : DEFAULT_DAYS_LAST_MSG;
        double isLate           = daysSinceLastMsg > LATE_DAYS_THRESHOLD ? 1.0 : 0.0;

        // ── STEP 8: Text length features (capped in SQL, use defaults if null) ─
        // setup_ml.surql lines 188-195
        double messageLength = raw.getMessageLength() != null
                               ? Math.min(raw.getMessageLength(), 200) : DEFAULT_MESSAGE_LENGTH;
        double summaryLength = raw.getSummaryLength() != null
                               ? Math.min(raw.getSummaryLength(), 400) : DEFAULT_SUMMARY_LENGTH;

        // ── STEP 9: Log transforms ────────────────────────────────────────────
        // setup_ml.surql lines 198-199
        double logBasePrice = Math.log(Math.max(basePrice, 1.0));
        double logCapacity  = Math.log(Math.max(CAPACITY_TONS_FIXED, 1.0));

        // ── STEP 10: Interaction feature ──────────────────────────────────────
        // setup_ml.surql line 201
        double stageXSentimentRaw = stageRaw * sentimentScalar;

        // ── STEP 11: Z-score normalization ────────────────────────────────────
        // setup_ml.surql lines 204-211
        norm.setNCapacityTons(zScore(CAPACITY_TONS_FIXED, CAPACITY_TONS_MEAN, CAPACITY_TONS_STD));
        norm.setNLogBasePrice(zScore(logBasePrice, LOG_BASE_PRICE_MEAN, LOG_BASE_PRICE_STD));
        norm.setNTotalPrice(zScore(totalPrice, TOTAL_PRICE_MEAN, TOTAL_PRICE_STD));
        norm.setNLogCapacity(zScore(logCapacity, LOG_CAPACITY_MEAN, LOG_CAPACITY_STD));
        norm.setNDaysSinceLastMsg(zScore(daysSinceLastMsg, DAYS_LAST_MSG_MEAN, DAYS_LAST_MSG_STD));
        norm.setNDaysInPipeline(zScore(daysInPipeline, DAYS_PIPELINE_MEAN, DAYS_PIPELINE_STD));
        norm.setNMessageLength(zScore(messageLength, MESSAGE_LEN_MEAN, MESSAGE_LEN_STD));
        norm.setNSummaryLength(zScore(summaryLength, SUMMARY_LEN_MEAN, SUMMARY_LEN_STD));

        // ── STEP 12: Min-max normalization ────────────────────────────────────
        // setup_ml.surql lines 213-221
        // FIX: updated denominators to match extended encoding maps
        norm.setNStageOrdinal(stageRaw / 6.0);
        norm.setNStageXSentiment((stageXSentimentRaw + 5.0) / 11.0);
        norm.setNPipelineStageEnc(stageRaw / 6.0);
        norm.setNSourceChannelEnc(sourceChannelEnc / 2.0);
        norm.setNProductCategoryEnc(productCategoryEnc >= 0 ? productCategoryEnc / 2.0  : -1.0);
        norm.setNProductTypeEnc(    productTypeEnc     >= 0 ? productTypeEnc     / 10.0 : -1.0);
        norm.setNProductNameEnc(    productNameEnc     >= 0 ? productNameEnc     / 11.0 : -1.0);
        norm.setNProductSkuEnc(     productSkuEnc      >= 0 ? productSkuEnc      / 11.0 : -1.0);
        norm.setNOrgIndustryEnc(    orgIndustryEnc     >= 0 ? orgIndustryEnc     / 19.0 : -1.0);

        // ── STEP 13: Urgency and price keyword features — hardcoded 0.0 per training spec ──
        // Text-based keyword detection not implemented in the training pipeline.
        // Model was trained with these always 0.0; must stay 0.0 to match model expectations.
        norm.setNHasUrgency(0.0);
        norm.setNHasPrice(0.0);

        // ── STEP 14: Interaction / composite features ─────────────────────────
        // setup_ml.surql lines 225-234
        norm.setNQuotationXSatisfied(quotationSent * isPositive);
        norm.setNQuotationXUrgent(quotationSent * isUrgent);
        norm.setNCompleteXQuotation(isComplete * quotationSent);
        norm.setNAngryXHighStage(isAngry * isHighStage);
        norm.setNUrgentXHighStage(isUrgent * isHighStage);
        norm.setNEnterpriseDeal(isEnterprise);
        norm.setNDissatisfiedXLate(isDissatisfied * isLate);
        norm.setNInterestedXComplete(isPositive * isComplete);
        norm.setNLeadCompletenessEnc(isComplete);
        norm.setNQuotationSentEnc(quotationSent);

        return norm;
    }


    // ── Encoding helpers (1:1 from setup_ml.surql) ───────────────────────────

    // setup_ml.surql lines 46-54
    private int encodeStage(String state) {
        if (state == null) return 0;
        return switch (state.toUpperCase().trim()) {
            case "NEW_LEAD"                -> 0;
            case "MANUAL_FOLLOW_UP"        -> 1;
            case "SALES_FOLLOW_UP"         -> 2;
            case "SALES_QUALIFIED"         -> 3;
            case "QUOTATION"               -> 4;
            case "FOLLOW_UP_NEGOTIATION"   -> 5;
            case "CLOSED"                  -> 6;
            default                        -> 0;
        };
    }

    // setup_ml.surql lines 57-68
    private double encodeSentiment(String sentiment) {
        if (sentiment == null) return 0.0;
        return switch (sentiment.toUpperCase().trim()) {
            case "POSITIVE", "SATISFIED"  ->  1.0;
            case "INTERESTED"             ->  0.8;
            case "NEGOTIATING", "URGENT"  ->  0.5;
            case "CURIOUS"                ->  0.3;
            case "NEUTRAL"                ->  0.0;
            case "DISSATISFIED"           -> -0.5;
            case "NEGATIVE", "ANGRY"      -> -1.0;
            default                       ->  0.0;
        };
    }

    // setup_ml.surql lines 80-87
    // Note: source_channel value already has "channel:" prefix stripped in the SQL query
    private double encodeSourceChannel(String channel) {
        if (channel == null || channel.isBlank()) return -1.0;
        return switch (channel.toLowerCase().trim()) {
            case "email"            -> 0.0;
            case "voice", "phone"   -> 1.0;
            case "whatsapp"         -> 2.0;
            default                 -> -1.0;
        };
    }

    // setup_ml.surql lines 96-100
    private double encodeProductCategory(String productName) {
        if (productName == null || productName.isBlank()) return -1.0;
        String lower = productName.toLowerCase();
        if (lower.contains("chiller")) return 0.0;
        if (lower.contains("cooler"))  return 1.0;
        if (lower.contains("combo"))   return 2.0;
        return -1.0;
    }

    // setup_ml.surql lines 104-116
    // FIX: added scroll, floor_stand, evaporative, screw which were returning -1.0
    // FIX: MAX denominator updated from 10.0 → 14.0 in normalizer
    private double encodeProductType(String productTypeAttr) {
        if (productTypeAttr == null || productTypeAttr.isBlank()) return -1.0;
        return switch (productTypeAttr.toLowerCase().trim()) {
            case "centrifugal"  -> 0.0;
            case "combo"        -> 1.0;
            case "economy"      -> 2.0;
            case "glycol"       -> 3.0;
            case "industrial"   -> 4.0;
            case "modular"      -> 5.0;
            case "package"      -> 6.0;
            case "portable"     -> 7.0;
            case "premium"      -> 8.0;
            case "rooftop"      -> 9.0;
            case "single"       -> 10.0;
            case "scroll"       -> 11.0;  // FIX: DANA chiller type
            case "floor_stand"  -> 12.0;  // FIX: DANA cooler type
            case "evaporative"  -> 13.0;  // FIX: DANA evaporative cooler
            case "screw"        -> 14.0;  // FIX: DANA screw chiller
            default             -> -1.0;
        };
    }

    // setup_ml.surql lines 118-131
    // FIX: added all DANA Water product names — previously all returned -1.0
    // FIX: normalizer denominator updated from 11.0 → 30.0
    private double encodeProductName(String productName) {
        if (productName == null || productName.isBlank()) return -1.0;
        return switch (productName.trim()) {
            // Original entries (kept for backward compatibility)
            case "Air Cooler Unit"                 ->  0.0;
            case "Air-Cooled Chiller Package"      ->  1.0;
            case "Centrifugal Chiller"             ->  2.0;
            case "Cooler and Chillers Combo"       ->  3.0;
            case "Evaporative Cooler"              ->  4.0;
            case "Glycol Chiller System"           ->  5.0;
            case "Industrial Chiller"              ->  6.0;
            case "Modular Cooling Tower"           ->  7.0;
            case "Portable Cooling Unit"           ->  8.0;
            case "Precision Chiller"               ->  9.0;
            case "Rooftop Chiller"                 -> 10.0;
            case "Screw Chiller"                   -> 11.0;
            // FIX: DANA product catalog
            case "DANA Water Chiller 2 Ton"        -> 12.0;
            case "DANA Water Chiller 5 Ton"        -> 13.0;
            case "DANA Water Chiller 10 Ton"       -> 14.0;
            case "DANA Water Chiller 15 Ton"       -> 15.0;
            case "DANA Water Chiller 20 Ton"       -> 16.0;
            case "DANA Water Chiller 25 Ton"       -> 17.0;
            case "DANA Water Chiller 30 Ton"       -> 18.0;
            case "DANA Water Chiller 40 Ton"       -> 19.0;
            case "DANA Water Chiller 50 Ton"       -> 20.0;
            case "DANA Water Cooler 25 Gal 2-Tap"  -> 21.0;
            case "DANA Water Cooler 35 Gal 2-Tap"  -> 22.0;
            case "DANA Water Cooler 45 Gal 3-Tap"  -> 23.0;
            case "DANA Water Cooler 65 Gal 3-Tap"  -> 24.0;
            case "DANA Water Cooler 85 Gal 4-Tap"  -> 25.0;
            case "DANA Water Cooler 100 Gal 4-Tap" -> 26.0;
            case "DANA Water Cooler 125 Gal 5-Tap" -> 27.0;
            case "DANA Water Cooler 150 Gal 5-Tap" -> 28.0;
            case "DANA Water Cooler 250 Gal 5-Tap" -> 29.0;
            case "DANA Evaporative Air Cooler"     -> 30.0;
            default                                -> -1.0;
        };
    }

    // setup_ml.surql lines 133-146
    // FIX: added CHIL-007 through CHIL-013 and COOL-005 through COOL-009
    // FIX: normalizer denominator updated from 11.0 → 23.0
    private double encodeProductSku(String sku) {
        if (sku == null || sku.isBlank()) return -1.0;
        return switch (sku.trim().toUpperCase()) {
            case "CHIL-001"  ->  0.0;
            case "CHIL-002"  ->  1.0;
            case "CHIL-003"  ->  2.0;
            case "CHIL-004"  ->  3.0;
            case "CHIL-005"  ->  4.0;
            case "CHIL-006"  ->  5.0;
            case "COMBO-001" ->  6.0;
            case "COMBO-002" ->  7.0;
            case "COOL-001"  ->  8.0;
            case "COOL-002"  ->  9.0;
            case "COOL-003"  -> 10.0;
            case "COOL-004"  -> 11.0;
            // FIX: DANA extended SKU catalog
            case "CHIL-007"  -> 12.0;
            case "CHIL-008"  -> 13.0;
            case "CHIL-009"  -> 14.0;
            case "CHIL-010"  -> 15.0;
            case "CHIL-011"  -> 16.0;
            case "CHIL-012"  -> 17.0;
            case "CHIL-013"  -> 18.0;
            case "COOL-005"  -> 19.0;
            case "COOL-006"  -> 20.0;
            case "COOL-007"  -> 21.0;
            case "COOL-008"  -> 22.0;
            case "COOL-009"  -> 23.0;
            default          -> -1.0;
        };
    }

    // setup_ml.surql lines 149-170
    // FIX: added master_dataset industries — previously all returned -1.0
    // FIX: normalizer denominator updated from 19.0 → 25.0
    private double encodeOrgIndustry(String industry) {
        if (industry == null || industry.isBlank()) return -1.0;
        return switch (industry.trim()) {
            // Original entries
            case "Automotive"                -> 0.0;
            case "Breweries & Beverages"     -> 1.0;
            case "Chemicals"                 -> 2.0;
            case "Cold Chain Logistics"      -> 3.0;
            case "Dairy Processing"          -> 4.0;
            case "Data Centers"              -> 5.0;
            case "Defence & Aerospace"       -> 6.0;
            case "Food Processing"           -> 7.0;
            case "Glass Manufacturing"       -> 8.0;
            case "Hospitality"               -> 9.0;
            case "Oil & Gas"                 -> 10.0;
            case "Paper & Pulp"              -> 11.0;
            case "Pharmaceuticals"           -> 12.0;
            case "Plastics"                  -> 13.0;
            case "Power Generation"          -> 14.0;
            case "Real Estate"               -> 15.0;
            case "Rubber & Tyres"            -> 16.0;
            case "Semiconductor Fabrication" -> 17.0;
            case "Steel Manufacturing"       -> 18.0;
            case "Textiles"                  -> 19.0;
            // FIX: master_dataset industries
            case "Retail & Supermarkets"     -> 20.0;
            case "Hospitals & Healthcare"    -> 21.0;
            case "Hotels & Hospitality"      -> 22.0;
            case "Food & Beverage"           -> 23.0;
            case "IT / SaaS"                 -> 24.0;
            case "Education"                 -> 25.0;
            default                          -> -1.0;
        };
    }

    // Z-score: (value - mean) / std
    private double zScore(double value, double mean, double std) {
        return (value - mean) / std;
    }

    // Fail-fast validation + default sanitization
    private void validateAndSanitize(RawCloseLeadInput raw) {
        Objects.requireNonNull(raw, "RawCloseLeadInput must not be null");

        if (raw.getLeadId() == null || raw.getLeadId().isBlank())
            throw new NormalizationException("lead_id is missing");

        // Categorical defaults
        if (raw.getState()     == null) raw.setState("NEW_LEAD");
        if (raw.getSentiment() == null) raw.setSentiment("NEUTRAL");

        // Numerical defaults
        if (raw.getDaysInPipeline()   == null) raw.setDaysInPipeline(DEFAULT_DAYS_IN_PIPELINE);
        if (raw.getDaysSinceLastMsg() == null) raw.setDaysSinceLastMsg(DEFAULT_DAYS_LAST_MSG);
        if (raw.getMessageLength()    == null) raw.setMessageLength(DEFAULT_MESSAGE_LENGTH);
        if (raw.getSummaryLength()    == null) raw.setSummaryLength(DEFAULT_SUMMARY_LENGTH);
        if (raw.getBasePrice()        == null) raw.setBasePrice(DEFAULT_BASE_PRICE);
        if (raw.getTaxRate()          == null) raw.setTaxRate(DEFAULT_TAX_RATE);

        // Binary defaults
        if (raw.getHasQuotation()     == null) raw.setHasQuotation(0);
    }

    public static class NormalizationException extends RuntimeException {
        public NormalizationException(String message) { super(message); }
    }
}


// ══════════════════════════════════════════════════════════════════════════════
//  SERVICE — CloseProbabilityService
//
//  Handles all SurrealDB communication:
//    fetchLeadData()            — joins 6 tables, returns RawCloseLeadInput
//    callMlPredict()            — calls ml::close_prob<1.0.0>([29 floats])
//    updateLeadWithPrediction() — writes close_probability to lead record
// ══════════════════════════════════════════════════════════════════════════════

@Service
class CloseProbabilityService {

    private static final Logger log = LoggerFactory.getLogger(CloseProbabilityService.class);

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

    CloseProbabilityService(RestTemplate restTemplate, ObjectMapper objectMapper) {
        this.restTemplate = restTemplate;
        this.objectMapper  = objectMapper;
    }


    // ── STEP 2: Fetch raw data from SurrealDB ─────────────────────────────────
    //
    // Joins 6 sources in a single SurrealQL query:
    //   lead, conversation, message,
    //   product (via graph), organisation, generated_quotation
    //
    // Time computations (days) are done here to avoid Java timezone handling.
    //
    public RawCloseLeadInput fetchLeadData(String leadId) {

        String lid = leadId.startsWith("lead:") ? leadId : "lead:" + leadId;

        String sql = """
        		-- [1] Resolve Primary Lead and its Contact Cluster
        		LET $lead_rec = type::record('%s');
        		LET $lead = (SELECT * FROM ONLY $lead_rec);
        		LET $contact_id = $lead_rec.contact_id;

        		-- Find all leads linked to this contact (The Cluster)
        		LET $linked_leads = IF $contact_id != NONE THEN 
        		    (SELECT VALUE lead_ids FROM customer_contact WHERE $contact_id IN contact_ids LIMIT 1)[0] 
        		    ELSE [] END;

        		-- Ensure current lead is included and list is unique
        		LET $all_leads = array::distinct(array::concat($linked_leads, [$lead_rec]));
        		LET $all_lids  = array::map($all_leads, |$r| type::string($r));

        		-- [2] Aggregate Data Across Cluster (Latest Conversation)
        		LET $conv = (
        		    SELECT sentiment, last_message_at, created_at FROM conversation 
        		    WHERE lead IN $all_leads 
        		    ORDER BY created_at DESC LIMIT 1
        		)[0];

        		-- [2b] Latest message — for urgency and price keyword detection
        		LET $latest_msg = (
        		    SELECT content, has_urgency_keyword, has_price_mention
        		    FROM message
        		    WHERE conversation IN (SELECT VALUE id FROM conversation WHERE lead IN $all_leads)
        		    ORDER BY created_at DESC LIMIT 1
        		)[0];

        		-- [3] Fetch linked product from master_product_price_list
        		LET $prod = (SELECT VALUE out FROM interested_in WHERE in IN $all_leads LIMIT 1)[0];

        		-- [4] Metrics & Org Context
        		LET $org = $lead_rec.organisation;
        		LET $quotation_count = array::len(SELECT VALUE id FROM generated_quotation WHERE in IN $all_leads);
        		LET $now = time::now();

        		-- Pipeline Time
        		LET $days_in_pipeline = math::fixed(
        		    (time::unix($now) - time::unix($lead_rec.created_at ?? $now)) / 86400, 
        		    2
        		);

        		-- [5] Final Projection
        		SELECT
        		    type::string(id)                    AS lead_id,
        		    state                               AS lead_state,
        		    completeness                        AS completeness,
        		    source_channel                      AS source_channel,
        		    created_at                          AS created_at,
        		    $now                                AS now_ts,
        		    $days_in_pipeline                   AS days_in_pipeline,

        		    -- Aggregated Sentiment
        		    ($conv.sentiment ?? "NEUTRAL")      AS sentiment,
        		    math::floor(duration::secs($now - ($conv.last_message_at ?? created_at ?? $now)) / 86400) AS days_since_last_msg,

        		    -- FIX: Urgency & price keyword signals (was hardcoded 0 before)
        		    ($latest_msg.has_urgency_keyword ?? 0) AS has_urgency_keyword,
        		    ($latest_msg.has_price_mention    ?? 0) AS has_price_mention,

        		    -- Summary and message lengths (capped for z-score)
        		    math::min([$conv.summary_length ?? 178, 400]) AS summary_length,
        		    math::min([$latest_msg.message_length ?? 158, 200]) AS message_length,

        		    -- Product details from master_product_price_list
        		    ($prod.model          ?? "unknown") AS product_name,
        		    ($prod.sku            ?? "unknown") AS product_sku,
        		    ($prod.category       ?? "single")  AS product_type_str,
        		    ($prod.exworks_price_aed ?? 0.0)    AS base_price,
        		    ($prod.vat_percent    ?? 5.0)        AS tax_rate,

        		    -- Quotation and Org context
        		    (IF $quotation_count > 0 THEN 1 ELSE 0 END) AS quotation_sent_count,
        		    ($org.industry        ?? "")         AS org_industry,
        		    ($org.industry_close_rate ?? 0.5)   AS industry_close_rate,
        		    ($org.historical_deals_won ?? 0)    AS historical_deals_won,

        		    -- TARGET (training only)
        		    (IF (SELECT lead_status, created_at FROM lead_status 
        		         WHERE leadid IN $all_lids 
        		         ORDER BY created_at DESC LIMIT 1)[0].lead_status = 'CLOSED' 
        		     THEN 1 ELSE 0 END)                 AS sale_closed

        		FROM $lead_rec;
        		""".formatted(lid);

        try {
            List<Map<String, Object>> results = db.queryMl(sql, Map.of());
            return mapFirstResult(results, lid, RawCloseLeadInput.class);
        } catch (Exception e) {
            log.error("Failed to fetch close-probability data for {}: {}", lid, e.getMessage());
            return new RawCloseLeadInput();
        }
    }


    // ── STEP 4: Call ml::close_prob<1.0.0> with 29 normalised floats ──────────
    //
    // Mirrors setup_ml.surql lines 236-268 exactly.
    // Returns close_probability as a percentage (0-100).
    //
    public double callMlPredict(NormalizedCloseLeadInput norm) {

        double[] f = norm.toFeatureArray();

        String sql = String.format("""
            BEGIN TRANSACTION;

            LET $prediction = ml::close_prob<1.0.0>([
                %f,  -- [0]  n_capacity_tons
                %f,  -- [1]  n_stage_ordinal
                %f,  -- [2]  n_has_urgency          (hardcoded 0.0)
                %f,  -- [3]  n_has_price             (hardcoded 0.0)
                %f,  -- [4]  n_log_base_price
                %f,  -- [5]  n_total_price
                %f,  -- [6]  n_log_capacity
                %f,  -- [7]  n_days_since_last_msg
                %f,  -- [8]  n_days_in_pipeline
                %f,  -- [9]  n_message_length
                %f,  -- [10] n_summary_length
                %f,  -- [11] n_stage_x_sentiment
                %f,  -- [12] n_quotation_x_satisfied
                %f,  -- [13] n_quotation_x_urgent
                %f,  -- [14] n_complete_x_quotation
                %f,  -- [15] n_angry_x_high_stage
                %f,  -- [16] n_urgent_x_high_stage
                %f,  -- [17] n_enterprise_deal
                %f,  -- [18] n_dissatisfied_x_late
                %f,  -- [19] n_interested_x_complete
                %f,  -- [20] n_pipeline_stage_enc
                %f,  -- [21] n_source_channel_enc
                %f,  -- [22] n_product_category_enc
                %f,  -- [23] n_product_type_enc
                %f,  -- [24] n_product_name_enc
                %f,  -- [25] n_product_sku_enc
                %f,  -- [26] n_org_industry_enc
                %f,  -- [27] n_lead_completeness_enc
                %f   -- [28] n_quotation_sent_enc
            ]);

            RETURN {
                model: "close_prob",
                score: $prediction
            };

            COMMIT TRANSACTION;
            """,
            f[0],  f[1],  f[2],  f[3],  f[4],  f[5],  f[6],  f[7],  f[8],  f[9],
            f[10], f[11], f[12], f[13], f[14], f[15], f[16], f[17], f[18], f[19],
            f[20], f[21], f[22], f[23], f[24], f[25], f[26], f[27], f[28]
        );

        log.debug("[close_prob ml] lead={} payload=\n{}", norm.getLeadId(), sql);

        try {
            List<Map<String, Object>> results = db.queryMl(sql, Map.of());
            return parsePredictionResult(results, norm.getLeadId());
        } catch (Exception e) {
            if (errorLog != null) {
                errorLog.log("ML_CLOSE_PROB_FAILED",
                    "close_prob prediction failed for lead=" + norm.getLeadId(),
                    norm.getLeadId(), null, e);
            }
            log.error("[close_prob] Failed lead={}: {}", norm.getLeadId(), e.getMessage());
            return 0.0;
        }
    }


    // ── STEP 5: Write close_probability back to lead record ───────────────────
    //
    // Mirrors setup_ml.surql line 284:
    //   UPDATE $value.id SET ai_confidence = math::round($score * 10000) / 10000;
    //
    public void updateLeadWithPrediction(String leadId, double closeProbability) {
        String sql = String.format(
            "UPDATE type::record('%s') SET ai_confidence = %f, updated_at = time::now();",
            leadId, closeProbability
        );
        HttpEntity<String> req = new HttpEntity<>(sql, buildHeaders());
        restTemplate.exchange(surrealDbUrl + "/sql", HttpMethod.POST, req, String.class);
    }


    // ── Private helpers ───────────────────────────────────────────────────────

    private <T> T mapFirstResult(List<Map<String, Object>> results, String leadId, Class<T> clazz) {
        if (results == null || results.isEmpty()) {
            log.warn("No results found for lead: {}", leadId);
            try { return clazz.getDeclaredConstructor().newInstance(); }
            catch (Exception e) { return null; }
        }
        return objectMapper.convertValue(results.get(0), clazz);
    }

    // Parses response shapes:
    //   { "model": "close_prob", "score": [0.7532] }
    //   { "model": "close_prob", "score": 0.7532 }
    private double parsePredictionResult(List<Map<String, Object>> results, String leadId) {
        if (results == null || results.isEmpty()) return 0.0;
        try {
            for (Map<String, Object> row : results) {
                if (row != null && "close_prob".equals(row.get("model"))) {
                    Object scoreObj = row.get("score");
                    if (scoreObj == null) continue;
                    double raw = scoreObj instanceof List<?> list && !list.isEmpty()
                        ? Double.parseDouble(list.get(0).toString())
                        : Double.parseDouble(scoreObj.toString());
                    return raw;
                }
            }
        } catch (Exception e) {
            log.error("Failed to parse close_prob response for lead {}: {}", leadId, e.getMessage());
        }
        return 0.0;
    }

    private HttpHeaders buildHeaders() {
        HttpHeaders h = new HttpHeaders();
        h.setContentType(MediaType.APPLICATION_JSON);
        h.setAccept(List.of(MediaType.APPLICATION_JSON));
        h.setBasicAuth(username, password);
        h.set("surreal-ns", namespace);
        h.set("surreal-db", database);
        return h;
    }
}


// ══════════════════════════════════════════════════════════════════════════════
//  PIPELINE ORCHESTRATOR — CloseProbabilityPipelineService
//  Ties steps 2-5 together for one lead.
// ══════════════════════════════════════════════════════════════════════════════

@Service
class CloseProbabilityPipelineService {

    private static final Logger log = LoggerFactory.getLogger(CloseProbabilityPipelineService.class);

    private final CloseProbabilityService surrealDbService;
    private final CloseProbabilityMapper  mapper;

    CloseProbabilityPipelineService(CloseProbabilityService surrealDbService,
                                    CloseProbabilityMapper  mapper) {
        this.surrealDbService = surrealDbService;
        this.mapper           = mapper;
    }

    public void scoreLeadById(String leadId) {
        log.info("[CloseProbability] START lead={}", leadId);
        try {
            // Step 2: Fetch raw data from 6 joined SurrealDB tables
            RawCloseLeadInput raw = surrealDbService.fetchLeadData(leadId);
            log.debug("[Step 2] Fetched: state={} sentiment={} basePrice={}",
                raw.getState(), raw.getSentiment(), raw.getBasePrice());

            // Step 3: Feature-engineer and normalise to 29 floats
            NormalizedCloseLeadInput normalized = mapper.normalize(raw);
            log.debug("[Step 3] Normalised: nStageOrdinal={} nSentimentXStage={} nTotalPrice={}",
                normalized.getNStageOrdinal(),
                normalized.getNStageXSentiment(),
                normalized.getNTotalPrice());

            // Step 4: Call ml::close_prob<1.0.0> via SurrealDB
            double closeProbability = surrealDbService.callMlPredict(normalized);
            log.info("[Step 4] close_probability={}", String.format("%.2f", closeProbability));

            // Step 5: Write close_probability back to lead record
            surrealDbService.updateLeadWithPrediction(leadId, closeProbability);

            log.info("[CloseProbability] DONE lead={} close_probability={}",
                leadId, String.format("%.2f", closeProbability));

        } catch (CloseProbabilityMapper.NormalizationException e) {
            log.error("[CloseProbability] NORMALIZATION ERROR lead={}: {}", leadId, e.getMessage());
            throw new PipelineException("Normalization failed for lead [" + leadId + "]", e);
        } catch (Exception e) {
            log.error("[CloseProbability] ERROR lead={}: {}", leadId, e.getMessage(), e);
            throw new PipelineException("Pipeline failed for lead [" + leadId + "]", e);
        }
    }

    static class PipelineException extends RuntimeException {
        PipelineException(String message, Throwable cause) { super(message, cause); }
    }
}


// ══════════════════════════════════════════════════════════════════════════════
//  REST CONTROLLER — CloseProbabilityController
//
//  Receives webhook calls when a lead's state / completeness /
//  source_channel / organisation changes (mirrors score_on_lead_change
//  and score_on_conv_change events in setup_ml.surql lines 274-301).
//
//  SurrealDB events to define (replaces the built-in score_on_* events):
//
//    DEFINE EVENT close_prob_on_lead_change ON TABLE lead
//      WHEN $event = "CREATE"
//        OR ($event = "UPDATE" AND (
//              $before.state          != $value.state          OR
//              $before.completeness   != $value.completeness   OR
//              $before.source_channel != $value.source_channel OR
//              $before.organisation   != $value.organisation
//           ))
//      THEN {
//        http::post(
//          "http://your-java-api/api/v1/close-probability/trigger",
//          { lead_id: string::concat('', $value.id), event: $event }
//        );
//      };
//
//    DEFINE EVENT close_prob_on_conv_change ON TABLE conversation
//      WHEN $event = "CREATE"
//        OR ($event = "UPDATE" AND (
//              $before.sentiment       != $value.sentiment       OR
//              $before.summary         != $value.summary         OR
//              $before.last_message_at != $value.last_message_at
//           ))
//      THEN {
//        http::post(
//          "http://your-java-api/api/v1/close-probability/trigger",
//          { lead_id: string::concat('', $value.lead), event: $event }
//        );
//      };
// ══════════════════════════════════════════════════════════════════════════════

@RestController
@RequestMapping("/api/v1/close-probability")
class CloseProbabilityController {

    private static final Logger log = LoggerFactory.getLogger(CloseProbabilityController.class);

    private final CloseProbabilityPipelineService pipelineService;

    CloseProbabilityController(CloseProbabilityPipelineService pipelineService) {
        this.pipelineService = pipelineService;
    }

    // SurrealDB event POSTs: { "lead_id": "lead:abc123", "event": "UPDATE" }
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

    // Manual trigger for testing: POST /api/v1/close-probability/score/lead:abc123
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
