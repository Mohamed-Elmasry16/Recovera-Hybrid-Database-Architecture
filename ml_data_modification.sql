
---- make the rules mathch the enum
WITH parsed_scenarios AS (
    SELECT 
        order_id,
        array_remove(ARRAY[
            CASE WHEN leakage_reason LIKE '%cod_unpaid%' 
                THEN 'cod_unpaid_after_delivery'::leakage_scenario_t END,

            CASE WHEN leakage_reason LIKE '%inventory_mismatch%' 
                THEN 'inventory_mismatch'::leakage_scenario_t END,

            CASE WHEN leakage_reason LIKE '%high_discount%' 
                THEN 'high_discount_negative_profit'::leakage_scenario_t END,

            CASE 
				    WHEN leakage_reason LIKE '%negative_profit%' 
				      OR leakage_reason LIKE '%negative_margin%'
				    THEN 'negative_profit_margin'::leakage_scenario_t
				END,
				CASE 
				    WHEN leakage_reason LIKE '%logistics>revenue%'
				    THEN 'logistics_exceeds_revenue'::leakage_scenario_t
				END,

            CASE WHEN leakage_reason LIKE '%never_shipped%' 
                THEN 'payment_approved_never_shipped'::leakage_scenario_t END,

            CASE WHEN leakage_reason LIKE '%no_invoice%' 
                THEN 'no_invoice_on_completion'::leakage_scenario_t END,

            CASE WHEN leakage_reason LIKE '%partial_payment%' 
                THEN 'partial_payment_only'::leakage_scenario_t END,

            CASE WHEN leakage_reason LIKE '%seller_paid_twice%' 
                THEN 'seller_paid_twice'::leakage_scenario_t END,

            CASE WHEN leakage_reason LIKE '%wrong_shipping_fee%' 
                THEN 'wrong_shipping_fee'::leakage_scenario_t END,

            CASE WHEN leakage_reason LIKE '%statistical_outlier%' 
                THEN 'statistical_outlier'::leakage_scenario_t END,

            CASE 
                WHEN leakage_reason LIKE '%contradicting_review%' 
                    THEN 'review_contradicts_cancelled'::leakage_scenario_t

                WHEN leakage_reason LIKE '%shipping_failed%' 
                    THEN 'shipping_failed_review_exists'::leakage_scenario_t
            END,

            CASE 
                WHEN leakage_reason = 'no_leakage' 
                    THEN 'no_leakage'::leakage_scenario_t
            END

        ], NULL) AS scenarios

    FROM ml_output.order_anomaly_scores
)

UPDATE ml_output.order_anomaly_scores oas
SET leakage_scenarios = ps.scenarios
FROM parsed_scenarios ps
WHERE oas.order_id = ps.order_id;


------check the rules 
SELECT leakage_scenarios, leakage_reason, COUNT(*)
FROM ml_output.order_anomaly_scores
GROUP BY leakage_scenarios, leakage_reason
ORDER BY COUNT(*) DESC;

-- see full table
SELECT order_id, if_score, lof_score, ensemble_score, anomaly_flag, risk_tier, anomaly_rank, leakage_scenarios, leakage_reason, scored_at, customer_id, order_status, order_purchase_timestamp, total_revenue, profit_margin, avg_discount_pct, shipping_delay_days, payment_status, shipping_status, month
	FROM ml_output.order_anomaly_scores;


-- add 'no_leakage' in 0 flag
UPDATE ml_output.order_anomaly_scores
SET leakage_reason =
    CASE
        WHEN anomaly_flag = 0 THEN 'no_leakage'
        ELSE LOWER(REPLACE(leakage_reason, ' ', '_'))
    END;

--- see and add values to the enum 
SELECT unnest(enum_range(NULL::leakage_scenario_t)) AS leakage_scenarios;

ALTER TYPE leakage_scenario_t
ADD VALUE IF NOT EXISTS 'statistical_outlier';
ALTER TYPE leakage_scenario_t ADD VALUE IF NOT EXISTS 'negative_profit_margin';


--- add values to leakae reasons 
INSERT INTO ml_output.order_leakage_reasons (order_id, leakage_type, confidence)
SELECT 
    sub.order_id,
    sub.unnested_scenario,
    oas.ensemble_score  
FROM (
    SELECT 
        order_id, 
        unnest(leakage_scenarios) AS unnested_scenario
    FROM ml_output.order_anomaly_scores
    WHERE leakage_scenarios IS NOT NULL 
      AND array_length(leakage_scenarios, 1) > 0
      AND 'no_leakage' <> ALL(leakage_scenarios) 
) sub
JOIN ml_output.order_anomaly_scores oas 
  ON sub.order_id = oas.order_id
ON CONFLICT (order_id, leakage_type) DO NOTHING;





DELETE FROM ml_output.order_leakage_reasons
WHERE ctid NOT IN (
    SELECT MIN(ctid)
    FROM ml_output.order_leakage_reasons
    GROUP BY order_id, leakage_type
);
SELECT order_id, leakage_type, COUNT(*)
FROM ml_output.order_leakage_reasons
GROUP BY order_id, leakage_type
HAVING COUNT(*) > 1
LIMIT 5;


REFRESH MATERIALIZED VIEW ml_output.mv_leakage_dashboard;
REFRESH MATERIALIZED VIEW ml_output.mv_monthly_leakage;
REFRESH MATERIALIZED VIEW ml_output.mv_seller_risk;
REFRESH MATERIALIZED VIEW ml_output.mv_leakage_by_scenario;


SELECT * FROM ml_output.mv_leakage_dashboard LIMIT 5;
SELECT * FROM ml_output.mv_leakage_by_scenario LIMIT 5;

SELECT * FROM ml_output.mv_leakage_dashboard
WHERE anomaly_flag = 1
LIMIT 5;



