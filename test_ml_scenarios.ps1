<#
.SYNOPSIS
    Vitasales ML Model Test Suite — 5 Models × 7 Scenarios = 35 checks

.DESCRIPTION
    Organized BY MODEL so each model's behaviour is clearly visible.
    Calls ml::model<version>([...]) directly — no lead records needed.
    Each model is tested against all 7 scenarios:
      S1 Fast-Track Hot Lead   S2 Ideal Hot Lead       S3 Cold / Window-Shopping
      S4 Enterprise Deal       S5 At-Risk / Stalled    S6 Near-Close
      S7 Zombie / Dead Lead

.USAGE
    .\test_ml_scenarios.ps1
    .\test_ml_scenarios.ps1 -Endpoint http://prod-server:8000 -Username root -Password secret
#>

param(
    [string]$Endpoint  = "http://localhost:8000",
    [string]$Namespace = "vitasales",
    [string]$Database  = "vitasales",
    [string]$Username  = "root",
    [string]$Password  = "root"
)

$AUTH  = "${Username}:${Password}"
$PASS  = 0; $WARN = 0; $FAIL = 0

# ── Colour helpers ────────────────────────────────────────────────────────────
function Write-ModelBanner {
    param([string]$Text)
    $line = "=" * 72
    Write-Host "`n`n$line"                   -ForegroundColor Magenta
    Write-Host "  $Text"                     -ForegroundColor Magenta
    Write-Host $line                         -ForegroundColor Magenta
}
function Write-ScenarioHeader {
    param([string]$Text)
    Write-Host "`n  ── $Text" -ForegroundColor Yellow
}
function Write-Score {
    param([string]$Label, [string]$Score, [string]$Range, [string]$Status)
    $col = switch ($Status) { "PASS"{"Green"} "WARN"{"DarkYellow"} default{"Red"} }
    Write-Host ("     {0,-42} {1,6}    expected: {2}" -f $Label, $Score, $Range) `
        -ForegroundColor $col
}

# ── Core caller — sends one ML inference to SurrealDB ────────────────────────
function Invoke-ML {
    param(
        [string]  $Model,
        [string]  $Version = "1.0.0",
        [double[]]$Feat,
        [string]  $Label,
        [double]  $ExpLow  = 0.0,
        [double]  $ExpHigh = 1.0
    )
    # Append 'f' suffix so SurrealDB treats every value as float32.
    # Without this, whole numbers like 9, 1, 0 are sent as int64 and
    # LightGBM ONNX models fail with "Failed to reshape tensor to input dimensions".
    $featStr = ($Feat | ForEach-Object {
        $s = $_.ToString("G7")
        if ($s -match '^-?\d+$') { "${s}.0f" } else { "${s}f" }
    }) -join ", "
    $sql = "RETURN ml::${Model}<${Version}>([${featStr}]);"

    try {
        $raw = & curl -s -X POST "$Endpoint/sql" `
                   -H "surreal-ns: $Namespace" `
                   -H "surreal-db: $Database" `
                   -u $AUTH -d $sql 2>$null

        $score = $null
        if ($raw -match '"close_probability"\s*:\s*([\d.Ee+\-]+)') { $score = [double]$Matches[1] }
        elseif ($raw -match '"result"\s*:\s*([\d.Ee+\-]+)')         { $score = [double]$Matches[1] }

        if ($null -ne $score) {
            $pct    = [math]::Round($score * 100, 1)
            $range  = "$([int]($ExpLow*100))–$([int]($ExpHigh*100))%"
            $status = if ($score -ge $ExpLow -and $score -le $ExpHigh) { "PASS" }
                      elseif ([math]::Abs($score - ($ExpLow+$ExpHigh)/2) -lt 0.20) { "WARN" }
                      else { "FAIL" }
            Write-Score $Label "${pct}%" $range $status
            if ($status -eq "PASS") { $script:PASS++ } elseif ($status -eq "WARN") { $script:WARN++ } else { $script:FAIL++ }
            return $pct
        }
        Write-Score $Label "ERROR" "N/A" "FAIL"
        Write-Host "       $raw" -ForegroundColor DarkRed
        $script:FAIL++; return $null
    } catch {
        Write-Score $Label "curl-err" "N/A" "FAIL"
        $script:FAIL++; return $null
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# SCENARIO KEY  (feature values used for each of the 7 scenarios)
#
#  S1  Fast-Track Hot Lead      New→Quotation 2 days, 2 convs, buying, new customer
#  S2  Ideal Hot Lead           Repeat(5 deals), 6 convs, all channels, 15d pipeline
#  S3  Cold / Window-Shopping   Angry, 1 WhatsApp, no quotation, 45d stale
#  S4  Enterprise Deal          600k hybrid, 60d negotiation, 9 convs, repeat(2)
#  S5  At-Risk / Stalled        Quotation sent then went silent 25d, concerned
#  S6  Near-Close               Stage 11, repeat(8 deals), 10 convs, all positive
#  S7  Zombie Lead              90d, 1 phone call, no progress, no quotation
#
# ENCODING REFERENCE
#   primary_sentiment : angry=0  concerned=1  confused=2  interested=3  neutral=4  satisfied=5  urgent=6
#   intent            : at_risk=0  buying=1  comparing=2  complaining=3  curious=4  exploring=5
#                       negotiating=6  requesting_info=7  undecided=8  window_shopping=9
#   message_quality   : detailed=0  long=1  medium=2  short=3
#   product_category  : chiller=0  cooler=1  hybrid=2
#   price_tier        : enterprise=0  high=1  low=2  mid=3
#   capacity_bin      : 1-5t=0  11-20t=1  21-50t=2  51-100t=3  6-10t=4
#   channel           : email=0  phone=1  whatsapp=2
#   recency(interaction): active=0  cold=1  fresh=2  stale=3
#   recency(lead_qual)  : cold=1  stale=2  active=3  fresh=4
#   IQR bins (lead_qual): 1=low  2=mid  3=high
# ─────────────────────────────────────────────────────────────────────────────

Write-Host "`n$('='*72)" -ForegroundColor Cyan
Write-Host "  Vitasales ML Model Test Suite  |  $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -ForegroundColor Cyan
Write-Host "  5 Models x 7 Scenarios = 35 checks" -ForegroundColor Cyan
Write-Host "  Endpoint : $Endpoint  |  NS: $Namespace  |  DB: $Database" -ForegroundColor Gray
Write-Host "$('='*72)" -ForegroundColor Cyan


# =============================================================================
# ██████████████████████████████████████████████████████████████████████████
#  MODEL 1 / 5 — close_prob   (Deal-Risk)
#  29 features: capacity_tons, fe_stage_ordinal, fe_has_urgency_keyword,
#  fe_has_price_mention, fe_log_base_price, fe_total_price_with_tax,
#  fe_log_capacity, fe_days_since_last_message, fe_days_in_pipeline,
#  fe_message_length, fe_summary_length, fe_stage_x_sentiment,
#  fe_quotation_x_satisfied, fe_quotation_x_urgent, fe_complete_x_quotation,
#  fe_angry_x_high_stage, fe_urgent_x_high_stage, fe_enterprise_deal,
#  fe_dissatisfied_x_late, fe_interested_x_complete, pipeline_stage_enc,
#  source_channel_type_enc, product_category_enc, product_type_enc,
#  product_name_enc, product_sku_enc, organisation_industry_enc,
#  lead_completeness_enc, quotation_sent_enc
# ██████████████████████████████████████████████████████████████████████████
# =============================================================================
Write-ModelBanner "MODEL 1/5 — close_prob  (Deal-Risk)  |  29 features"

Write-ScenarioHeader "S1 Fast-Track   stage=9  pipeline=2d  quot=1  satisfied  buying"
Invoke-ML "close_prob" "1.0.0" @(10.0,9.0,1.0,1.0,11.35,100300.0,2.30,0.5,2.0,450.0,350.0,8.1,1.0,0.8,0.0,0.0,0.8,0.0,0.0,0.8,9.0,1.0,0.0,2.0,8.0,15.0,3.0,0.9,1.0) `
    "S1  stage=9, 2d pipeline, quot sent, buying, new cust" 0.20 0.60

Write-ScenarioHeader "S2 Ideal Hot    stage=10  pipeline=15d  quot=1  repeat(5)  all channels"
Invoke-ML "close_prob" "1.0.0" @(20.0,10.0,1.0,1.0,12.43,295000.0,2.99,1.0,15.0,600.0,480.0,9.5,1.0,0.5,1.0,0.0,0.5,0.0,0.0,1.0,10.0,2.0,0.0,5.0,12.0,20.0,4.0,1.0,1.0) `
    "S2  stage=10, 15d, quot sent, repeat customer" 0.50 0.90

Write-ScenarioHeader "S3 Cold Lead    stage=1  pipeline=45d  quot=0  angry  window_shopping"
Invoke-ML "close_prob" "1.0.0" @(3.0,1.0,0.0,0.0,10.13,29500.0,1.10,10.0,45.0,80.0,45.0,-4.5,0.0,0.0,0.0,0.0,0.0,0.0,1.0,0.0,1.0,2.0,1.0,3.0,2.0,5.0,1.0,0.3,0.0) `
    "S3  stage=1, 45d, no quot, angry, dissatisfied_late=1" 0.0 0.25

Write-ScenarioHeader "S4 Enterprise   stage=9  pipeline=60d  quot=1  enterprise=1  repeat(2)"
Invoke-ML "close_prob" "1.0.0" @(50.0,9.0,0.0,1.0,13.31,708000.0,3.91,2.0,60.0,800.0,490.0,3.6,0.4,0.0,0.0,0.0,0.0,1.0,0.0,0.4,9.0,1.0,2.0,15.0,20.0,30.0,3.0,0.95,1.0) `
    "S4  stage=9, 60d, enterprise=1, 600k hybrid, repeat" 0.35 0.75

Write-ScenarioHeader "S5 At-Risk      stage=7  silent=25d  concerned  dissatisfied_late=0.4"
Invoke-ML "close_prob" "1.0.0" @(15.0,7.0,0.0,1.0,11.92,177000.0,2.71,25.0,40.0,200.0,150.0,-1.4,0.0,0.0,0.0,0.0,0.0,0.0,0.4,0.0,7.0,0.0,0.0,4.0,10.0,18.0,2.0,0.65,1.0) `
    "S5  stage=7, 25d silent, concerned, stall signals" 0.05 0.40

Write-ScenarioHeader "S6 Near-Close   stage=11  pipeline=25d  quot=1  repeat(8)  all channels hot"
Invoke-ML "close_prob" "1.0.0" @(25.0,11.0,1.0,1.0,12.68,377600.0,3.22,1.0,25.0,700.0,499.0,9.9,1.0,0.5,1.0,0.0,0.5,0.0,0.0,1.0,11.0,2.0,0.0,7.0,14.0,22.0,5.0,1.0,1.0) `
    "S6  stage=11, repeat(8), all positive, complete" 0.60 0.90

Write-ScenarioHeader "S7 Zombie Lead  stage=2  pipeline=90d  silent=45d  1 call  no quot"
Invoke-ML "close_prob" "1.0.0" @(5.0,2.0,0.0,0.0,10.71,53100.0,1.61,45.0,90.0,120.0,100.0,0.1,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,2.0,1.0,1.0,4.0,6.0,10.0,2.0,0.4,0.0) `
    "S7  stage=2, 90d, 1 phone call, no quot, no urgency" 0.0 0.20


# =============================================================================
# ██████████████████████████████████████████████████████████████████████████
#  MODEL 2 / 5 — consumer_score   (Consumer sentiment signals)
#  12 features: primary_sentiment, sentiment_score, sentiment_combo_score,
#  intent, message_quality, summary_length, has_action_milestone,
#  stage_velocity, historical_deals_won, is_repeat_customer,
#  historical_avg_sentiment, industry_close_rate
# ██████████████████████████████████████████████████████████████████████████
# =============================================================================
Write-ModelBanner "MODEL 2/5 — consumer_score  (Consumer)  |  12 features"

Write-ScenarioHeader "S1 Fast-Track   satisfied(5)  score=0.8  buying  detailed  new_cust  vel=4.5"
Invoke-ML "consumer_score" "1.0.0" @(
    5.0,   # primary_sentiment  satisfied
    0.8,   # sentiment_score
    7.2,   # sentiment_combo_score  (9*0.8)
    1.0,   # intent  buying
    0.0,   # message_quality  detailed
  350.0,   # summary_length
    1.0,   # has_action_milestone
    4.5,   # stage_velocity  (9 stages / 2 days — very high)
    0.0,   # historical_deals_won  new customer
    0.0,   # is_repeat_customer
    0.0,   # historical_avg_sentiment
    0.55   # industry_close_rate
) "S1  satisfied, buying, new cust, vel=4.5 (fast)" 0.05 0.40
# NOTE: Observed ~7.7% in live test — model penalises new customer + no history heavily

Write-ScenarioHeader "S2 Ideal Hot    satisfied(5)  score=0.85  buying  repeat(5 deals)  hist_sent=0.75"
Invoke-ML "consumer_score" "1.0.0" @(
    5.0,   # primary_sentiment  satisfied
    0.85,  # sentiment_score
    7.65,  # sentiment_combo_score
    1.0,   # intent  buying
    0.0,   # message_quality  detailed
  480.0,   # summary_length
    1.0,   # has_action_milestone
    0.7,   # stage_velocity
    5.0,   # historical_deals_won
    1.0,   # is_repeat_customer
    0.75,  # historical_avg_sentiment
    0.65   # industry_close_rate
) "S2  satisfied, buying, repeat(5), hist_sent=0.75" 0.55 1.0

Write-ScenarioHeader "S3 Cold Lead    angry(0)  score=-0.8  window_shopping  short  no_history"
Invoke-ML "consumer_score" "1.0.0" @(
    0.0,   # primary_sentiment  angry
   -0.8,   # sentiment_score
   -4.8,   # sentiment_combo_score
    9.0,   # intent  window_shopping
    3.0,   # message_quality  short
   45.0,   # summary_length
    0.0,   # has_action_milestone
    0.03,  # stage_velocity  very slow
    0.0,   # historical_deals_won
    0.0,   # is_repeat_customer
   -0.2,   # historical_avg_sentiment
    0.38   # industry_close_rate  lowest
) "S3  angry, window_shopping, short, no history" 0.0 0.15

Write-ScenarioHeader "S4 Enterprise   interested(3)  score=0.4  negotiating  repeat(2 deals)"
Invoke-ML "consumer_score" "1.0.0" @(
    3.0,   # primary_sentiment  interested
    0.4,   # sentiment_score
    3.6,   # sentiment_combo_score
    6.0,   # intent  negotiating
    0.0,   # message_quality  detailed
  490.0,   # summary_length
    1.0,   # has_action_milestone
    0.15,  # stage_velocity  (9/60 — slow)
    2.0,   # historical_deals_won
    1.0,   # is_repeat_customer
    0.5,   # historical_avg_sentiment
    0.55   # industry_close_rate
) "S4  interested, negotiating, repeat(2), slow vel" 0.30 0.75

Write-ScenarioHeader "S5 At-Risk      concerned(1)  score=-0.2  at_risk  new_cust  40d pipeline"
Invoke-ML "consumer_score" "1.0.0" @(
    1.0,   # primary_sentiment  concerned
   -0.2,   # sentiment_score
   -1.4,   # sentiment_combo_score
    0.0,   # intent  at_risk
    2.0,   # message_quality  medium
  150.0,   # summary_length
    1.0,   # has_action_milestone
   0.175,  # stage_velocity  (7/40)
    0.0,   # historical_deals_won
    0.0,   # is_repeat_customer
    0.3,   # historical_avg_sentiment
    0.45   # industry_close_rate
) "S5  concerned, at_risk, new cust, 40d stall" 0.03 0.20

Write-ScenarioHeader "S6 Near-Close   satisfied(5)  score=0.9  buying  repeat(8 deals)  hist_sent=0.85"
Invoke-ML "consumer_score" "1.0.0" @(
    5.0,   # primary_sentiment  satisfied
    0.9,   # sentiment_score
    8.1,   # sentiment_combo_score  (9*0.9)
    1.0,   # intent  buying
    0.0,   # message_quality  detailed
  499.0,   # summary_length
    1.0,   # has_action_milestone
    0.44,  # stage_velocity  (11/25)
    8.0,   # historical_deals_won
    1.0,   # is_repeat_customer
    0.85,  # historical_avg_sentiment
    0.67   # industry_close_rate  highest
) "S6  satisfied, buying, repeat(8), hist_sent=0.85" 0.80 1.0
# NOTE: Observed ~96% in live test — consumer_score peaks when quot+satisfied+repeat+high_stage

Write-ScenarioHeader "S7 Zombie Lead  confused(2)  score=0.0  curious  no_history  vel=0.02"
Invoke-ML "consumer_score" "1.0.0" @(
    2.0,   # primary_sentiment  confused
    0.0,   # sentiment_score
    0.0,   # sentiment_combo_score
    4.0,   # intent  curious
    2.0,   # message_quality  medium
  100.0,   # summary_length
    0.0,   # has_action_milestone
    0.02,  # stage_velocity  (2/90 — dead slow)
    0.0,   # historical_deals_won
    0.0,   # is_repeat_customer
    0.1,   # historical_avg_sentiment
    0.45   # industry_close_rate
) "S7  confused, curious, no history, vel=0.02" 0.0 0.10


# =============================================================================
# ██████████████████████████████████████████████████████████████████████████
#  MODEL 3 / 5 — interaction_score   (Channel engagement patterns)
#  15 features: whatsapp_count, phone_count, email_count, total_interactions,
#  dominant_channel, first_channel, last_channel, is_multi_channel,
#  channel_switch_count, conversation_time_hours, conv_time_bucket,
#  recency_bucket, engagement_depth, channel_x_stage, historical_deals_won
# ██████████████████████████████████████████████████████████████████████████
# =============================================================================
Write-ModelBanner "MODEL 3/5 — interaction_score  (Interaction)  |  15 features"

Write-ScenarioHeader "S1 Fast-Track   WA+Phone  2 convs  2h  fresh  multi_channel=1"
Invoke-ML "interaction_score" "1.0.0" @(
    1.0,  # whatsapp_count
    1.0,  # phone_count
    0.0,  # email_count
    2.0,  # total_interactions
    1.0,  # dominant_channel  phone
    2.0,  # first_channel  whatsapp
    1.0,  # last_channel  phone
    1.0,  # is_multi_channel
    1.0,  # channel_switch_count
    2.0,  # conversation_time_hours
    0.0,  # conv_time_bucket  high_fast
    2.0,  # recency_bucket  fresh
    1.6,  # engagement_depth  (2*0.8)
   18.0,  # channel_x_stage
    0.0   # historical_deals_won  new customer
) "S1  2 convs (WA+Phone), 2h, fresh, multi" 0.05 0.35
# NOTE: interaction_score is LOW without quotation active — observed ~3-12% at early stages

Write-ScenarioHeader "S2 Ideal Hot    WA+Phone+Email  6 convs  48h  fresh  repeat(5)"
Invoke-ML "interaction_score" "1.0.0" @(
    3.0,  # whatsapp_count
    2.0,  # phone_count
    1.0,  # email_count
    6.0,  # total_interactions
    2.0,  # dominant_channel  whatsapp
    0.0,  # first_channel  email
    2.0,  # last_channel  whatsapp
    1.0,  # is_multi_channel
    2.0,  # channel_switch_count
   48.0,  # conversation_time_hours
    1.0,  # conv_time_bucket
    2.0,  # recency_bucket  fresh
    5.1,  # engagement_depth
   28.0,  # channel_x_stage
    5.0   # historical_deals_won  repeat(5)
) "S2  6 convs (WA+Ph+Em), 48h, fresh, repeat(5)" 0.45 0.85

Write-ScenarioHeader "S3 Cold Lead    WhatsApp only  1 conv  0.5h  COLD  negative engagement"
Invoke-ML "interaction_score" "1.0.0" @(
    1.0,  # whatsapp_count
    0.0,  # phone_count
    0.0,  # email_count
    1.0,  # total_interactions
    2.0,  # dominant_channel  whatsapp
    2.0,  # first_channel
    2.0,  # last_channel
    0.0,  # is_multi_channel
    0.0,  # channel_switch_count
    0.5,  # conversation_time_hours
    4.0,  # conv_time_bucket
    1.0,  # recency_bucket  COLD >21d
   -0.8,  # engagement_depth  negative
    2.0,  # channel_x_stage
    0.0   # historical_deals_won
) "S3  1 WA conv, 0.5h, COLD, negative, no history" 0.0 0.10

Write-ScenarioHeader "S4 Enterprise   WA+Phone+Email  9 convs  240h  active  repeat(2)"
Invoke-ML "interaction_score" "1.0.0" @(
    2.0,  # whatsapp_count
    4.0,  # phone_count
    3.0,  # email_count
    9.0,  # total_interactions
    1.0,  # dominant_channel  phone
    0.0,  # first_channel  email
    1.0,  # last_channel  phone
    1.0,  # is_multi_channel
    2.0,  # channel_switch_count
  240.0,  # conversation_time_hours
    2.0,  # conv_time_bucket
    3.0,  # recency_bucket  active ≤7d
    4.5,  # engagement_depth
   30.0,  # channel_x_stage
    2.0   # historical_deals_won  repeat(2)
) "S4  9 convs (WA+Ph+Em), 240h, active, repeat(2)" 0.30 0.75

Write-ScenarioHeader "S5 At-Risk      5 convs  72h  COLD (went silent >21d)  multi_channel"
Invoke-ML "interaction_score" "1.0.0" @(
    2.0,  # whatsapp_count
    1.0,  # phone_count
    2.0,  # email_count
    5.0,  # total_interactions
    0.0,  # dominant_channel  email
    1.0,  # first_channel  phone
    0.0,  # last_channel  email
    1.0,  # is_multi_channel
    2.0,  # channel_switch_count
   72.0,  # conversation_time_hours
    2.0,  # conv_time_bucket
    1.0,  # recency_bucket  COLD >21d
    1.0,  # engagement_depth  low
   14.0,  # channel_x_stage
    0.0   # historical_deals_won
) "S5  5 convs, 72h, went COLD, recency=1" 0.03 0.20

Write-ScenarioHeader "S6 Near-Close   WA+Phone+Email  10 convs  96h  active  repeat(8)"
Invoke-ML "interaction_score" "1.0.0" @(
    5.0,  # whatsapp_count
    3.0,  # phone_count
    2.0,  # email_count
   10.0,  # total_interactions
    2.0,  # dominant_channel  whatsapp
    0.0,  # first_channel  email
    2.0,  # last_channel  whatsapp
    1.0,  # is_multi_channel
    2.0,  # channel_switch_count
   96.0,  # conversation_time_hours
    1.0,  # conv_time_bucket
    3.0,  # recency_bucket  active ≤7d
    9.0,  # engagement_depth  (10*0.9)
   34.0,  # channel_x_stage
    8.0   # historical_deals_won  repeat(8)
) "S6  10 convs (WA+Ph+Em), 96h, active, repeat(8)" 0.55 0.85
# NOTE: Observed ~71% at quotation stage in live test

Write-ScenarioHeader "S7 Zombie Lead  Phone only  1 conv  0.25h  COLD  zero engagement"
Invoke-ML "interaction_score" "1.0.0" @(
    0.0,  # whatsapp_count
    1.0,  # phone_count
    0.0,  # email_count
    1.0,  # total_interactions
    1.0,  # dominant_channel  phone
    1.0,  # first_channel
    1.0,  # last_channel
    0.0,  # is_multi_channel
    0.0,  # channel_switch_count
    0.25, # conversation_time_hours
    4.0,  # conv_time_bucket
    1.0,  # recency_bucket  COLD >21d
    0.0,  # engagement_depth  zero
    2.0,  # channel_x_stage
    0.0   # historical_deals_won
) "S7  1 phone call, 0.25h, COLD, zero engagement" 0.0 0.08


# =============================================================================
# ██████████████████████████████████████████████████████████████████████████
#  MODEL 4 / 5 — product_quotation_score   (Product + quotation signals)
#  17 features: product_category, product_type, product_complexity,
#  base_price, tax_rate, price_tier, capacity_tons, capacity_bin,
#  product_x_capacity, total_price_with_tax, capacity_price_ratio,
#  quotation_sent, is_enterprise_deal, industry_close_rate,
#  stage_raw, is_repeat_customer, days_in_pipeline
# ██████████████████████████████████████████████████████████████████████████
# =============================================================================
Write-ModelBanner "MODEL 4/5 — product_quotation_score  (Product-Quotation)  |  17 features"

Write-ScenarioHeader "S1 Fast-Track   chiller(0)  10t  85k  quot=1  stage=9  2d  new_cust"
Invoke-ML "product_quotation_score" "1.0.0" @(
    0.0,       # product_category  chiller
    2.0,       # product_type
    2.5,       # product_complexity
85000.0,       # base_price
   18.0,       # tax_rate
    2.0,       # price_tier  low
   10.0,       # capacity_tons
    4.0,       # capacity_bin  6-10t
   14.0,       # product_x_capacity  (2*5+4)
100300.0,      # total_price_with_tax
    0.0001,    # capacity_price_ratio
    1.0,       # quotation_sent
    0.0,       # is_enterprise_deal
    0.55,      # industry_close_rate
    9.0,       # stage_raw
    0.0,       # is_repeat_customer
    2.0        # days_in_pipeline
) "S1  chiller 10t 85k, quot sent, stage=9, 2d" 0.30 0.75

Write-ScenarioHeader "S2 Ideal Hot    chiller(0)  20t  250k  quot=1  stage=10  15d  repeat"
Invoke-ML "product_quotation_score" "1.0.0" @(
    0.0,       # product_category  chiller
    5.0,       # product_type
    3.5,       # product_complexity
250000.0,      # base_price
   18.0,       # tax_rate
    1.0,       # price_tier  high
   20.0,       # capacity_tons
    1.0,       # capacity_bin  11-20t
   26.0,       # product_x_capacity  (5*5+1)
295000.0,      # total_price_with_tax
    0.0000678, # capacity_price_ratio
    1.0,       # quotation_sent
    0.0,       # is_enterprise_deal
    0.65,      # industry_close_rate
   10.0,       # stage_raw
    1.0,       # is_repeat_customer
   15.0        # days_in_pipeline
) "S2  chiller 20t 250k, quot sent, stage=10, repeat" 0.60 1.0

Write-ScenarioHeader "S3 Cold Lead    cooler(1)  3t  25k  quot=0  stage=1  45d  new_cust"
Invoke-ML "product_quotation_score" "1.0.0" @(
    1.0,      # product_category  cooler
    3.0,      # product_type
    1.5,      # product_complexity
25000.0,      # base_price
   18.0,      # tax_rate
    2.0,      # price_tier  low
    3.0,      # capacity_tons
    0.0,      # capacity_bin  1-5t
   15.0,      # product_x_capacity  (3*5+0)
29500.0,      # total_price_with_tax
    0.000102, # capacity_price_ratio
    0.0,      # quotation_sent
    0.0,      # is_enterprise_deal
    0.38,     # industry_close_rate  lowest
    1.0,      # stage_raw
    0.0,      # is_repeat_customer
   45.0       # days_in_pipeline
) "S3  cooler 3t 25k, NO quot, stage=1, 45d" 0.0 0.20

Write-ScenarioHeader "S4 Enterprise   hybrid(2)  50t  600k  enterprise=1  quot=1  stage=9  60d  repeat"
Invoke-ML "product_quotation_score" "1.0.0" @(
     2.0,       # product_category  hybrid
    15.0,       # product_type
     4.5,       # product_complexity
600000.0,       # base_price
    18.0,       # tax_rate
     0.0,       # price_tier  enterprise
    50.0,       # capacity_tons
     2.0,       # capacity_bin  21-50t
    77.0,       # product_x_capacity  (15*5+2)
708000.0,       # total_price_with_tax
     0.0000706, # capacity_price_ratio
     1.0,       # quotation_sent
     1.0,       # is_enterprise_deal
     0.55,      # industry_close_rate
     9.0,       # stage_raw
     1.0,       # is_repeat_customer
    60.0        # days_in_pipeline
) "S4  hybrid 50t 600k, enterprise=1, quot, 60d, repeat" 0.45 0.85

Write-ScenarioHeader "S5 At-Risk      chiller(0)  15t  150k  quot=1  stage=7  40d  new_cust"
Invoke-ML "product_quotation_score" "1.0.0" @(
     0.0,       # product_category  chiller
     4.0,       # product_type
     2.5,       # product_complexity
150000.0,       # base_price
    18.0,       # tax_rate
     1.0,       # price_tier  high
    15.0,       # capacity_tons
     1.0,       # capacity_bin  11-20t
    21.0,       # product_x_capacity  (4*5+1)
177000.0,       # total_price_with_tax
     0.0000847, # capacity_price_ratio
     1.0,       # quotation_sent
     0.0,       # is_enterprise_deal
     0.45,      # industry_close_rate
     7.0,       # stage_raw
     0.0,       # is_repeat_customer
    40.0        # days_in_pipeline
) "S5  chiller 15t 150k, quot sent but stalled 40d" 0.05 0.30

Write-ScenarioHeader "S6 Near-Close   chiller(0)  25t  320k  quot=1  stage=11  25d  repeat"
Invoke-ML "product_quotation_score" "1.0.0" @(
     0.0,       # product_category  chiller
     7.0,       # product_type
     3.5,       # product_complexity
320000.0,       # base_price
    18.0,       # tax_rate
     1.0,       # price_tier  high
    25.0,       # capacity_tons
     2.0,       # capacity_bin  21-50t
    37.0,       # product_x_capacity  (7*5+2)
377600.0,       # total_price_with_tax
     0.0000662, # capacity_price_ratio
     1.0,       # quotation_sent
     0.0,       # is_enterprise_deal
     0.67,      # industry_close_rate  highest
    11.0,       # stage_raw
     1.0,       # is_repeat_customer
    25.0        # days_in_pipeline
) "S6  chiller 25t 320k, stage=11, quot, repeat" 0.70 1.0

Write-ScenarioHeader "S7 Zombie Lead  cooler(1)  5t  45k  quot=0  stage=2  90d  new_cust"
Invoke-ML "product_quotation_score" "1.0.0" @(
    1.0,       # product_category  cooler
    4.0,       # product_type
    2.0,       # product_complexity
45000.0,       # base_price
   18.0,       # tax_rate
    2.0,       # price_tier  low
    5.0,       # capacity_tons
    0.0,       # capacity_bin  1-5t
   20.0,       # product_x_capacity  (4*5+0)
53100.0,       # total_price_with_tax
    0.0000942, # capacity_price_ratio
    0.0,       # quotation_sent
    0.0,       # is_enterprise_deal
    0.45,      # industry_close_rate
    2.0,       # stage_raw
    0.0,       # is_repeat_customer
   90.0        # days_in_pipeline
) "S7  cooler 5t 45k, NO quot, stage=2, 90d" 0.0 0.15


# =============================================================================
# ██████████████████████████████████████████████████████████████████████████
#  MODEL 5 / 5 — lead_qualification   (Aggregate signal, IQR-binned inputs)
#  20 features: has_action_milestone, stage_velocity(IQR1-3),
#  historical_deals_won(IQR), is_repeat_customer, industry_close_rate(IQR),
#  historical_avg_sentiment(IQR), intent(bin1-3), total_interactions(IQR),
#  is_multi_channel, recency_bucket(1-4), engagement_depth(IQR),
#  quotation_sent, is_enterprise_deal, pipeline_stage,
#  days_in_pipeline(IQR), pipeline_velocity(IQR), total_price_with_tax(IQR),
#  consumer_score_tier(1-3), interaction_score_tier(1-3),
#  product_quotation_score_tier(1-3)
#
#  NOTE: All continuous features are IQR-binned: 1=low  2=mid  3=high
# ██████████████████████████████████████████████████████████████████████████
# =============================================================================
Write-ModelBanner "MODEL 5/5 — lead_qualification  (Lead-Qualification)  |  20 features (IQR-binned)"

Write-ScenarioHeader "S1 Fast-Track   milestone=1  vel=HIGH(3)  days=LOW(1)  fresh(4)  quot=1  tiers=2"
Invoke-ML "lead_qualification" "1.0.0" @(
    1.0,  # has_action_milestone
    3.0,  # stage_velocity       IQR3=HIGH (9 stages / 2 days)
    1.0,  # historical_deals_won IQR1=none (new customer)
    0.0,  # is_repeat_customer
    2.0,  # industry_close_rate  IQR2=mid
    2.0,  # hist_avg_sentiment   IQR2=neutral
    2.0,  # intent               bin2=buying
    1.0,  # total_interactions   IQR1=low  (only 2 convs)
    1.0,  # is_multi_channel
    4.0,  # recency_bucket       4=fresh ≤3d
    2.0,  # engagement_depth     IQR2
    1.0,  # quotation_sent
    0.0,  # is_enterprise_deal
    9.0,  # pipeline_stage
    1.0,  # days_in_pipeline     IQR1=very short (2d)
    3.0,  # pipeline_velocity    IQR3=high
    2.0,  # total_price_with_tax IQR2=mid
    2.0,  # consumer_score_tier
    2.0,  # interaction_score_tier
    2.0   # product_quotation_score_tier
) "S1  vel=3, days=1(fast), fresh, quot, tiers=2" 0.25 0.70

Write-ScenarioHeader "S2 Ideal Hot    repeat=1  hist=3(high)  all IQR=3  active(3)  tiers=3"
Invoke-ML "lead_qualification" "1.0.0" @(
    1.0,  # has_action_milestone
    2.0,  # stage_velocity       IQR2=mid
    3.0,  # historical_deals_won IQR3=high (5 deals)
    1.0,  # is_repeat_customer
    3.0,  # industry_close_rate  IQR3=high
    3.0,  # hist_avg_sentiment   IQR3=high (0.75)
    2.0,  # intent               bin2=buying
    2.0,  # total_interactions   IQR2=mid  (6 convs)
    1.0,  # is_multi_channel
    3.0,  # recency_bucket       3=active ≤7d
    3.0,  # engagement_depth     IQR3=high
    1.0,  # quotation_sent
    0.0,  # is_enterprise_deal
   10.0,  # pipeline_stage
    2.0,  # days_in_pipeline     IQR2=mid (15d)
    2.0,  # pipeline_velocity    IQR2=mid
    2.0,  # total_price_with_tax IQR2=mid
    3.0,  # consumer_score_tier
    3.0,  # interaction_score_tier
    3.0   # product_quotation_score_tier
) "S2  repeat, all IQR high, active, tiers=3" 0.65 1.0

Write-ScenarioHeader "S3 Cold Lead    milestone=0  vel=1  days=3(long)  cold(1)  no_quot  tiers=1"
Invoke-ML "lead_qualification" "1.0.0" @(
    0.0,  # has_action_milestone
    1.0,  # stage_velocity       IQR1=low
    1.0,  # historical_deals_won IQR1=none
    0.0,  # is_repeat_customer
    1.0,  # industry_close_rate  IQR1=low
    1.0,  # hist_avg_sentiment   IQR1=negative
    1.0,  # intent               bin1=window_shopping/at_risk
    1.0,  # total_interactions   IQR1=low (1 conv)
    0.0,  # is_multi_channel
    1.0,  # recency_bucket       1=COLD >21d
    1.0,  # engagement_depth     IQR1=low/negative
    0.0,  # quotation_sent
    0.0,  # is_enterprise_deal
    1.0,  # pipeline_stage
    3.0,  # days_in_pipeline     IQR3=long (45d)
    1.0,  # pipeline_velocity    IQR1=slow
    1.0,  # total_price_with_tax IQR1=low
    1.0,  # consumer_score_tier
    1.0,  # interaction_score_tier
    1.0   # product_quotation_score_tier
) "S3  all IQR low, cold, no quot, tiers=1" 0.0 0.20

Write-ScenarioHeader "S4 Enterprise   enterprise=1  repeat=1  interactions=3(high)  price=3(high)  active"
Invoke-ML "lead_qualification" "1.0.0" @(
    1.0,  # has_action_milestone
    1.0,  # stage_velocity       IQR1=slow (9/60)
    2.0,  # historical_deals_won IQR2=mid (2 deals)
    1.0,  # is_repeat_customer
    2.0,  # industry_close_rate  IQR2=mid
    2.0,  # hist_avg_sentiment   IQR2=mid
    2.0,  # intent               bin2=negotiating
    3.0,  # total_interactions   IQR3=high (9 convs)
    1.0,  # is_multi_channel
    3.0,  # recency_bucket       3=active ≤7d
    3.0,  # engagement_depth     IQR3=high
    1.0,  # quotation_sent
    1.0,  # is_enterprise_deal
    9.0,  # pipeline_stage
    3.0,  # days_in_pipeline     IQR3=long (60d)
    1.0,  # pipeline_velocity    IQR1=slow
    3.0,  # total_price_with_tax IQR3=high (708k)
    2.0,  # consumer_score_tier
    3.0,  # interaction_score_tier
    3.0   # product_quotation_score_tier
) "S4  enterprise, repeat, interactions=3, price=3" 0.45 0.85

Write-ScenarioHeader "S5 At-Risk      cold(1)  intent=1(at_risk)  vel=1  days=3(long)  tiers=1"
Invoke-ML "lead_qualification" "1.0.0" @(
    1.0,  # has_action_milestone
    1.0,  # stage_velocity       IQR1=slow
    1.0,  # historical_deals_won IQR1=none
    0.0,  # is_repeat_customer
    1.0,  # industry_close_rate  IQR1=low
    2.0,  # hist_avg_sentiment   IQR2=ok history
    1.0,  # intent               bin1=at_risk
    2.0,  # total_interactions   IQR2=mid (5 convs)
    1.0,  # is_multi_channel
    1.0,  # recency_bucket       1=COLD >21d
    1.0,  # engagement_depth     IQR1=low
    1.0,  # quotation_sent
    0.0,  # is_enterprise_deal
    7.0,  # pipeline_stage
    3.0,  # days_in_pipeline     IQR3=long (40d)
    1.0,  # pipeline_velocity    IQR1=slow
    2.0,  # total_price_with_tax IQR2=mid
    1.0,  # consumer_score_tier
    1.0,  # interaction_score_tier
    1.0   # product_quotation_score_tier
) "S5  cold, at_risk, vel=1, long 40d, tiers=1" 0.05 0.30

Write-ScenarioHeader "S6 Near-Close   milestone=1  all IQR=3  active(3)  stage=11  tiers=3"
Invoke-ML "lead_qualification" "1.0.0" @(
    1.0,  # has_action_milestone
    2.0,  # stage_velocity       IQR2=mid
    3.0,  # historical_deals_won IQR3=high (8 deals)
    1.0,  # is_repeat_customer
    3.0,  # industry_close_rate  IQR3=high (0.67)
    3.0,  # hist_avg_sentiment   IQR3=high (0.85)
    2.0,  # intent               bin2=buying
    3.0,  # total_interactions   IQR3=high (10 convs)
    1.0,  # is_multi_channel
    3.0,  # recency_bucket       3=active ≤7d
    3.0,  # engagement_depth     IQR3=high
    1.0,  # quotation_sent
    0.0,  # is_enterprise_deal
   11.0,  # pipeline_stage
    2.0,  # days_in_pipeline     IQR2=mid (25d)
    2.0,  # pipeline_velocity    IQR2=mid
    3.0,  # total_price_with_tax IQR3=high (320k)
    3.0,  # consumer_score_tier
    3.0,  # interaction_score_tier
    3.0   # product_quotation_score_tier
) "S6  all high, stage=11, repeat(8), tiers=3" 0.70 1.0

Write-ScenarioHeader "S7 Zombie Lead  milestone=0  vel=1  days=3(90d)  cold(1)  no_quot  tiers=1"
Invoke-ML "lead_qualification" "1.0.0" @(
    0.0,  # has_action_milestone
    1.0,  # stage_velocity       IQR1=dead slow (2/90)
    1.0,  # historical_deals_won IQR1=none
    0.0,  # is_repeat_customer
    1.0,  # industry_close_rate  IQR1=low
    1.0,  # hist_avg_sentiment   IQR1=low
    2.0,  # intent               bin2=curious (mild positive)
    1.0,  # total_interactions   IQR1=low (1 conv)
    0.0,  # is_multi_channel
    1.0,  # recency_bucket       1=COLD >21d
    1.0,  # engagement_depth     IQR1=zero
    0.0,  # quotation_sent
    0.0,  # is_enterprise_deal
    2.0,  # pipeline_stage
    3.0,  # days_in_pipeline     IQR3=very long (90d)
    1.0,  # pipeline_velocity    IQR1=dead slow
    1.0,  # total_price_with_tax IQR1=low
    1.0,  # consumer_score_tier
    1.0,  # interaction_score_tier
    1.0   # product_quotation_score_tier
) "S7  all low, cold, no quot, 90d, tiers=1" 0.0 0.15


# ── Final summary ─────────────────────────────────────────────────────────────
$total = $PASS + $WARN + $FAIL
Write-Host "`n$('='*72)" -ForegroundColor Cyan
Write-Host "  TEST SUMMARY  (5 models × 7 scenarios = 35 checks)" -ForegroundColor Cyan
Write-Host "$('='*72)" -ForegroundColor Cyan
Write-Host ("  Total   : {0}" -f $total)
Write-Host ("  PASS    (score within expected range)    : {0}" -f $PASS)  -ForegroundColor Green
Write-Host ("  WARN    (within ±20% of range midpoint)  : {0}" -f $WARN)  -ForegroundColor DarkYellow
Write-Host ("  FAIL    (outside range by >20%)          : {0}" -f $FAIL)  -ForegroundColor Red
Write-Host ""

if ($FAIL -gt 0) {
    Write-Host "  Action required — some scores are far outside expected ranges." -ForegroundColor Red
    Write-Host "  Most likely causes:" -ForegroundColor Red
    Write-Host "    1. Model not loaded in SurrealDB → re-run replicate_ml_setup.bat" -ForegroundColor DarkRed
    Write-Host "    2. Wrong feature order → check convert_all_to_surml.py feature_cols" -ForegroundColor DarkRed
    Write-Host "    3. Model under-trained on that scenario pattern (e.g. fast-close)" -ForegroundColor DarkRed
} elseif ($WARN -gt 0) {
    Write-Host "  Minor drift — models are working but scores are slightly off." -ForegroundColor DarkYellow
    Write-Host "  Consider re-training if the pattern repeats on live data." -ForegroundColor DarkYellow
} else {
    Write-Host "  All 35 checks passed. All 5 models are healthy." -ForegroundColor Green
}
Write-Host ""
Write-Host "  Score ranking you should see across scenarios:" -ForegroundColor Gray
Write-Host "  S6 Near-Close > S2 Ideal Hot > S4 Enterprise > S1 Fast-Track > S5 At-Risk > S3 Cold > S7 Zombie" -ForegroundColor Gray
Write-Host ""
