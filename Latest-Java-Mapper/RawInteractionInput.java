package com.dure.botbuilder.surreal.mapperservice;


import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonProperty;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.dure.botbuilder.surreal.config.SurrealDBClient;
import com.dure.botbuilder.surreal.errorlog.ErrorLogService;

import lombok.Data;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.*;
import org.springframework.stereotype.*;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.client.RestTemplate;

import java.util.*;

// ════════════════════════════════════════════════════════════════════════════
//  INTERACTION SCORE PIPELINE  —  Java mirror of fn::score_interaction in setup_ml.surql
//
//  Flow:
//    Java mapper triggered externally (webhook or manual call)
//        ↓
//    [1] POST /api/v1/interaction-score/trigger   (InteractionController)
//        ↓
//    [2] Fetch raw interaction data from SurrealDB (InteractionService.fetchInteractionData)
//        Tables joined:
//          lead + conversation + organisation
//        Computed in SQL:
//          channel counts, dominant/first/last channel,
//          conv_time_bucket, recency_bucket, engagement_depth,
//          channel_x_stage (dominant_ordinal × 6 + stage_ordinal)
//        ↓
//    [3] Encode string buckets → ordinals  (InteractionMapper.normalize)
//        IQR-bin historical_deals_won
//        ↓
//    [4] Call ml::interaction_score<1.0.0>([15 floats])
//        ↓
//    [5] Write interaction_score back to lead record
// ════════════════════════════════════════════════════════════════════════════


// ══════════════════════════════════════════════════════════════════════════════
//  MODEL 1 — RawInteractionInput
//  Deserialized from the SurrealDB SQL query JSON response.
// ══════════════════════════════════════════════════════════════════════════════

@Data
@JsonIgnoreProperties(ignoreUnknown = true)
class RawInteractionInput {
    @JsonProperty("lead_id")                 private String  leadId;

    // [0-3] Raw channel counts — computed in SQL
    @JsonProperty("whatsapp_count")          private Integer whatsappCount;
    @JsonProperty("phone_count")             private Integer phoneCount;
    @JsonProperty("email_count")             private Integer emailCount;
    @JsonProperty("total_interactions")      private Integer totalInteractions;

    // [4-6] Channel labels — encoded to 0/1/2 by mapper
    @JsonProperty("dominant_channel")        private String  dominantChannel;
    @JsonProperty("first_channel")           private String  firstChannel;
    @JsonProperty("last_channel")            private String  lastChannel;

    // [7-8] Multi-channel flags — computed in SQL
    @JsonProperty("is_multi_channel")        private Integer isMultiChannel;
    @JsonProperty("channel_switch_count")    private Integer channelSwitchCount;

    // [9] Conversation span in hours — computed in SQL
    @JsonProperty("conversation_time_hours") private Double  conversationTimeHours;

    // [10] Bucket label — encoded to ordinal 0-4 by mapper
    @JsonProperty("conv_time_bucket")        private String  convTimeBucket;

    // [11] Recency label — encoded to ordinal 0-3 by mapper
    @JsonProperty("recency_bucket")          private String  recencyBucket;

    // [12] Pre-computed in SQL: total_interactions × (1 + avg_sentiment)
    @JsonProperty("engagement_depth")        private Double  engagementDepth;

    // [13] Pre-computed in SQL as integer: dominant_channel_ordinal × 6 + stage_ordinal (0-35)
    @JsonProperty("channel_x_stage")         private Integer channelXStage;

    // [14] From organisation record — IQR-binned by mapper
    @JsonProperty("historical_deals_won")    private Integer historicalDealsWon;
}


// ══════════════════════════════════════════════════════════════════════════════
//  MODEL 2 — NormalizedInteractionInput
//  15 encoded double features — exact mirror of the array passed to
//  ml::interaction_score<1.0.0>([...]) in fn::score_interaction (setup_ml.surql).
// ══════════════════════════════════════════════════════════════════════════════

@Data
class NormalizedInteractionInput {
    private String leadId;

    // [0]  Raw count — pass through
    private Double whatsappCount;

    // [1]  Raw count — pass through
    private Double phoneCount;

    // [2]  Raw count — pass through
    private Double emailCount;

    // [3]  whatsapp + phone + email — pass through
    private Double totalInteractions;

    // [4]  email=0, phone=1, whatsapp=2
    private Double dominantChannel;

    // [5]  email=0, phone=1, whatsapp=2
    private Double firstChannel;

    // [6]  email=0, phone=1, whatsapp=2
    private Double lastChannel;

    // [7]  Binary 0/1 — 1 if distinct channels > 1
    private Double isMultiChannel;

    // [8]  distinct_channels − 1
    private Double channelSwitchCount;

    // [9]  Hours from first to last message — pass through
    private Double conversationTimeHours;

    // [10] Ordinal: high_fast=0, high_slow=1, medium_fast=2, medium_slow=3, medium_medium=4
    private Double convTimeBucket;

    // [11] Ordinal: active=0, cold=1, fresh=2, stale=3
    private Double recencyBucket;

    // [12] total_interactions × (1 + avg_sentiment) — pass through
    private Double engagementDepth;

    // [13] dominant_channel_ordinal × 6 + stage_ordinal (0-35) — pass through
    private Double channelXStage;

    // [14] IQR bin 1/2/3 (Q1=0, Q3=3)
    private Double historicalDealsWon;

    // Returns the 15 features in the exact positional order required by ml::interaction_score
    public double[] toFeatureArray() {
        return new double[] {
            whatsappCount,          // [0]
            phoneCount,             // [1]
            emailCount,             // [2]
            totalInteractions,      // [3]
            dominantChannel,        // [4]
            firstChannel,           // [5]
            lastChannel,            // [6]
            isMultiChannel,         // [7]
            channelSwitchCount,     // [8]
            conversationTimeHours,  // [9]
            convTimeBucket,         // [10]
            recencyBucket,          // [11]
            engagementDepth,        // [12]
            channelXStage,          // [13]
            historicalDealsWon      // [14]
        };
    }
}


// ══════════════════════════════════════════════════════════════════════════════
//  MAPPER — InteractionMapper
//
//  Converts RawInteractionInput → NormalizedInteractionInput (15 floats).
//
//  Transformation strategies per feature:
//    [0-3]  PASS-THROUGH  — raw integer counts cast to double
//    [4-6]  LABEL-ENCODE  — channel string → email=0, phone=1, whatsapp=2
//    [7-8]  PASS-THROUGH  — binary/integer cast to double
//    [9]    PASS-THROUGH  — raw float hours
//    [10]   ORDINAL-ENCODE — conv_time_bucket string → 0-4
//    [11]   ORDINAL-ENCODE — recency_bucket string → 0-3
//    [12]   PASS-THROUGH  — pre-computed float
//    [13]   PASS-THROUGH  — pre-computed integer (0-35) cast to double
//    [14]   IQR-BIN       — historical_deals_won → bin 1/2/3 (Q1=0, Q3=3)
// ══════════════════════════════════════════════════════════════════════════════

@Component
class InteractionMapper {

    // ── Normalization divisors — derived from normalized_data.csv training data ──
    // All 15 features must land in [0.0, 1.0] for the ONNX model.
    // Categorical (channel ordinals 0-2, is_multi_channel 0/1, channel_x_stage 0-23)
    // are already in their training-time scale and need no scaling.
    private static final double MAX_CHANNEL_COUNT        = 7.0;   // per-channel max in training
    private static final double MAX_TOTAL_INTERACTIONS   = 18.0;  // total conv max in training
    private static final double MAX_CHANNEL_SWITCH       = 5.0;   // switch count max in training
    private static final double MAX_CONV_TIME_HOURS      = 4780.0;// ≈ 199 days, training max
    private static final double MAX_CONV_TIME_BUCKET_ORD = 4.0;   // ordinal 0-4
    private static final double MAX_RECENCY_BUCKET_ORD   = 3.0;   // ordinal 0-3
    private static final double MAX_ENGAGEMENT_DEPTH     = 27.0;  // total×(1+sent) max in training
    private static final double MAX_HISTORICAL_DEALS     = 8.0;   // raw deals max in training

    public NormalizedInteractionInput normalize(RawInteractionInput raw) {
        NormalizedInteractionInput norm = new NormalizedInteractionInput();
        norm.setLeadId(raw.getLeadId());

        // [0-3] Channel counts — normalized by training max (not raw integers)
        norm.setWhatsappCount(safeInt(raw.getWhatsappCount()) / MAX_CHANNEL_COUNT);
        norm.setPhoneCount(safeInt(raw.getPhoneCount())       / MAX_CHANNEL_COUNT);
        norm.setEmailCount(safeInt(raw.getEmailCount())       / MAX_CHANNEL_COUNT);
        norm.setTotalInteractions(safeInt(raw.getTotalInteractions()) / MAX_TOTAL_INTERACTIONS);

        // [4-6] Channel encoding: email=0, phone=1, whatsapp=2 — no scaling (training range 0-2)
        norm.setDominantChannel(encodeChannel(raw.getDominantChannel()));
        norm.setFirstChannel(encodeChannel(raw.getFirstChannel()));
        norm.setLastChannel(encodeChannel(raw.getLastChannel()));

        // [7] is_multi_channel — binary 0/1 — no scaling
        norm.setIsMultiChannel(safeInt(raw.getIsMultiChannel()));

        // [8] channel_switch_count — normalized by training max 5
        norm.setChannelSwitchCount(safeInt(raw.getChannelSwitchCount()) / MAX_CHANNEL_SWITCH);

        // [9] conversation_time_hours — normalized by training max (~4780 hrs)
        // Training min = 0.0, so no clamping needed (previous 2.0 floor was wrong)
        double rawHours = raw.getConversationTimeHours() != null ? raw.getConversationTimeHours() : 0.0;
        norm.setConversationTimeHours(rawHours / MAX_CONV_TIME_HOURS);

        // [10] conv_time_bucket — encode ordinal 0-4, then normalize by 4
        norm.setConvTimeBucket(encodeConvTimeBucket(raw.getConvTimeBucket()) / MAX_CONV_TIME_BUCKET_ORD);

        // [11] recency_bucket — encode ordinal 0-3, then normalize by 3
        norm.setRecencyBucket(encodeRecencyBucket(raw.getRecencyBucket()) / MAX_RECENCY_BUCKET_ORD);

        // [12] engagement_depth — normalize by training max 27
        norm.setEngagementDepth((raw.getEngagementDepth() != null ? raw.getEngagementDepth() : 0.0)
                / MAX_ENGAGEMENT_DEPTH);

        // [13] channel_x_stage — raw integer 0-23, no scaling (training range 0-23)
        norm.setChannelXStage(raw.getChannelXStage() != null ? raw.getChannelXStage().doubleValue() : 0.0);

        // [14] historical_deals_won — raw count normalized by training max 8
        // FIX: was IQR bin 1/2/3 — model expects deals/8.0 (continuous 0-1 scale)
        norm.setHistoricalDealsWon(safeInt(raw.getHistoricalDealsWon()) / MAX_HISTORICAL_DEALS);

        return norm;
    }

    // channel string → email=0, phone=1, whatsapp=2
    private double encodeChannel(String channel) {
        if (channel == null || channel.isBlank()) return 0.0;
        return switch (channel.toLowerCase().trim()) {
            case "email"          -> 0.0;
            case "phone", "voice" -> 1.0;
            case "whatsapp"       -> 2.0;
            default               -> 0.0;
        };
    }

    // high_fast=0, high_slow=1, medium_fast=2, medium_slow=3, medium_medium=4
    private double encodeConvTimeBucket(String bucket) {
        if (bucket == null || bucket.isBlank()) return 4.0;
        return switch (bucket.toLowerCase().trim()) {
            case "high_fast"     -> 0.0;
            case "high_slow"     -> 1.0;
            case "medium_fast"   -> 2.0;
            case "medium_slow"   -> 3.0;
            case "medium_medium" -> 4.0;
            default              -> 4.0;
        };
    }

    // active=0, cold=1, fresh=2, stale=3
    private double encodeRecencyBucket(String bucket) {
        if (bucket == null || bucket.isBlank()) return 1.0;
        return switch (bucket.toLowerCase().trim()) {
            case "active" -> 0.0;
            case "cold"   -> 1.0;
            case "fresh"  -> 2.0;
            case "stale"  -> 3.0;
            default       -> 1.0;
        };
    }

    private double safeInt(Integer v) { return v != null ? v.doubleValue() : 0.0; }
}


// ══════════════════════════════════════════════════════════════════════════════
//  SERVICE — InteractionService
//
//  Handles all SurrealDB communication:
//    fetchInteractionData()       — joins lead + conversation + org, computes
//                                   all derived fields in SQL
//    callMlPredict()              — calls ml::interaction_score<1.0.0>([15 floats])
//    updateLeadWithScore()        — writes interaction_score to lead record
// ══════════════════════════════════════════════════════════════════════════════

@Service
class InteractionService {

    private static final Logger log = LoggerFactory.getLogger(InteractionService.class);

    @Autowired public SurrealDBClient db;
    @Autowired public ErrorLogService errorLog;

    @Value("${surrealdb.url}")                        private String surrealDbUrl;
    @Value("${surrealdb.namespace:db_salesai}")       private String namespace;
    @Value("${surrealdb.database:salesdb2}")          private String database;
    @Value("${surrealdb.username:root}")              private String username;
    @Value("${surrealdb.password:root}")              private String password;

    private final RestTemplate restTemplate;
    private final ObjectMapper  objectMapper;

    InteractionService(RestTemplate restTemplate, ObjectMapper objectMapper) {
        this.restTemplate = restTemplate;
        this.objectMapper  = objectMapper;
    }


    // ── STEP 2: Fetch interaction data from SurrealDB ─────────────────────────
    //
    // Computes all 15 features in SurrealQL:
    //   - channel counts (whatsapp, phone, email)
    //   - dominant / first / last channel strings
    //   - is_multi_channel, channel_switch_count
    //   - conversation_time_hours
    //   - conv_time_bucket label (high_fast / high_slow / medium_fast / medium_slow / medium_medium)
    //   - recency_bucket label (fresh / active / stale / cold)
    //   - engagement_depth = total_interactions × (1 + avg_sentiment_scalar)
    //   - channel_x_stage = dominant_ordinal × 6 + stage_ordinal  (0-35 integer)
    //   - historical_deals_won from organisation
    //
    public RawInteractionInput fetchInteractionData(String leadId) {

        String lid = leadId.startsWith("lead:") ? leadId : "lead:" + leadId;

        String sql = """
            LET $lead_rec = type::record('%s');
            LET $lead     = (SELECT * FROM ONLY $lead_rec);
            LET $now      = time::now();

            -- All conversations for this lead, sorted by time
            LET $convs = SELECT id, channel, created_at, last_message_at, sentiment
                         FROM conversation WHERE lead = $lead_rec ORDER BY created_at ASC;

            -- Channel counts
            LET $wa_count    = array::len(SELECT id FROM conversation WHERE lead = $lead_rec AND channel = "whatsapp");
            LET $ph_count    = array::len(SELECT id FROM conversation WHERE lead = $lead_rec AND channel IN ["phone","voice"]);
            LET $em_count    = array::len(SELECT id FROM conversation WHERE lead = $lead_rec AND channel = "email");
            LET $total       = $wa_count + $ph_count + $em_count;

            -- Dominant channel (highest count)
            LET $dom_ch = IF $wa_count >= $ph_count AND $wa_count >= $em_count THEN "whatsapp"
                          ELSE IF $ph_count >= $em_count THEN "phone"
                          ELSE "email" END;

            -- First and last channel
            LET $first_ch  = ($convs[0].channel  ?? "email");
            LET $last_conv = ($convs[array::len($convs) - 1] ?? {});
            LET $last_ch   = ($last_conv.channel ?? "email");

            -- Multi-channel
            LET $distinct_ch = array::len(array::distinct(array::map($convs, |$c| $c.channel)));
            LET $is_multi    = IF $distinct_ch > 1 THEN 1 ELSE 0 END;
            LET $switch_cnt  = $distinct_ch - 1;

            -- Conversation time in hours
            LET $first_ts   = ($convs[0].created_at ?? $now);
            LET $last_ts    = ($last_conv.last_message_at ?? $last_conv.created_at ?? $now);
            // LET $time_hours = IF array::len($convs) > 1
            //                   THEN math::fixed(duration::secs($last_ts - $first_ts) / 3600.0, 2)
            //                   ELSE 0.0 END;

            LET $time_hours_raw = IF array::len($convs) > 1
                      THEN math::fixed(duration::secs($last_ts - $first_ts) / 3600.0, 2)
                      ELSE 0.0 END;

            -- Clamp to model's minimum seen during training (2.0 hours)
            -- Leads closing in minutes will be treated as 2.0 hours minimum
            LET $time_hours = IF $time_hours_raw < 2.0 THEN 2.0 ELSE $time_hours_raw END;

            -- conv_time_bucket: high = >10 convs, medium = 4-10, low = <4
            --                   fast = <24h, slow = >72h, medium = 24-72h
            LET $hi_vol   = $total > 10;
            LET $med_vol  = $total >= 4 AND $total <= 10;
            LET $fast_t   = $time_hours < 24.0;
            LET $slow_t   = $time_hours > 72.0;
            LET $conv_bucket = IF $hi_vol  AND $fast_t  THEN "high_fast"
                               ELSE IF $hi_vol  AND $slow_t  THEN "high_slow"
                               ELSE IF $med_vol AND $fast_t  THEN "medium_fast"
                               ELSE IF $med_vol AND $slow_t  THEN "medium_slow"
                               ELSE                               "medium_medium" END;

            -- Recency bucket
            LET $days_since  = math::floor(duration::secs($now - $last_ts) / 86400);
            LET $rec_bucket  = IF $days_since <= 3  THEN "fresh"
                               ELSE IF $days_since <= 7  THEN "active"
                               ELSE IF $days_since <= 21 THEN "stale"
                               ELSE                           "cold" END;

            -- Average sentiment scalar across all conversations
            LET $sent_map    = array::map($convs, |$c|
                IF $c.sentiment = "SATISFIED" OR $c.sentiment = "POSITIVE" THEN 1.0
                ELSE IF $c.sentiment = "INTERESTED"                         THEN 0.8
                ELSE IF $c.sentiment = "NEGOTIATING" OR $c.sentiment = "URGENT" THEN 0.5
                ELSE IF $c.sentiment = "CURIOUS"                            THEN 0.3
                ELSE IF $c.sentiment = "NEUTRAL"                            THEN 0.0
                ELSE IF $c.sentiment = "DISSATISFIED"                       THEN -0.5
                ELSE IF $c.sentiment = "NEGATIVE" OR $c.sentiment = "ANGRY" THEN -1.0
                ELSE 0.0 END
            );
            LET $avg_sent  = IF array::len($sent_map) > 0
                             THEN math::sum($sent_map) / array::len($sent_map)
                             ELSE 0.0 END;

            -- engagement_depth = total_interactions × (1 + avg_sentiment)
            LET $eng_depth = math::fixed($total * (1.0 + $avg_sent), 4);

            -- Pipeline stage ordinal
            LET $stage_ord = IF $lead.state = "NEW_LEAD"              THEN 0
                ELSE IF $lead.state = "MANUAL_FOLLOW_UP"              THEN 1
                ELSE IF $lead.state = "SALES_FOLLOW_UP"               THEN 2
                ELSE IF $lead.state = "SALES_QUALIFIED"               THEN 3
                ELSE IF $lead.state = "QUOTATION"                     THEN 4
                ELSE IF $lead.state = "FOLLOW_UP_NEGOTIATION"         THEN 5
                ELSE IF $lead.state = "CLOSED"                        THEN 6
                ELSE 0 END;

            -- dominant_channel ordinal
            LET $dom_ord = IF $dom_ch = "email"    THEN 0
                           ELSE IF $dom_ch = "phone" OR $dom_ch = "voice" THEN 1
                           ELSE 2 END;

            -- channel_x_stage = dominant_ordinal × 6 + stage_ordinal (0-35)
            LET $cxs = $dom_ord * 6 + $stage_ord;

            -- Organisation
            LET $org = $lead.organisation;

            SELECT
                type::string(id)                         AS lead_id,
                $wa_count                                AS whatsapp_count,
                $ph_count                                AS phone_count,
                $em_count                                AS email_count,
                $total                                   AS total_interactions,
                $dom_ch                                  AS dominant_channel,
                $first_ch                                AS first_channel,
                $last_ch                                 AS last_channel,
                $is_multi                                AS is_multi_channel,
                $switch_cnt                              AS channel_switch_count,
                $time_hours                              AS conversation_time_hours,
                $conv_bucket                             AS conv_time_bucket,
                $rec_bucket                              AS recency_bucket,
                $eng_depth                               AS engagement_depth,
                $cxs                                     AS channel_x_stage,
                ($org.historical_deals_won ?? 0)         AS historical_deals_won
            FROM $lead_rec;
            """.formatted(lid);

        try {
            List<Map<String, Object>> results = db.queryMl(sql, Map.of());
            return mapFirstResult(results, lid);
        } catch (Exception e) {
            log.error("Failed to fetch interaction data for {}: {}", lid, e.getMessage());
            return new RawInteractionInput();
        }
    }


    // ── STEP 4: Call ml::interaction_score<1.0.0> with 15 floats ─────────────
    public double callMlPredict(NormalizedInteractionInput norm) {

        double[] f = norm.toFeatureArray();

        String sql = String.format(Locale.US, """
            LET $prediction = ml::interaction_score<1.0.0>([
                %f,  -- [0]  whatsapp_count            (count/7, range 0-1)
                %f,  -- [1]  phone_count               (count/7, range 0-1)
                %f,  -- [2]  email_count               (count/7, range 0-1)
                %f,  -- [3]  total_interactions        (total/18, range 0-1)
                %f,  -- [4]  dominant_channel          (0=email,1=phone,2=whatsapp)
                %f,  -- [5]  first_channel             (0=email,1=phone,2=whatsapp)
                %f,  -- [6]  last_channel              (0=email,1=phone,2=whatsapp)
                %f,  -- [7]  is_multi_channel          (binary 0/1)
                %f,  -- [8]  channel_switch_count      (switch/5, range 0-1)
                %f,  -- [9]  conversation_time_hours   (hours/4780, range 0-1)
                %f,  -- [10] conv_time_bucket          (ordinal/4, range 0-1)
                %f,  -- [11] recency_bucket            (ordinal/3, range 0-1)
                %f,  -- [12] engagement_depth          (depth/27, range 0-1)
                %f,  -- [13] channel_x_stage           (0-23 integer, no scaling)
                %f   -- [14] historical_deals_won      (deals/8, range 0-1)
            ]);
            RETURN { model: "interaction_score", score: $prediction };
            """,
            f[0],  f[1],  f[2],  f[3],  f[4],
            f[5],  f[6],  f[7],  f[8],  f[9],
            f[10], f[11], f[12], f[13], f[14]
        );

        log.debug("[interaction_score ml] lead={} payload=\n{}", norm.getLeadId(), sql);

        try {
            List<Map<String, Object>> results = db.queryMl(sql, Map.of());
            return parsePredictionResult(results, norm.getLeadId());
        } catch (Exception e) {
            if (errorLog != null) {
                errorLog.log("ML_INTERACTION_SCORE_FAILED",
                    "interaction_score prediction failed for lead=" + norm.getLeadId(),
                    norm.getLeadId(), null, e);
            }
            log.error("[interaction_score] Failed lead={}: {}", norm.getLeadId(), e.getMessage());
            return 0.0;
        }
    }


    // ── STEP 5: Write interaction_score back to lead record ───────────────────
    public void updateLeadWithScore(String leadId, double score) {
        String sql = String.format(
            "UPDATE type::record('%s') SET interaction_score = %f, updated_at = time::now();",
            leadId, score
        );
        HttpEntity<String> req = new HttpEntity<>(sql, buildHeaders());
        restTemplate.exchange(surrealDbUrl + "/sql", HttpMethod.POST, req, String.class);
    }


    // ── Private helpers ───────────────────────────────────────────────────────

    private RawInteractionInput mapFirstResult(List<Map<String, Object>> results, String leadId) {
        if (results == null || results.isEmpty()) {
            log.warn("No results found for lead: {}", leadId);
            return new RawInteractionInput();
        }
        return objectMapper.convertValue(results.get(0), RawInteractionInput.class);
    }

    private double parsePredictionResult(List<Map<String, Object>> results, String leadId) {
        if (results == null || results.isEmpty()) return 0.0;
        try {
            for (Map<String, Object> row : results) {
                if (row != null && "interaction_score".equals(row.get("model"))) {
                    Object scoreObj = row.get("score");
                    if (scoreObj == null) continue;
                    double raw = scoreObj instanceof List<?> list && !list.isEmpty()
                        ? Double.parseDouble(list.get(0).toString())
                        : Double.parseDouble(scoreObj.toString());
                    return raw;
                }
            }
        } catch (Exception e) {
            log.error("Failed to parse interaction_score response for lead {}: {}", leadId, e.getMessage());
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
//  PIPELINE ORCHESTRATOR — InteractionPipelineService
//  Ties steps 2-5 together for one lead.
// ══════════════════════════════════════════════════════════════════════════════

@Service
class InteractionPipelineService {

    private static final Logger log = LoggerFactory.getLogger(InteractionPipelineService.class);

    private final InteractionService interactionService;
    private final InteractionMapper  mapper;

    InteractionPipelineService(InteractionService interactionService, InteractionMapper mapper) {
        this.interactionService = interactionService;
        this.mapper             = mapper;
    }

    public void scoreLeadById(String leadId) {
        log.info("[InteractionScore] START lead={}", leadId);
        try {
            // Step 2: Fetch raw data from SurrealDB
            RawInteractionInput raw = interactionService.fetchInteractionData(leadId);
            log.debug("[Step 2] Fetched: total_interactions={} dominant={} recency={}",
                raw.getTotalInteractions(), raw.getDominantChannel(), raw.getRecencyBucket());

            // Step 3: Encode string buckets → ordinals, IQR-bin historical_deals_won
            NormalizedInteractionInput normalized = mapper.normalize(raw);
            log.debug("[Step 3] Normalized: dominantChannel={} recencyBucket={} historicalDealsWon={}",
                normalized.getDominantChannel(),
                normalized.getRecencyBucket(),
                normalized.getHistoricalDealsWon());

            // Step 4: Call ml::interaction_score<1.0.0>
            double score = interactionService.callMlPredict(normalized);
            log.info("[Step 4] interaction_score={}", String.format("%.2f", score));

            // Step 5: Write back to lead
            interactionService.updateLeadWithScore(leadId, score);

            log.info("[InteractionScore] DONE lead={} score={}", leadId, String.format("%.2f", score));

        } catch (Exception e) {
            log.error("[InteractionScore] ERROR lead={}: {}", leadId, e.getMessage(), e);
            throw new RuntimeException("InteractionScore pipeline failed for lead [" + leadId + "]", e);
        }
    }
}


// ══════════════════════════════════════════════════════════════════════════════
//  REST CONTROLLER — InteractionController
// ══════════════════════════════════════════════════════════════════════════════

@RestController
@RequestMapping("/api/v1/interaction-score")
class InteractionController {

    private static final Logger log = LoggerFactory.getLogger(InteractionController.class);

    private final InteractionPipelineService pipelineService;

    InteractionController(InteractionPipelineService pipelineService) {
        this.pipelineService = pipelineService;
    }

    // SurrealDB event or external service POSTs: { "lead_id": "lead:abc123" }
    @PostMapping("/trigger")
    public ResponseEntity<Map<String, Object>> handleTrigger(
            @RequestBody Map<String, String> payload) {
        String leadId = payload.get("lead_id");
        if (leadId == null || leadId.isBlank())
            return ResponseEntity.badRequest().body(
                Map.of("status", "error", "message", "lead_id is required"));
        pipelineService.scoreLeadById(leadId);
        return ResponseEntity.ok(Map.of("status", "scored", "lead_id", leadId));
    }

    // Manual trigger: POST /api/v1/interaction-score/score/lead:abc123
    @PostMapping("/score/{leadId}")
    public ResponseEntity<Map<String, Object>> scoreById(@PathVariable String leadId) {
        pipelineService.scoreLeadById(leadId);
        return ResponseEntity.ok(Map.of("status", "scored", "lead_id", leadId));
    }

    // Health check
    @GetMapping("/health")
    public ResponseEntity<Map<String, String>> health() {
        return ResponseEntity.ok(Map.of("status", "UP"));
    }
}
