package com.dure.botbuilder.surreal.newmapperservice;



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
import com.fasterxml.jackson.annotation.JsonInclude;
import com.fasterxml.jackson.annotation.JsonProperty;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

// ════════════════════════════════════════════════════════════════════════════
//  CONSUMER SCORE PIPELINE  —  All logic in one file
//
//  Flow:
//    SurrealDB trigger fires on lead CREATE / UPDATE
//        ↓
//    [1] POST /api/v2/consumer-score/trigger      (ConsumerScoreController)
//        ↓
//    [2] Fetch raw data from SurrealDB tables      (SurrealDbService.fetchLeadData)
//        Joins: lead + conversation + message
//               + organisation + lead_state_history
//               + lead_status  + lead_stage
//        ↓
//    [3] Map DB JSON → Normalized integer JSON     (ConsumerScoreMapper.normalize)
//        │
//        │  Table                    Raw field                    Transformation
//        │  ────────────────────     ────────────────────────     ─────────────────────────
//        │  lead                     id                         → dropped
//        │  lead_status              lead_status == "CLOSED"    → sale_closed     binary 0/1
//        │  lead_state_history       to_state IN milestones     → has_action_milestone 0/1
//        │  lead_state_history       created_at + stage_order   → stage_velocity  IQR bin 1-3
//        │  conversation             sentiment (string)         → primary_sentiment label 1-7
//        │  conversation             sentiment_score (float)    → sentiment_score  IQR bin 1-3
//        │  conversation             sentiment_combo_score(int) → sentiment_combo_score IQR 1-3
//        │  conversation             len(summary)               → summary_length   IQR bin 1-3
//        │  message                  content length bucket      → message_quality  ordinal 1-4
//        │  lead                     classification (string)    → intent           label 1-10
//        │  organisation             historical_deals_won (int) → hist_deals_won   IQR bin 1-3
//        │  organisation             historical_deals_won >= 1  → is_repeat_customer 0/1
//        │  organisation             historical_avg_sentiment   → hist_avg_senti.  IQR bin 1-3
//        │  organisation             industry close rate        → industry_close_rate IQR 1-3
//        ↓
//    [4] Call SurrealDB ml::predict() with normalized JSON
//        (SurrealDbService.callMlPredict)
//        LightGBM model already loaded in SurrealDB via DEFINE MODEL — no ONNX needed
//        ↓
//    [5] Write consumer_score + predicted_closed back to lead record
//        (SurrealDbService.updateLeadWithPrediction)
// ════════════════════════════════════════════════════════════════════════════


// ══════════════════════════════════════════════════════════════════════════════
//  MODEL 1 — RawLeadInput
//  Deserialized from the SurrealDB SQL query JSON response.
//  Each field is annotated with its source table + field.
// ══════════════════════════════════════════════════════════════════════════════

@JsonIgnoreProperties(ignoreUnknown = true)
class RawLeadInput {

    // ── lead ──────────────────────────────────────────────────────────────────
    // lead.id — unique identifier, dropped before model input
    @JsonProperty("lead_id")
    private String leadId;

    // lead.classification — AI intent classifier output (string)
    // values: "at_risk"|"churning"|"closing"|"comparison_shopping"|"evaluating"
    //         |"information_seeking"|"negotiating"|"ready_to_buy"
    //         |"upsell_opportunity"|"window_shopping"
    @JsonProperty("intent")
    private String intent;

    // ── conversation ──────────────────────────────────────────────────────────
    // conversation.sentiment — AI sentiment classifier label (string)
    // values: "angry"|"curious"|"dissatisfied"|"interested"
    //         |"negotiating"|"satisfied"|"urgent"
    @JsonProperty("primary_sentiment")
    private String primarySentiment;

    // AI scoring pipeline output, float -1.0 to +1.0
    @JsonProperty("sentiment_score")
    private Double sentimentScore;

    // Weighted combination of message-level + conversation-level sentiment, int 0-10+
    @JsonProperty("sentiment_combo_score")
    private Integer sentimentComboScore;

    // len(conversation.summary) in characters
    @JsonProperty("summary_length")
    private Integer summaryLength;

    // ── message ───────────────────────────────────────────────────────────────
    // Bucket derived from message.content character count at extraction time
    // values: "short"|"medium"|"long"|"detailed"
    @JsonProperty("message_quality")
    private String messageQuality;

    // ── lead_state_history + lead_stage ───────────────────────────────────────
    // 1 if any lead_state_history.to_state is in milestone stages, else 0
    // milestone stages: SALES_QUALIFIED, QUOTATION_SENT, CLOSED
    @JsonProperty("has_action_milestone")
    private Integer hasActionMilestone;

    // (lead_stage.stage_order of to_state - stage_order of from_state)
    //  divided by hours elapsed between lead_state_history.created_at timestamps
    @JsonProperty("stage_velocity")
    private Double stageVelocity;

    // ── organisation ──────────────────────────────────────────────────────────
    // organisation.historical_deals_won — count of all past CLOSED deals for this org
    @JsonProperty("historical_deals_won")
    private Integer historicalDealsWon;

    // Derived: 1 if organisation.historical_deals_won >= 1, else 0
    @JsonProperty("is_repeat_customer")
    private Integer isRepeatCustomer;

    // organisation.historical_avg_sentiment — org-level avg sentiment, float -1.0 to +1.0
    @JsonProperty("historical_avg_sentiment")
    private Double historicalAvgSentiment;

    // Aggregated proportion of leads with state == CLOSED for this industry (float 0.0-1.0)
    @JsonProperty("industry_close_rate")
    private Double industryCloseRate;

    // ── lead_status ───────────────────────────────────────────────────────────
    // TARGET — 1 if most recent lead_status.lead_status == "CLOSED", else 0
    // Null during live inference, present in training data only
    @JsonProperty("sale_closed")
    private Integer saleClosed;

    public String  getLeadId()                 { return leadId; }
    public void    setLeadId(String v)          { this.leadId = v; }
    public String  getIntent()                  { return intent; }
    public void    setIntent(String v)          { this.intent = v; }
    public String  getPrimarySentiment()        { return primarySentiment; }
    public void    setPrimarySentiment(String v){ this.primarySentiment = v; }
    public Double  getSentimentScore()          { return sentimentScore; }
    public void    setSentimentScore(Double v)  { this.sentimentScore = v; }
    public Integer getSentimentComboScore()     { return sentimentComboScore; }
    public void    setSentimentComboScore(Integer v){ this.sentimentComboScore = v; }
    public Integer getSummaryLength()           { return summaryLength; }
    public void    setSummaryLength(Integer v)  { this.summaryLength = v; }
    public String  getMessageQuality()          { return messageQuality; }
    public void    setMessageQuality(String v)  { this.messageQuality = v; }
    public Integer getHasActionMilestone()      { return hasActionMilestone; }
    public void    setHasActionMilestone(Integer v){ this.hasActionMilestone = v; }
    public Double  getStageVelocity()           { return stageVelocity; }
    public void    setStageVelocity(Double v)   { this.stageVelocity = v; }
    public Integer getHistoricalDealsWon()      { return historicalDealsWon; }
    public void    setHistoricalDealsWon(Integer v){ this.historicalDealsWon = v; }
    public Integer getIsRepeatCustomer()        { return isRepeatCustomer; }
    public void    setIsRepeatCustomer(Integer v){ this.isRepeatCustomer = v; }
    public Double  getHistoricalAvgSentiment()  { return historicalAvgSentiment; }
    public void    setHistoricalAvgSentiment(Double v){ this.historicalAvgSentiment = v; }
    public Double  getIndustryCloseRate()       { return industryCloseRate; }
    public void    setIndustryCloseRate(Double v){ this.industryCloseRate = v; }
    public Integer getSaleClosed()              { return saleClosed; }
    public void    setSaleClosed(Integer v)     { this.saleClosed = v; }
}


// ══════════════════════════════════════════════════════════════════════════════
//  MODEL 2 — NormalizedLeadInput
//  All fields are integers.
//  This is the exact JSON structure passed into SurrealDB ml::predict().
//  leadId is carried for DB write-back but stripped from the ML payload.
// ══════════════════════════════════════════════════════════════════════════════

@JsonInclude(JsonInclude.Include.NON_NULL)
class NormalizedLeadInput {

    // Carried for DB write-back — NOT included in ml::predict() call
    private String leadId;

    // ── Label encoded (nominal — alphabetical order, no ordinal meaning) ──────
    @JsonProperty("primary_sentiment")
    private Integer primarySentiment;       // angry=1 curious=2 dissatisfied=3 interested=4
                                            // negotiating=5 satisfied=6 urgent=7

    @JsonProperty("intent")
    private Integer intent;                 // at_risk=1 churning=2 closing=3 comparison_shopping=4
                                            // evaluating=5 information_seeking=6 negotiating=7
                                            // ready_to_buy=8 upsell_opportunity=9 window_shopping=10

    // ── Ordinal encoded (order IS meaningful — depth of engagement) ───────────
    @JsonProperty("message_quality")
    private Integer messageQuality;         // short=1 medium=2 long=3 detailed=4

    // ── Binary (kept as-is) ───────────────────────────────────────────────────
    @JsonProperty("has_action_milestone")
    private Integer hasActionMilestone;     // 0 or 1

    @JsonProperty("is_repeat_customer")
    private Integer isRepeatCustomer;       // 0 or 1

    // ── IQR-binned numerical (all → 1=Low / 2=Medium / 3=High) ───────────────
    // Binning rule (same for all 7 columns):
    //   value <= Q1            → 1  (Low)
    //   Q1 < value <= Q3       → 2  (Medium)
    //   value > Q3             → 3  (High)

    @JsonProperty("sentiment_score")
    private Integer sentimentScore;         // Q1 = -0.36   Q3 = 0.67

    @JsonProperty("sentiment_combo_score")
    private Integer sentimentComboScore;    // Q1 =  1.0    Q3 = 5.0

    @JsonProperty("summary_length")
    private Integer summaryLength;          // Q1 = 163.0   Q3 = 281.0

    @JsonProperty("stage_velocity")
    private Integer stageVelocity;          // Q1 =  0.48   Q3 = 1.86

    @JsonProperty("historical_deals_won")
    private Integer historicalDealsWon;     // Q1 =  0.0    Q3 = 3.0   (skewed: 46% Low)

    @JsonProperty("historical_avg_sentiment")
    private Integer historicalAvgSentiment; // Q1 = -0.20   Q3 = 0.48

    @JsonProperty("industry_close_rate")
    private Integer industryCloseRate;      // Q1 =  0.424  Q3 = 0.594

    // TARGET — null during inference, present during training only
    @JsonProperty("sale_closed")
    private Integer saleClosed;

    public String  getLeadId()                  { return leadId; }
    public void    setLeadId(String v)           { this.leadId = v; }
    public Integer getPrimarySentiment()         { return primarySentiment; }
    public void    setPrimarySentiment(Integer v){ this.primarySentiment = v; }
    public Integer getIntent()                   { return intent; }
    public void    setIntent(Integer v)          { this.intent = v; }
    public Integer getMessageQuality()           { return messageQuality; }
    public void    setMessageQuality(Integer v)  { this.messageQuality = v; }
    public Integer getHasActionMilestone()       { return hasActionMilestone; }
    public void    setHasActionMilestone(Integer v){ this.hasActionMilestone = v; }
    public Integer getIsRepeatCustomer()         { return isRepeatCustomer; }
    public void    setIsRepeatCustomer(Integer v){ this.isRepeatCustomer = v; }
    public Integer getSentimentScore()           { return sentimentScore; }
    public void    setSentimentScore(Integer v)  { this.sentimentScore = v; }
    public Integer getSentimentComboScore()      { return sentimentComboScore; }
    public void    setSentimentComboScore(Integer v){ this.sentimentComboScore = v; }
    public Integer getSummaryLength()            { return summaryLength; }
    public void    setSummaryLength(Integer v)   { this.summaryLength = v; }
    public Integer getStageVelocity()            { return stageVelocity; }
    public void    setStageVelocity(Integer v)   { this.stageVelocity = v; }
    public Integer getHistoricalDealsWon()       { return historicalDealsWon; }
    public void    setHistoricalDealsWon(Integer v){ this.historicalDealsWon = v; }
    public Integer getHistoricalAvgSentiment()   { return historicalAvgSentiment; }
    public void    setHistoricalAvgSentiment(Integer v){ this.historicalAvgSentiment = v; }
    public Integer getIndustryCloseRate()        { return industryCloseRate; }
    public void    setIndustryCloseRate(Integer v){ this.industryCloseRate = v; }
    public Integer getSaleClosed()               { return saleClosed; }
    public void    setSaleClosed(Integer v)      { this.saleClosed = v; }
}


// ══════════════════════════════════════════════════════════════════════════════
//  MAPPER — ConsumerScoreMapper
//
//  Converts RawLeadInput (7 joined DB tables) → NormalizedLeadInput (integers).
//
//  Thresholds and encoding maps are taken 1:1 from:
//    normalize.py output  (response-normalized-consumer.txt)
//    Normalization_Report.docx
//
//  Transformation strategies used:
//    1. BINARY      — 0/1 kept as-is
//    2. ORDINAL     — string → ordered integer (message_quality)
//    3. LABEL       — string → alphabetical integer (primary_sentiment, intent)
//    4. IQR BIN     — float/int → 1(Low)/2(Medium)/3(High)
// ══════════════════════════════════════════════════════════════════════════════

@Component
class ConsumerScoreMapper {

    // ── IQR Thresholds ─────────────────────────────────────────────────────────
    // Recomputed from 11,800-row training dataset (master_dataset_fixed.csv)
    // All sentiment/velocity ranges updated — old data had -1..+1 range, new is 0..1

    // sentiment_score | source: conversation.sentiment_score (float 0.5 to 1.0)
    // bin dist: Low=~3933 / Medium=~3934 / High=~3933
    private static final double SENTIMENT_SCORE_Q1     = 0.50;
    private static final double SENTIMENT_SCORE_Q3     = 0.85;

    // sentiment_combo_score | source: weighted message+conversation combo (int 3-7)
    private static final double SENTIMENT_COMBO_Q1     = 3.0;
    private static final double SENTIMENT_COMBO_Q3     = 5.0;

    // summary_length | source: len(conversation.summary) in characters
    private static final double SUMMARY_LENGTH_Q1      = 263.0;
    private static final double SUMMARY_LENGTH_Q3      = 512.0;

    // stage_velocity | source: stage_order_delta / days_in_pipeline
    private static final double STAGE_VELOCITY_Q1      = 0.90;
    private static final double STAGE_VELOCITY_Q3      = 2.21;

    // historical_deals_won | source: organisation.historical_deals_won (int count)
    private static final double HISTORICAL_DEALS_Q1    = 0.0;
    private static final double HISTORICAL_DEALS_Q3    = 1.0;

    // historical_avg_sentiment | source: organisation.historical_avg_sentiment (0.0-1.0)
    private static final double HIST_AVG_SENTIMENT_Q1  = 0.45;
    private static final double HIST_AVG_SENTIMENT_Q3  = 0.76;

    // industry_close_rate | source: aggregated CLOSED rate for organisation.industry
    private static final double INDUSTRY_CLOSE_RATE_Q1 = 0.50;
    private static final double INDUSTRY_CLOSE_RATE_Q3 = 0.632;


    // ── Categorical Encoding Maps ─────────────────────────────────────────────

    // primary_sentiment — LABEL ENCODED alphabetically (NOMINAL)
    // source: conversation.sentiment (AI classifier) — stored UPPERCASE in DB, lowercased here
    // FIX: removed "statisfied" typo, added correct "satisfied", added "dissatisfied" alias
    private static final Map<String, Integer> PRIMARY_SENTIMENT_MAP = Map.of(
        "angry",        1,
        "curious",      2,
        "disappointed", 3,   // DB may return "DISAPPOINTED"
        "dissatisfied", 3,   // DB may return "DISSATISFIED" — same bin
        "interested",   4,
        "negotiating",  5,
        "satisfied",    6,   // FIX: was "statisfied" (typo) — broke all satisfied leads
        "urgent",       7,
        "neutral",4
    );

    // intent — LABEL ENCODED alphabetically (NOMINAL)
    // source: lead.classification (AI intent classifier)
    // FIX: added "non_sales" → defaults to information_seeking bin (6)
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
        Map.entry("non_sales",           6),  // FIX: was missing — classify as information_seeking
        Map.entry("sales",               6)   // legacy alias
    );

    // message_quality — ORDINAL ENCODED (order IS meaningful: short → detailed)
    // source: character length of message.content bucketed at extraction time
    private static final Map<String, Integer> MESSAGE_QUALITY_MAP = Map.of(
        "short",    1,
        "medium",   2,
        "long",     3,
        "detailed", 4
    );


    // ── Main normalize() entry point ──────────────────────────────────────────

    public NormalizedLeadInput normalize(RawLeadInput raw) {
        validateRawInput(raw); // Now sanitizes and sets defaults
        NormalizedLeadInput norm = new NormalizedLeadInput();

        norm.setLeadId(raw.getLeadId());

        // ── STEP 1: Binary ───────────────────────────────────────────────────
        norm.setHasActionMilestone(mapBinary("has_action_milestone", raw.getHasActionMilestone()));
        norm.setIsRepeatCustomer(mapBinary("is_repeat_customer", raw.getIsRepeatCustomer()));
        
        if (raw.getSaleClosed() != null) {
            norm.setSaleClosed(mapBinary("sale_closed", raw.getSaleClosed()));
        }

        // ── STEP 2 & 3: Categorical ──────────────────────────────────────────
        norm.setMessageQuality(encodeCategorical("message_quality", 
            raw.getMessageQuality(), MESSAGE_QUALITY_MAP));
            
        norm.setPrimarySentiment(encodeCategorical("primary_sentiment", 
            raw.getPrimarySentiment(), PRIMARY_SENTIMENT_MAP));
            
        norm.setIntent(encodeCategorical("intent", 
            raw.getIntent(), INTENT_MAP));

        // ── STEP 5: Numerical/IQR (Handling sentiment_score, velocity, etc.) ──
        // Rule: If value is null, we pass a midpoint between Q1 and Q3 to force Bin 2.

        norm.setSentimentScore(iqrBin("sentiment_score", 
            raw.getSentimentScore(), SENTIMENT_SCORE_Q1, SENTIMENT_SCORE_Q3));

        norm.setSentimentComboScore(iqrBin("sentiment_combo_score", 
            toDouble(raw.getSentimentComboScore()), SENTIMENT_COMBO_Q1, SENTIMENT_COMBO_Q3));

        norm.setSummaryLength(iqrBin("summary_length", 
            toDouble(raw.getSummaryLength()), SUMMARY_LENGTH_Q1, SUMMARY_LENGTH_Q3));

        norm.setStageVelocity(iqrBin("stage_velocity", 
            raw.getStageVelocity(), STAGE_VELOCITY_Q1, STAGE_VELOCITY_Q3));

        norm.setHistoricalDealsWon(iqrBin("historical_deals_won", 
            toDouble(raw.getHistoricalDealsWon()), HISTORICAL_DEALS_Q1, HISTORICAL_DEALS_Q3));

        norm.setHistoricalAvgSentiment(iqrBin("historical_avg_sentiment", 
            raw.getHistoricalAvgSentiment(), HIST_AVG_SENTIMENT_Q1, HIST_AVG_SENTIMENT_Q3));

        norm.setIndustryCloseRate(iqrBin("industry_close_rate", 
            raw.getIndustryCloseRate(), INDUSTRY_CLOSE_RATE_Q1, INDUSTRY_CLOSE_RATE_Q3));

        return norm;
    }


    // ── Transformation helpers ────────────────────────────────────────────────

    // BINARY: validates 0 or 1 and passes through unchanged
    private int mapBinary(String field, Integer value) {
        if (value == null)
            throw new NormalizationException(field + ": must not be null");
        if (value != 0 && value != 1)
            throw new NormalizationException(field + ": must be 0 or 1, got: " + value);
        return value;
    }

    // CATEGORICAL: string → integer via lookup map
    // Trims and lowercases before lookup to tolerate minor DB formatting differences
    private int encodeCategorical(String field, String rawValue, Map<String, Integer> map) {
        if (rawValue == null || rawValue.isBlank())
            throw new NormalizationException(field + ": must not be null or blank");
        Integer encoded = map.get(rawValue.trim().toLowerCase());
        if (encoded == null)
            throw new NormalizationException(
                field + ": unrecognized value '" + rawValue + "'. Valid: " + map.keySet());
        return encoded;
    }

    // IQR BIN: float/int → 1 (Low) / 2 (Medium) / 3 (High)
    // Q1 is inclusive on the Low boundary, Q3 is inclusive on the Medium boundary
    private int iqrBin(String field, Double value, double q1, double q3) {
        if (value == null)
            throw new NormalizationException(field + ": must not be null");
        if (value <= q1)      return 1; // Low
        else if (value <= q3) return 2; // Medium
        else                  return 3; // High
    }

    // Integer → Double null-safe helper
    private Double toDouble(Integer v) { return v != null ? v.doubleValue() : null; }

    // Fail-fast validation — collects all missing fields before throwing
    private void validateRawInput(RawLeadInput raw) {
        Objects.requireNonNull(raw, "RawLeadInput must not be null");

        // ── 1. CRITICAL: Lead ID Check ──────────────────────────────────────
        if (raw.getLeadId() == null || raw.getLeadId().isBlank()) {
            throw new NormalizationException("Normalization failed: lead_id is missing.");
        }

        // ── 2. SANITIZE: Set Defaults for Missing (NONE) Values ──────────────
        // This prevents NullPointerExceptions in the encode/iqr methods.
        
        // Categorical Defaults
        // FIX: "neutral" removed from sentiment map — default to "curious" (mid-range bin 2)
        if (raw.getPrimarySentiment() == null) raw.setPrimarySentiment("curious");
        if (raw.getIntent()           == null) raw.setIntent("information_seeking");
        if (raw.getMessageQuality()   == null) raw.setMessageQuality("medium");

        // Numerical Defaults — set to values that produce bin 2 (Medium) with new IQR thresholds
        if (raw.getSentimentScore()         == null) raw.setSentimentScore(0.67);  // mid of 0.50..0.85
        //if (raw.getSentimentComboScore()    == null) raw.setSentimentComboScore(4);
        if (raw.getSummaryLength()          == null) raw.setSummaryLength(380);    // mid of 263..512
        if (raw.getStageVelocity()          == null) raw.setStageVelocity(0.0);
        if (raw.getHistoricalDealsWon()     == null) raw.setHistoricalDealsWon(0);
        if (raw.getHistoricalAvgSentiment() == null) raw.setHistoricalAvgSentiment(0.0);
        if (raw.getIndustryCloseRate()      == null) raw.setIndustryCloseRate(0.0);

        // Binary Defaults
        if (raw.getHasActionMilestone() == null) raw.setHasActionMilestone(0);
        if (raw.getIsRepeatCustomer()   == null) raw.setIsRepeatCustomer(0);

        // ── 3. LOGGING ──────────────────────────────────────────────────────
        // Optional: Log that we are working with an incomplete record
        //log.debug("Lead [{}] validated and sanitized for normalization.", raw.getLeadId());
    }

    public static class NormalizationException extends RuntimeException {
        public NormalizationException(String message) { super(message); }
    }
}


// ══════════════════════════════════════════════════════════════════════════════
//  SURREAL DB SERVICE — SurrealDbService
//
//  Handles all SurrealDB communication:
//    fetchLeadData()            — joins 7 tables, returns RawLeadInput
//    callMlPredict()            — calls ml::predict() on the LightGBM model
//                                 already loaded in SurrealDB (no ONNX / no local model)
//    updateLeadWithPrediction() — writes consumer_score + predicted_closed to lead
//
//  SurrealDB ML setup (run once to register the model):
//    DEFINE MODEL consumer_score<1.0.0>
//      PERMISSIONS FULL;
//    -- then upload the model file via SurrealDB CLI or REST:
//    -- surreal ml import --conn http://localhost:8000 --user root --pass root
//    --    --ns vitafi --db sales consumer_score-1.0.0.surml
// ══════════════════════════════════════════════════════════════════════════════

@Service
class ConsumerScoreService {

    private static final Logger log = LoggerFactory.getLogger(ConsumerScoreService.class);
    @Autowired
    public SurrealDBClient         db;
    
    @Autowired
    public ErrorLogService errorLog;

    @Value("${surrealdb.url}")           private String surrealDbUrl;
    @Value("${surrealdb.namespace:db_salesai}")     private String namespace;
    @Value("${surrealdb.database:salesdb2}")      private String database;
    @Value("${surrealdb.username:root}")      private String username;
    @Value("${surrealdb.password:root}")      private String password;

    // Registered model name + version in SurrealDB, e.g. "consumer_score<1.0.0>"
    // Must match the name used in: DEFINE MODEL consumer_score<1.0.0>
    @Value("${surrealdb.ml.model.name:consumer_score}")
    private String mlModelName;

    private final RestTemplate restTemplate;
    private final ObjectMapper  objectMapper;

    ConsumerScoreService(RestTemplate restTemplate, ObjectMapper objectMapper) {
        this.restTemplate = restTemplate;
        this.objectMapper  = objectMapper;
    }


    // ── STEP 2: Fetch raw lead data from SurrealDB ────────────────────────────
    //
    // Joins 7 tables in a single SQL query:
    //   lead, conversation, message, organisation,
    //   lead_state_history, lead_stage, lead_status
    //
    public RawLeadInput fetchLeadData(String leadId) {
    	 
        // Ensure full record ref format e.g. "lead:abc123"
        String lid = leadId.startsWith("lead:") ? leadId : "lead:" + leadId;
 
        String sql = """
-- Assign variables for the specific lead
-- [1] Core record refs
LET $lead_rec = type::record('%s');
LET $lid      = type::string($lead_rec);

-- [2] Resolve linked lead IDs
LET $contact_id = $lead_rec.contact_id;
LET $linked_leads = IF $contact_id IS NOT NONE THEN
    (SELECT VALUE lead_ids FROM customer_contact
     WHERE $contact_id INSIDE contact_ids
     LIMIT 1)[0]
ELSE [$lead_rec] END;
LET $linked_leads = IF $linked_leads IS NOT NONE AND array::len($linked_leads) > 0
    THEN array::distinct(array::concat($linked_leads, [$lead_rec]))
    ELSE [$lead_rec] END;
LET $linked_lids = array::map($linked_leads, |$r| type::string($r));

-- [3] Org ref
LET $org = $lead_rec.organisation;

-- [4] Sentiment Logic
-- FIX: added DISAPPOINTED → -0.5 (same as DISSATISFIED)
LET $sent_obj = (
    SELECT sentiment, started_at FROM conversation
    WHERE lead IN $linked_leads
    ORDER BY started_at DESC LIMIT 1
)[0];

LET $sent_str = $sent_obj.sentiment OR 'CURIOUS';

LET $sent_raw =
    IF $sent_str = 'POSITIVE'   OR $sent_str = 'SATISFIED'  THEN 1.0
    ELSE IF $sent_str = 'INTERESTED'                         THEN 0.8
    ELSE IF $sent_str = 'URGENT'                             THEN 0.75
    ELSE IF $sent_str = 'NEGOTIATING'                        THEN 0.5
    ELSE IF $sent_str = 'CURIOUS'                            THEN 0.3
    ELSE IF $sent_str = 'NEUTRAL'                            THEN 0.0
    ELSE IF $sent_str = 'DISSATISFIED'
         OR $sent_str = 'DISAPPOINTED'                       THEN -0.5
    ELSE IF $sent_str = 'FRUSTRATED'                         THEN -0.7
    ELSE IF $sent_str = 'NEGATIVE' OR $sent_str = 'ANGRY'   THEN -1.0
    ELSE 0.0 END;

-- [5] Stage & Velocity Logic
-- FIX: added FOLLOW_UP, QUOTATION_IN_DRAFT, MANUAL_FOLLOW_UP
LET $stage_raw_vel =
    IF $lead_rec.state = 'NEW_LEAD'                   THEN 0
    ELSE IF $lead_rec.state = 'MANUAL_FOLLOW_UP'      THEN 1
    ELSE IF $lead_rec.state = 'SALES_FOLLOW_UP'       THEN 2
    ELSE IF $lead_rec.state = 'SALES_QUALIFIED'       THEN 3
    ELSE IF $lead_rec.state = 'QUOTATION'
         OR $lead_rec.state = 'QUOTATION_IN_DRAFT'
         OR $lead_rec.state = 'QUOTATION_SENT'        THEN 4
    ELSE IF $lead_rec.state = 'FOLLOW_UP'
         OR $lead_rec.state = 'FOLLOW_UP_NEGOTIATION' THEN 5
    ELSE IF $lead_rec.state = 'CLOSED'                THEN 6
    ELSE 0 END;

LET $days_in_pipeline = type::float(math::max([
    math::floor(duration::secs(time::now() - $lead_rec.created_at) / 86400),
    1
]));

-- Velocity: Stage (0-6) / Days (minimum 1)
LET $velocity_raw = type::float($stage_raw_vel) / $days_in_pipeline;

-- FIX: sentiment_combo_score — maps to 3-7 integer range matching training data
-- Formula: 3 + round((sent_raw + 1.0) * 2.0)
-- ANGRY(-1.0)→3, DISSATISFIED(-0.5)→4, NEUTRAL(0.0)→5, URGENT(0.5-0.75)→6, SATISFIED(1.0)→7
LET $combo_raw = math::round(3.0 + (($sent_raw + 1.0) * 2.0));

-- [6] Message Quality Logic
LET $latest_conv_id = (
    SELECT id, started_at FROM conversation
    WHERE lead IN $linked_leads
    ORDER BY started_at DESC LIMIT 1
)[0].id;

LET $msg_len = IF $latest_conv_id IS NOT NONE THEN
    (
        SELECT string::len(content) AS len, created_at FROM message
        WHERE conversation = $latest_conv_id
          AND content IS NOT NONE
        ORDER BY created_at DESC LIMIT 1
    )[0].len OR 0
ELSE 0 END;

LET $message_quality =
    IF $msg_len > 200      THEN 'detailed'
    ELSE IF $msg_len > 100 THEN 'long'
    ELSE IF $msg_len > 50  THEN 'medium'
    ELSE 'short' END;

-- [7] Industry close rate — FIX: was hardcoded 0.5, now derived from org.industry
LET $org_industry = $org.industry OR '';
LET $ind_close_rate =
    IF $org_industry = 'Data Centers'                THEN 0.67
    ELSE IF $org_industry = 'Cold Chain Logistics'   THEN 0.62
    ELSE IF $org_industry = 'Semiconductor Fabrication' THEN 0.60
    ELSE IF $org_industry = 'Dairy Processing'       THEN 0.58
    ELSE IF $org_industry = 'Breweries & Beverages'
         OR $org_industry = 'Food & Beverage'        THEN 0.55
    ELSE IF $org_industry = 'Food Processing'        THEN 0.55
    ELSE IF $org_industry = 'Defence & Aerospace'    THEN 0.53
    ELSE IF $org_industry = 'Pharmaceuticals'
         OR $org_industry = 'Hospitals & Healthcare' THEN 0.52
    ELSE IF $org_industry = 'Automotive'
         OR $org_industry = 'Hospitality'
         OR $org_industry = 'Hotels & Hospitality'   THEN 0.50
    ELSE IF $org_industry = 'Chemicals'
         OR $org_industry = 'Retail & Supermarkets'
         OR $org_industry = 'IT / SaaS'
         OR $org_industry = 'Education'              THEN 0.48
    ELSE IF $org_industry = 'Real Estate'            THEN 0.47
    ELSE IF $org_industry = 'Oil & Gas'
         OR $org_industry = 'Power Generation'       THEN 0.45
    ELSE IF $org_industry = 'Glass Manufacturing'    THEN 0.44
    ELSE IF $org_industry = 'Paper & Pulp'           THEN 0.43
    ELSE IF $org_industry = 'Steel Manufacturing'    THEN 0.42
    ELSE IF $org_industry = 'Rubber & Tyres'         THEN 0.41
    ELSE IF $org_industry = 'Plastics'               THEN 0.40
    ELSE IF $org_industry = 'Textiles'               THEN 0.38
    ELSE 0.50 END;

-- [8] Final Selection
SELECT
    id                                               AS lead_id,
    classification                                   AS intent,
    $sent_str                                        AS primary_sentiment,
    $sent_raw                                        AS sentiment_score,
    $combo_raw                                       AS sentiment_combo_score,

    (SELECT string::len(summary) AS len, started_at FROM conversation
     WHERE lead IN $linked_leads AND summary IS NOT NONE
     ORDER BY started_at DESC LIMIT 1)[0].len OR 0   AS summary_length,

    $message_quality                                 AS message_quality,

    (IF array::len(
        SELECT VALUE id FROM lead_state_history
        WHERE lead_id INSIDE $linked_lids
          AND to_state INSIDE ['SALES_QUALIFIED','QUOTATION_SENT','CLOSED']
    ) > 0 THEN 1 ELSE 0 END)                         AS has_action_milestone,

    $velocity_raw                                    AS stage_velocity,

    (organisation.historical_deals_won OR 0)         AS historical_deals_won,
    (IF (organisation.historical_deals_won OR 0) >= 1
     THEN 1 ELSE 0 END)                              AS is_repeat_customer,
    (organisation.historical_avg_sentiment OR 0.5)   AS historical_avg_sentiment,
    $ind_close_rate                                  AS industry_close_rate,

    (IF (SELECT lead_status, created_at FROM lead_status
         WHERE leadid INSIDE $linked_lids
         ORDER BY created_at DESC LIMIT 1)[0].lead_status = 'CLOSED'
     THEN 1 ELSE 0 END)                              AS sale_closed

FROM $lead_rec;
            """.formatted(lid);
 
        try {
            // 1. Call the centralized client (Pooled WebClient)
            List<Map<String, Object>> results = db.queryMl(sql, Map.of());

            // 2. Map the result to your DTO
            return mapFirstResult(results, lid, RawLeadInput.class);

        } catch (Exception e) {
            log.error("Failed to fetch Lead data for {}: {}", lid, e.getMessage());
            // Return an empty DTO or handle as per your business logic
            return new RawLeadInput();
        }
    }
    /**
     * Replaces the old parseFirstRow. Converts the List<Map> from SurrealDBClient
     * into the desired Class type using Jackson's convertValue.
     */
    private <T> T mapFirstResult(List<Map<String, Object>> results, String leadId, Class<T> clazz) {
        if (results == null || results.isEmpty()) {
            log.warn("No results found for lead: {}", leadId);
            try {
                return clazz.getDeclaredConstructor().newInstance();
            } catch (Exception e) {
                return null;
            }
        }

        // SurrealDBClient.query typically returns the 'result' portion.
        // We take the first row and map it to the DTO.
        return objectMapper.convertValue(results.get(0), clazz);
    }


    // ── STEP 4: Call LightGBM model loaded in SurrealDB ───────────────────────
    //
    // SurrealDB ml::predict() syntax:
    //   RETURN ml::predict('<model_name>', { feature: value, ... });
    //
    // The 12 normalized integer features are passed as a JSON object.
    // Feature names must match the column names the model was trained on.
    //
    // Expected response shapes (handled in parsePredictionResult):
    //   { "sale_closed": 1, "consumer_score": 0.823 }  — class + probability
    //   0.823                                           — probability only
    //   { "sale_closed": 1 }                            — class label only
    //
    public double callMlPredict(NormalizedLeadInput norm) {
        // We wrap the operation in a transaction block to bypass the read-only error
        String sql = String.format("""
            BEGIN TRANSACTION;
            
            LET $prediction = ml::consumer_score<2.0.0>([
                %f, -- primary_sentiment
                %f, -- sentiment_score
                %f, -- sentiment_combo_score
                %f, -- intent
                %f, -- message_quality
                %f, -- summary_length
                %f, -- has_action_milestone
                %f, -- stage_velocity
                %f, -- historical_deals_won
                %f, -- is_repeat_customer
                %f, -- historical_avg_sentiment
                %f  -- industry_close_rate
            ]);

            RETURN {
                model: "consumer_score",
                score: $prediction
            };

            COMMIT TRANSACTION;
            """,
            (double) norm.getPrimarySentiment(),
            (double) norm.getSentimentScore(),
            (double) norm.getSentimentComboScore(),
            (double) norm.getIntent(),
            (double) norm.getMessageQuality(),
            (double) norm.getSummaryLength(),
            (double) norm.getHasActionMilestone(),
            (double) norm.getStageVelocity(),
            (double) norm.getHistoricalDealsWon(),
            (double) norm.getIsRepeatCustomer(),
            (double) norm.getHistoricalAvgSentiment(),
            (double) norm.getIndustryCloseRate()
        );

        log.debug("[SurrealDB ml::predict] lead={} payload=\n{}", norm.getLeadId(), sql);
        try {
            // Use the centralized client
            List<Map<String, Object>> results = db.queryMl(sql,Map.of());

            // Pass the list to the updated parser
            return parsePredictionResult(results, norm.getLeadId());

        } catch (Exception e) {
            if (errorLog != null) {
                errorLog.log("ML_CONSUMER_SCORE_FAILED",
                    "consumer_score prediction failed for lead=" + norm.getLeadId(),
                    norm.getLeadId(), null, e);
            }
            log.error("[ML consumer_score] Failed lead={}: {}", norm.getLeadId(), e.getMessage());
            return 0.0;
        }}


    // ── STEP 5: Write prediction result back to lead record ───────────────────
    //
    // Fields written to lead:
    //   consumer_score    — probability 0.0-1.0 (P(sale_closed=1))
    //   ai_confidence     — same value in the existing ai_confidence field
    //   predicted_closed  — binary 0 or 1
    //   score_updated_at  — timestamp of this scoring run
    //
    public void updateLeadWithPrediction(String leadId, double consumerScore) {
        // Correct Syntax for SurrealDB 3.x
        String sql = String.format(
            "UPDATE type::record('%s') SET consumer_score = %f, updated_at = time::now();", 
            leadId, consumerScore
        );

        HttpEntity<String> req = new HttpEntity<>(sql, buildHeaders());
        restTemplate.exchange(surrealDbUrl + "/sql", HttpMethod.POST, req, String.class);
    }


    // ── Private helpers ───────────────────────────────────────────────────────

    private HttpHeaders buildHeaders() {
        HttpHeaders h = new HttpHeaders();
        // Use APPLICATION_JSON if you are sending/receiving JSON via the HTTP API
        h.setContentType(MediaType.APPLICATION_JSON); 
        h.setAccept(List.of(MediaType.APPLICATION_JSON));
        h.setBasicAuth(username, password);

        // ── SurrealDB 3.x Specific Headers ──
        h.set("surreal-ns", namespace);
        h.set("surreal-db", database);
        
        return h;
    }
    
    private HttpHeaders buildHeadersML() {
        HttpHeaders h = new HttpHeaders();
        // Use APPLICATION_JSON if you are sending/receiving JSON via the HTTP API
        h.setContentType(MediaType.APPLICATION_JSON); 
        h.setAccept(List.of(MediaType.APPLICATION_JSON));
        h.setBasicAuth(username, password);

        // ── SurrealDB 3.x Specific Headers ──
        h.set("surreal-ns", "vitasales");
        h.set("surreal-db", "vitasales");
        
        return h;
    }

    // Parses a SurrealDB /sql response and deserializes the first result row.
    // SurrealDB response format: [{ "status":"OK", "result":[{...row...}] }, ...]
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

    // Parses the ml::predict() response.
    // Handles three possible response shapes from SurrealDB:
    //   Shape A: { "sale_closed": 1, "consumer_score": 0.823 }  — class + probability
    //   Shape B: 0.823                                           — probability scalar only
    //   Shape C: { "sale_closed": 1 }                           — class label only
    private double parsePredictionResult(List<Map<String, Object>> results, String leadId) {
        if (results == null || results.isEmpty()) {
            return 0.0;
        }

        try {
            // Search through the flattened results for our model identifier
            for (Map<String, Object> row : results) {
                if (row != null && "consumer_score".equals(row.get("model"))) {
                    Object scoreObj = row.get("score");
                    
                    if (scoreObj == null) continue;

                    // Handle both single values and array returns [0.85]
                    if (scoreObj instanceof List<?> list && !list.isEmpty()) {
                        return Double.parseDouble(list.get(0).toString());
                    } else {
                        return Double.parseDouble(scoreObj.toString());
                    }
                }
            }
        } catch (Exception e) {
            log.error("Failed to parse Consumer ML response for lead {}: {}", leadId, e.getMessage());
        }
        return 0.0;
    }

    // Prediction result DTO
    static class PredictionResult {
        private final int    predictedSaleClosed; // 0 = will not close, 1 = will close
        private final double consumerScore;       // probability 0.0-1.0, stored in DB

        PredictionResult(int predictedSaleClosed, double consumerScore) {
            this.predictedSaleClosed = predictedSaleClosed;
            this.consumerScore       = consumerScore;
        }

        public int    getPredictedSaleClosed() { return predictedSaleClosed; }
        public double getConsumerScore()       { return consumerScore; }
    }
}


// ══════════════════════════════════════════════════════════════════════════════
//  PIPELINE ORCHESTRATOR — ConsumerScorePipelineService
//  Ties steps 2-5 together for one lead.
// ══════════════════════════════════════════════════════════════════════════════

@Service
class ConsumerScorePipelineService {

    private static final Logger log = LoggerFactory.getLogger(ConsumerScorePipelineService.class);

    private final ConsumerScoreService    surrealDbService;
    private final ConsumerScoreMapper mapper;

    ConsumerScorePipelineService(ConsumerScoreService surrealDbService,
                                  ConsumerScoreMapper mapper) {
        this.surrealDbService = surrealDbService;
        this.mapper           = mapper;
    }

    public void scoreLeadById(String leadId) {
        log.info("[Pipeline] START lead={}", leadId);
        try {
            // Step 2: Fetch raw data from 7 joined SurrealDB tables
            RawLeadInput raw = surrealDbService.fetchLeadData(leadId);
            log.debug("[Step 2] Fetched: intent={} sentiment={} sentimentScore={}",
                raw.getIntent(), raw.getPrimarySentiment(), raw.getSentimentScore());

            // Step 3: Map raw DB JSON → normalized integer JSON
            NormalizedLeadInput normalized = mapper.normalize(raw);
            log.debug("[Step 3] Normalized: primarySentiment={} intent={} sentimentScore={}",
                normalized.getPrimarySentiment(),
                normalized.getIntent(),
                normalized.getSentimentScore());

            // Step 4: Call LightGBM via SurrealDB ml::predict() API
            double prediction =
                surrealDbService.callMlPredict(normalized);
//            log.info("[Step 4] ml::predict result: consumerScore={} predictedClosed={}",
//                String.format("%.4f", prediction.getConsumerScore()),
//                prediction.getPredictedSaleClosed());

            // Step 5: Write consumer_score + predicted_closed back to lead record
            surrealDbService.updateLeadWithPrediction(
                leadId,
                prediction);

//            log.info("[Pipeline] DONE lead={} consumerScore={} predictedClosed={}",
//                leadId,
//                String.format("%.4f", prediction.getConsumerScore()),
//                prediction.getPredictedSaleClosed());

        } catch (ConsumerScoreMapper.NormalizationException e) {
            log.error("[Pipeline] NORMALIZATION ERROR lead={}: {}", leadId, e.getMessage());
            throw new PipelineException("Normalization failed for lead [" + leadId + "]", e);
        } catch (Exception e) {
            log.error("[Pipeline] ERROR lead={}: {}", leadId, e.getMessage(), e);
            throw new PipelineException("Pipeline failed for lead [" + leadId + "]", e);
        }
    }

    static class PipelineException extends RuntimeException {
        PipelineException(String message, Throwable cause) { super(message, cause); }
    }
}


// ══════════════════════════════════════════════════════════════════════════════
//  REST CONTROLLER — ConsumerScoreController
//
//  Receives the SurrealDB trigger webhook and starts the pipeline.
//
//  SurrealDB event to define once in your DB:
//
//    DEFINE EVENT score_consumer ON TABLE lead
//      WHEN $event = "CREATE" OR $event = "UPDATE"
//      THEN {
//        http::post(
//          "http://your-java-api/api/v2/consumer-score/trigger",
//          { lead_id: string::concat('', $value.id), event: $event }
//        );
//      };
// ══════════════════════════════════════════════════════════════════════════════

@RestController
@RequestMapping("/api/v1/consumer-score")
class ConsumerScoreController {

    private static final Logger log = LoggerFactory.getLogger(ConsumerScoreController.class);

    private final ConsumerScorePipelineService pipelineService;

    ConsumerScoreController(ConsumerScorePipelineService pipelineService) {
        this.pipelineService = pipelineService;
    }

    // SurrealDB trigger POSTs: { "lead_id": "lead:abc123", "event": "CREATE" }
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

    // Manual trigger for testing: POST /api/v2/consumer-score/score/lead:abc123
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
