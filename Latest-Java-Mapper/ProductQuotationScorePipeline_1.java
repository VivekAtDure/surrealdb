package com.dure.botbuilder.surreal.mapperservice.product;
import java.time.Instant;
import java.util.List;
import java.util.Locale;
import java.util.Map;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpEntity;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpMethod;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.stereotype.Service;
import org.springframework.web.client.RestTemplate;

import com.dure.botbuilder.surreal.config.SurrealDBClient;
import com.dure.botbuilder.surreal.errorlog.ErrorLogService;
import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonProperty;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import lombok.Data;

/**
 * PRODUCT QUOTATION SCORE PIPELINE (SurrealDB 3.0)
 * Logic: 18-Feature ML Model [ml::product_quotation_score<1.0.0>]
 */
@Service
public class ProductQuotationScorePipeline {
    private static final Logger log = LoggerFactory.getLogger(ProductQuotationScorePipeline.class);

    @Value("${surrealdb.url}")           private String surrealDbUrl;
    @Value("${surrealdb.namespace:db_salesai}")     private String namespace;
    @Value("${surrealdb.database:salesdb2}")      private String database;
    @Value("${surrealdb.username:root}")      private String username;
    @Value("${surrealdb.password:root}")      private String password;
    @Autowired
    public ErrorLogService errorLog;
    
    @Autowired
    private SurrealDBClient db;

    private final RestTemplate restTemplate = new RestTemplate();
    private final ObjectMapper objectMapper = new ObjectMapper();
    public ProductQuotationScorePipeline() {
        // FIX: Enables handling of java.time.Instant for SurrealDB timestamps
        this.objectMapper.registerModule(new com.fasterxml.jackson.datatype.jsr310.JavaTimeModule());
    }
    public void scoreLeadById(String leadId) {
        log.info("[Product Pipeline] START lead={}", leadId);
        try {
            // 1. Fetch raw data using SurrealDB 3.0 safe query
            RawProductQuotationInput raw = fetchProductQuotationData(leadId);
            
            // 2. Normalize to 18 specific ML features
            NormalizedProductQuotationInput normalized = normalize(raw);
            
            // 3. Call ML Predict & Update Lead in one transaction
            double score = callMlPredict(normalized);
            updateLeadWithPrediction(leadId,score);
            
            log.info("[Product Pipeline] DONE lead={} productScore={}", leadId, score);
        } catch (Exception e) {
            log.error("[Product Pipeline] FAILED lead={}: {}", leadId, e.getMessage());
            errorLog.log("ML_PRODUCT_QUOTATION_FAILED",
            	"product_quotation_score prediction failed for lead" + leadId,
                    leadId, null, e);
        }
    }
    
    public NormalizedProductQuotationInput normalize(RawProductQuotationInput raw) {
        NormalizedProductQuotationInput n = new NormalizedProductQuotationInput();
        n.setLeadId(raw.getLeadId());

        // FIX: Explicit Null Checks to prevent NullPointerException
        double price = (raw.getBasePrice() != null) ? raw.getBasePrice() : 0.0;
        double tax   = (raw.getTaxRate() != null) ? raw.getTaxRate() : 5.0;
        double cap   = (raw.getCapacityTons() != null) ? raw.getCapacityTons() : 0.0;
        int quoteCnt = (raw.getQuotationSentCount() != null) ? raw.getQuotationSentCount() : 0;
        int wonDeals = (raw.getHistoricalDeals_won() != null) ? raw.getHistoricalDeals_won() : 0;
        double indRate = (raw.getIndustryCloseRate() != null) ? raw.getIndustryCloseRate() : 0.5;

        // [0] Category (chiller=0, cooler=1, combo=2)
        String name = (raw.getProductName() != null ? raw.getProductName() : "").toLowerCase();
        n.setProductCategory(name.contains("chiller") ? 0.0 : name.contains("combo") ? 2.0 : 1.0);

        // [1-2] Type & Complexity
        // double typeVal = "single".equalsIgnoreCase(raw.getProductTypeStr()) ? 10.0 : 5.0;
        // n.setProductType(typeVal);
        // n.setProductComplexity("single".equalsIgnoreCase(raw.getProductTypeStr()) ? 1.0 : 2.0);

        String type = raw.getProductTypeStr() != null ? raw.getProductTypeStr().toLowerCase() : "";

        // product_type ordinal: alphabetical encoding matching training data
        // centrifugal=0, combo=1, economy=2, evaporative=3, floor_stand=4,
        // glycol=5, industrial=6, modular=7, package=8, portable=9,
        // premium=10, rooftop=11, screw=12, scroll=13, single=14
        double typeVal;
        double complexity;
        switch (type) {
            case "centrifugal"  -> { typeVal =  0.0; complexity = 3.0; }
            case "combo"        -> { typeVal =  1.0; complexity = 2.5; }
            case "economy"      -> { typeVal =  2.0; complexity = 1.5; }
            case "evaporative"  -> { typeVal =  3.0; complexity = 1.0; }
            case "floor_stand"  -> { typeVal =  4.0; complexity = 2.0; }
            case "glycol"       -> { typeVal =  5.0; complexity = 3.5; }
            case "industrial"   -> { typeVal =  6.0; complexity = 4.0; }
            case "modular"      -> { typeVal =  7.0; complexity = 3.0; }
            case "package"      -> { typeVal =  8.0; complexity = 2.0; }
            case "portable"     -> { typeVal =  9.0; complexity = 1.0; }
            case "premium"      -> { typeVal = 10.0; complexity = 3.5; }
            case "rooftop"      -> { typeVal = 11.0; complexity = 2.5; }
            case "screw"        -> { typeVal = 12.0; complexity = 3.0; }
            case "scroll"       -> { typeVal = 13.0; complexity = 2.0; }
            case "single"       -> { typeVal = 14.0; complexity = 1.0; }
            default             -> { typeVal =  0.0; complexity = 2.0; }
        }

        n.setProductType(typeVal);
        n.setProductComplexity(complexity);

        // [3-5] Pricing
        n.setBasePrice(price);
        n.setTaxRate(tax);
        // price_tier — alphabetical label encoding: enterprise=0, high=1, low=2, mid=3
        if (price >= 400_000)       n.setPriceTier(0.0); // enterprise
        else if (price >= 200_000)  n.setPriceTier(1.0); // high
        else if (price < 50_000)    n.setPriceTier(2.0); // low
        else                        n.setPriceTier(3.0); // mid (50k-200k)

        // [6-8] Capacity & Composite
        n.setCapacityTons(cap);
        // capacity_bin: 1-5t=0, 6-10t=4, 11-20t=1, 21-50t=2, 51-100t=3
        double bin;
        if      (cap <= 5)  bin = 0.0;
        else if (cap <= 10) bin = 4.0;
        else if (cap <= 20) bin = 1.0;
        else if (cap <= 50) bin = 2.0;
        else                bin = 3.0;

        n.setCapacityBin(bin);
        // product_x_capacity = product_type_ordinal × 5 + capacity_bin
        n.setProductXCapacity(typeVal * 5.0 + bin);

        // [9-10] Totals
        double total = price * (1 + tax / 100.0);
        n.setTotalPrice(total);
        n.setCapacityPriceRatio(total > 0 ? cap / total : 0.0);

        // [11-13, 15] Flags & Industry
        n.setQuotationSent(quoteCnt > 0 ? 1.0 : 0.0);
        n.setIsEnterpriseDeal(price >= 400000 ? 1.0 : 0.0);
        n.setIndustryCloseRate(indRate);
        n.setIsRepeatCustomer(wonDeals > 0 ? 1.0 : 0.0);

        // [14, 16, 17] Pipeline & Velocity
        double stage = mapStage(raw.getLeadState());
        n.setStageRaw(stage);
        
        // Null-safe time calculation
        long diff = 86400; // Default 1 day in seconds
        if (raw.getNowTs() != null && raw.getCreatedAt() != null) {
            diff = Math.abs(raw.getNowTs().getEpochSecond() - raw.getCreatedAt().getEpochSecond());
        }
        double days = Math.max(1.0, (double) diff / 86400.0);
        n.setDaysInPipeline(days);
        n.setPipelineVelocity(stage / days);

        return n;
    }
    private double mapStage(String s) {
        if (s == null) return 0.0;
        String key = s.toUpperCase().trim()
                      .replace(" ", "_")
                      .replace("/", "_")
                      .replaceAll("_+", "_");
        // stage_raw ordinal 0-6 — matches training spec and fn::score_lead in setup_ml.surql
        return switch (key) {
            case "NEW_LEAD"                -> 0.0;
            case "MANUAL_FOLLOW_UP"        -> 1.0;
            case "SALES_FOLLOW_UP"         -> 2.0;
            case "SALES_QUALIFIED"         -> 3.0;
            case "QUOTATION",
                 "QUOTATION_SENT",
                 "QUOTATION_IN_DRAFT"      -> 4.0;
            case "FOLLOW_UP_NEGOTIATION",
                 "FOLLOW_UP___NEGOTIATION",
                 "FOLLOW_UP"              -> 5.0;
            case "CLOSED"                  -> 6.0;
            default                        -> 0.0;
        };
    }
    public void updateLeadWithPrediction(String leadId, double consumerScore) {
        // Correct Syntax for SurrealDB 3.x
        String sql = String.format(
            "UPDATE type::record('%s') SET product_quotation_score = %f, updated_at = time::now();", 
            leadId, consumerScore
        );

        HttpEntity<String> req = new HttpEntity<>(sql, buildHeaders());
        restTemplate.exchange(surrealDbUrl + "/sql", HttpMethod.POST, req, String.class);
    }

    private RawProductQuotationInput fetchProductQuotationData(String leadId) {
        String lid = leadId.startsWith("lead:") ? leadId : "lead:" + leadId;

        String sql = String.format("""
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

-- [3] Fetch linked product from master_product_price_list (Synchronized with Reference)
-- Using the edge 'interested_in' as per your working reference
LET $prod = (SELECT VALUE out FROM interested_in WHERE in IN $all_leads LIMIT 1)[0];

-- [4] Metrics & Org Context
-- Using path-based fetching as per reference for reliable org data
LET $org = $lead_rec.organisation;
LET $quotation_count = array::len(SELECT VALUE id FROM generated_quotation WHERE in IN $all_leads);
LET $now = time::now();

-- Pipeline Time (Unix-based math for precision)
LET $days_in_pipeline = math::fixed(
    (time::unix($now) - time::unix($lead_rec.created_at ?? $now)) / 86400, 
    2
);

-- [5] Final Projection
SELECT
    type::string(id)                    AS lead_id,
    state                               AS lead_state,
    created_at                          AS created_at,
    $now                                AS now_ts,
    $days_in_pipeline                   AS days_in_pipeline,

    -- Aggregated Sentiment
    ($conv.sentiment ?? "NEUTRAL")      AS sentiment,
    math::floor(duration::secs($now - ($conv.last_message_at ?? created_at ?? $now)) / 86400) AS days_since_last_msg,

    -- Product details from master_product_price_list
    ($prod.model ?? "unknown")          AS product_name,
    ($prod.category ?? "single")        AS product_type_str,
    ($prod.exworks_price_aed ?? 0.0)    AS base_price,
    ($prod.vat_percent ?? 5.0)          AS tax_rate,
    ($prod.capacity_tons ?? $prod.capacity_value ?? 0.0) AS capacity_tons,

    -- Quotation and Org context
    (IF $quotation_count > 0 THEN 1 ELSE 0 END) AS quotation_sent_count,
    ($org.industry_close_rate ?? 0.5)    AS industry_close_rate,
    ($org.historical_deals_won ?? 0)    AS historical_deals_won,

    -- FIXED TARGET LOGIC: Include created_at in sub-selection for ORDER BY
    (IF (SELECT lead_status, created_at FROM lead_status 
         WHERE leadid IN $all_lids 
         ORDER BY created_at DESC LIMIT 1)[0].lead_status = 'CLOSED' 
     THEN 1 ELSE 0 END)                 AS sale_closed

FROM $lead_rec;
            """, lid);

        try {
            List<Map<String, Object>> results = db.queryMl(sql, Map.of());
            
            if (results != null && !results.isEmpty()) {
                // Converts the Map directly to your DTO
                return objectMapper.convertValue(results.get(0), RawProductQuotationInput.class);
            }
        } catch (Exception e) {
            log.error("Failed to fetch Product Data for lead {}: {}", lid, e.getMessage());
        }
        return new RawProductQuotationInput();
    }
    private double callMlPredict(NormalizedProductQuotationInput norm) {
        // Note: The model expects 17 parameters [0-16]. 
        // We remove the 18th placeholder to fix the "Failed to reshape tensor" error.
        String sql = String.format(Locale.US, """
            BEGIN TRANSACTION;
            
            LET $prediction = ml::product_quotation_score<1.0.0>([
                %f, %f, %f, %f, %f, %f, %f, %f, %f, %f,
                %f, %f, %f, %f, %f, %f, %f
            ]);
            
           RETURN { 
        model: "product_quotation", 
        score: $prediction[0] 
    };
            
            COMMIT TRANSACTION;
            """,
            norm.getProductCategory(),    // [0]
            norm.getProductType(),        // [1]
            norm.getProductComplexity(),  // [2]
            norm.getBasePrice(),          // [3]
            norm.getTaxRate(),            // [4]
            norm.getPriceTier(),          // [5]
            norm.getCapacityTons(),       // [6]
            norm.getCapacityBin(),        // [7]
            norm.getProductXCapacity(),   // [8]
            norm.getTotalPrice(),         // [9]
            norm.getCapacityPriceRatio(), // [10]
            norm.getQuotationSent(),      // [11]
            norm.getIsEnterpriseDeal(),   // [12]
            norm.getIndustryCloseRate(),  // [13]
            norm.getStageRaw(),           // [14]
            norm.getIsRepeatCustomer(),   // [15]
            norm.getDaysInPipeline()      // [16]
        );

        try {
            // 1. Use the centralized client (Pooled WebClient)
            List<Map<String, Object>> results = db.queryMl(sql, Map.of());

            // 2. Parse results from the flattened list
            return parsePredictionResult(results, norm.getLeadId());

        } catch (Exception e) {
            if (errorLog != null) {
                errorLog.log("ML_PRODUCT_QUOTATION_FAILED",
                    "product_quotation_score prediction failed for lead=" + norm.getLeadId(),
                    norm.getLeadId(), null, e);
            }
            log.error("[ML product_quotation_score] Failed lead={}: {}", norm.getLeadId(), e.getMessage());
            return 0.0;
        }
    }
    private double parsePredictionResult(List<Map<String, Object>> results, String leadId) {
        if (results == null || results.isEmpty()) {
            return 0.0;
        }

        try {
            // The new client parser already filtered out the BEGIN and LET statements
            for (Map<String, Object> row : results) {
                if (row != null && "product_quotation".equals(row.get("model"))) {
                    Object scoreObj = row.get("score");
                    if (scoreObj == null) continue;
                    double raw = scoreObj instanceof List<?> list && !list.isEmpty()
                        ? Double.parseDouble(list.get(0).toString())
                        : Double.parseDouble(scoreObj.toString());
                    return raw;
                }
            }
        } catch (Exception e) {
            log.error("Failed to parse Product ML response for lead {}: {}", leadId, e.getMessage());
        }
        return 0.0;
    }

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

    private <T> T parseFirstRow(String body, String id, Class<T> clazz) {
        try {
            JsonNode root = objectMapper.readTree(body);
            JsonNode result = root.get(root.size()-1).get("result"); // Last statement result
            if (result.isArray() && result.size() > 0) {
                return objectMapper.treeToValue(result.get(0), clazz);
            }
        } catch (Exception e) { log.error("Parse error for {}: {}", id, e.getMessage()); }
        try { return clazz.getDeclaredConstructor().newInstance(); } catch (Exception e) { return null; }
    }
}

// ── Models ───────────────────────────────────────────────────────────────────

@Data
@JsonIgnoreProperties(ignoreUnknown = true)
class RawProductQuotationInput {
    @JsonProperty("lead_id") private String leadId;
    @JsonProperty("product_name") private String productName;
    @JsonProperty("product_type_str") private String productTypeStr;
    @JsonProperty("base_price") private Double basePrice;
    @JsonProperty("tax_rate") private Double taxRate;
    @JsonProperty("capacity_tons") private Double capacityTons;
    @JsonProperty("quotation_sent_count") private Integer quotationSentCount;
    @JsonProperty("industry_close_rate") private Double industryCloseRate;
    @JsonProperty("historical_deals_won") private Integer historicalDeals_won;
    @JsonProperty("lead_state") private String leadState;
    @JsonProperty("created_at") private Instant createdAt;
    @JsonProperty("now_ts") private Instant nowTs;
}

@Data
class NormalizedProductQuotationInput {
    private String leadId;
    private Double productCategory;    // [0]
    private Double productType;        // [1]
    private Double productComplexity;  // [2]
    private Double basePrice;          // [3]
    private Double taxRate;            // [4]
    private Double priceTier;          // [5]
    private Double capacityTons;       // [6]
    private Double capacityBin;        // [7]
    private Double productXCapacity;   // [8]
    private Double totalPrice;         // [9]
    private Double capacityPriceRatio; // [10]
    private Double quotationSent;      // [11]
    private Double isEnterpriseDeal;   // [12]
    private Double industryCloseRate;  // [13]
    private Double stageRaw;           // [14]
    private Double isRepeatCustomer;   // [15]
    private Double daysInPipeline;     // [16]
    private Double pipelineVelocity;   // [17]
}

// ── Mapper ───────────────────────────────────────────────────────────────────


