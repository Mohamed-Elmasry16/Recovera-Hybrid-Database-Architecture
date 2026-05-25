-- ================================================================
-- 0. INFRASTRUCTURE — NEW TABLES & EXTENSIONS
-- ================================================================

-- 0.1 pgvector + trigram extensions
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
-- If using ParadeDB: CREATE EXTENSION IF NOT EXISTS pg_bm25;

-- 0.2 Drop & recreate rag schema with versioning
DROP SCHEMA IF EXISTS rag CASCADE;
CREATE SCHEMA rag;

-- 0.3 Source-type ENUM
CREATE TYPE rag.rag_source_t AS ENUM (
    'schema_doc',
    'business_rule',
    'leakage_scenario',
    'sql_template',
    'review',
    'leakage_reason',
    'kpi_glossary',
    'join_graph',
    'anti_pattern',
    'routing_hint',
    'enum_reference',
    'generated_column',
    'metric_definition',
    'lineage_doc',
    'anomaly_interpretation',
    'summary_profile',
    'temporal_context'
);

-- 0.4 Embedding-type ENUM
CREATE TYPE rag.embedding_type_t AS ENUM (
    'schema',
    'business_rule',
    'sql_template',
    'review',
    'metric',
    'routing',
    'glossary',
    'lineage'
);

-- 0.5 Query-intent ENUM
CREATE TYPE rag.query_intent_t AS ENUM (
    'simple_lookup',
    'aggregation',
    'anomaly_investigation',
    'trend_analysis',
    'sentiment_analysis',
    'schema_discovery',
    'kpi_definition',
    'sql_generation'
);

-- ----------------------------------------------------------------
-- FIX-1: Composite return type for all search functions
--         Replaces the invalid "RETURNS TABLE LIKE rag.hybrid_search"
--         pattern used in the original search_analytics and
--         search_reviews convenience wrappers.
-- ----------------------------------------------------------------
CREATE TYPE rag.search_result_t AS (
    doc_id           BIGINT,
    source_type      rag.rag_source_t,
    title            TEXT,
    content          TEXT,
    metadata         JSONB,
    bm25_score       REAL,
    vector_score     REAL,
    hybrid_score     REAL,
    priority         SMALLINT,
    retrieval_weight NUMERIC
);

-- 0.6 Main documents table
CREATE TABLE rag.documents (
    doc_id              BIGSERIAL PRIMARY KEY,
    source_type         rag.rag_source_t        NOT NULL,
    source_id           TEXT                    NOT NULL,
    title               TEXT                    NOT NULL,
    content             TEXT                    NOT NULL,
    content_lang        TEXT        DEFAULT 'ar' NOT NULL,
    metadata            JSONB       DEFAULT '{}'::JSONB,
    embedding_type      rag.embedding_type_t,
    priority            SMALLINT    DEFAULT 5 CHECK (priority BETWEEN 1 AND 10),
    retrieval_weight    NUMERIC(4,2) DEFAULT 1.0,
    version             INTEGER     DEFAULT 1,
    is_active           BOOLEAN     DEFAULT TRUE,
    needs_reembedding   BOOLEAN     DEFAULT TRUE,
    created_at          TIMESTAMPTZ DEFAULT NOW(),
    updated_at          TIMESTAMPTZ DEFAULT NOW()
);

--------------------------------
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_ts_config WHERE cfgname = 'arabic'
    ) THEN
        CREATE TEXT SEARCH CONFIGURATION arabic ( COPY = simple );
        RAISE NOTICE 'Created fallback Arabic text-search config (copy of simple). '
                     'Install a proper Arabic stemmer and recreate if needed.';
    END IF;
END;
$$;

-- 0.8 BM25 keyword-search column (now safe — config exists above)
ALTER TABLE rag.documents ADD COLUMN content_tsv TSVECTOR
    GENERATED ALWAYS AS (
        to_tsvector('arabic',  content) ||
        to_tsvector('english', content)
    ) STORED;

CREATE INDEX idx_docs_tsv         ON rag.documents USING GIN(content_tsv);
CREATE INDEX idx_docs_source_type ON rag.documents(source_type);
CREATE INDEX idx_docs_priority    ON rag.documents(priority DESC);
CREATE INDEX idx_docs_active      ON rag.documents(is_active) WHERE is_active = TRUE;
CREATE INDEX idx_docs_metadata    ON rag.documents USING GIN(metadata);

-- 0.7 Embedding collection tables
CREATE TABLE rag.schema_embeddings (
    doc_id      BIGINT REFERENCES rag.documents(doc_id) ON DELETE CASCADE,
    embedding   VECTOR(1536),
    created_at  TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (doc_id)
);

CREATE TABLE rag.business_embeddings (
    doc_id      BIGINT REFERENCES rag.documents(doc_id) ON DELETE CASCADE,
    embedding   VECTOR(1536),
    created_at  TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (doc_id)
);

CREATE TABLE rag.metrics_embeddings (
    doc_id      BIGINT REFERENCES rag.documents(doc_id) ON DELETE CASCADE,
    embedding   VECTOR(1536),
    created_at  TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (doc_id)
);

CREATE TABLE rag.review_embeddings (
    doc_id      BIGINT REFERENCES rag.documents(doc_id) ON DELETE CASCADE,
    embedding   VECTOR(1536),
    created_at  TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (doc_id)
);

-- 0.9 Retrieval analytics table
CREATE TABLE rag.retrieval_log (
    log_id              BIGSERIAL PRIMARY KEY,
    query_text          TEXT,
    query_intent        rag.query_intent_t,
    retrieved_doc_ids   BIGINT[],
    generated_sql       TEXT,
    sql_valid           BOOLEAN,
    sql_executed        BOOLEAN,
    execution_error     TEXT,
    hallucination_flag  BOOLEAN DEFAULT FALSE,
    confidence_score    NUMERIC(4,3),
    latency_ms          INTEGER,
    created_at          TIMESTAMPTZ DEFAULT NOW()
);

-- 0.10 SQL validation blocklist
CREATE TABLE rag.sql_guard (
    guard_id    SERIAL PRIMARY KEY,
    guard_type  TEXT NOT NULL,
    pattern     TEXT NOT NULL,
    message     TEXT NOT NULL
);

-- 0.11 Versioning audit trail
CREATE TABLE rag.document_versions (
    version_id  BIGSERIAL PRIMARY KEY,
    doc_id      BIGINT REFERENCES rag.documents(doc_id),
    version     INTEGER,
    content     TEXT,
    metadata    JSONB,
    changed_at  TIMESTAMPTZ DEFAULT NOW(),
    changed_by  TEXT DEFAULT SESSION_USER
);

----------------------------------------------------------------
CREATE OR REPLACE FUNCTION rag.on_doc_update()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    -- Archive previous version
    INSERT INTO rag.document_versions(doc_id, version, content, metadata)
    VALUES (OLD.doc_id, OLD.version, OLD.content, OLD.metadata);

    -- Bump version counter and timestamp
    NEW.version        := OLD.version + 1;
    NEW.updated_at     := NOW();

    -- Flag for re-embedding pipeline
    NEW.needs_reembedding := TRUE;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_doc_update
BEFORE UPDATE ON rag.documents
FOR EACH ROW WHEN (OLD.content IS DISTINCT FROM NEW.content)
EXECUTE FUNCTION rag.on_doc_update();

-- 0.12 Retrieval cache
CREATE TABLE rag.retrieval_cache (
    cache_key   TEXT PRIMARY KEY,
    query_hash  TEXT,
    result_json JSONB,
    hit_count   INTEGER DEFAULT 1,
    expires_at  TIMESTAMPTZ DEFAULT NOW() + INTERVAL '24 hours',
    created_at  TIMESTAMPTZ DEFAULT NOW()
);

-- ----------------------------------------------------------------
-- Cache invalidation: when a document changes, expire any cache
-- entries that included it in their result set.
-- ----------------------------------------------------------------

CREATE OR REPLACE FUNCTION rag.invalidate_cache_on_doc_change()
RETURNS TRIGGER LANGUAGE plpgsql AS $$ BEGIN
    DELETE FROM rag.retrieval_cache
    WHERE result_json @> jsonb_build_array(jsonb_build_object('doc_id', NEW.doc_id))
       OR expires_at < NOW();
    RETURN NEW;
END;
 $$;

CREATE TRIGGER trg_cache_invalidate
AFTER UPDATE ON rag.documents
FOR EACH ROW WHEN (OLD.content IS DISTINCT FROM NEW.content)
EXECUTE FUNCTION rag.invalidate_cache_on_doc_change();


-- ================================================================
-- 1. SCHEMA DOCS
-- ================================================================

INSERT INTO rag.documents
    (source_type, source_id, title, content, content_lang,
     embedding_type, priority, retrieval_weight, metadata)
VALUES

('schema_doc','ecommerce.orders','Table: ecommerce.orders',
$$الجدول الرئيسي للأوردرات. ~298K row. كل الأموال بالجنيه المصري (EGP).

الأعمدة المهمة:
- order_id (PK): معرف الأوردر الفريد
- customer_id: FK → ecommerce.customers
- order_status: ENUM (delivered, canceled, shipped, processing, invoiced, unavailable)
- order_purchase_timestamp: تاريخ ووقت الشراء
- total_revenue: إجمالي الإيراد بالجنيه
- total_profit: صافي الربح بالجنيه
- profit_margin: نسبة الربح (سالب = خسارة = leakage)
- avg_discount_pct: نسبة الخصم 0.0–1.0 (فوق 0.50 = high_discount_negative_profit)
- payment_status: ENUM (approved, partial, unpaid, missing) — missing = delivered_no_payment leakage
- shipping_delay_days: تأخير الشحن بالأيام (فوق 14 = delayed_delivery_compensation)
- invoice_available: FALSE = no_invoice_on_completion leakage
- inventory_mismatch: TRUE = inventory_mismatch leakage
- order_month (GENERATED): أول يوم في شهر الشراء — استخدمه في GROUP BY الشهري
- order_quarter (GENERATED): أول يوم في الربع
- order_year (GENERATED): السنة

English aliases: orders table, order records, purchase table

العلاقات: JOIN customers ON customer_id | JOIN order_items ON order_id |
          JOIN payments ON order_id | JOIN shipping ON order_id$$,
'ar+en','schema', 9, 1.5,
'{
  "schema":"ecommerce","table":"orders","rows":298323,
  "embedding_type":"schema","priority":9,"retrieval_weight":1.5,
  "tables":["ecommerce.orders"],
  "join_paths":[
    "orders JOIN customers ON orders.customer_id = customers.customer_id",
    "orders JOIN order_items ON orders.order_id = order_items.order_id",
    "orders JOIN payments ON orders.order_id = payments.order_id",
    "orders JOIN shipping ON orders.order_id = shipping.order_id"
  ],
  "keywords":["order","revenue","profit","discount","payment_status","shipping_delay",
              "أوردر","إيراد","ربح","خصم","حالة الدفع"],
  "arabic_aliases":["الأوردرات","الطلبات","المشتريات"],
  "english_aliases":["orders","purchases","transactions"]
}'::JSONB),

('schema_doc','ecommerce.customers','Table: ecommerce.customers',
$$بروفايل العملاء. ~253K row.

الأعمدة المهمة:
- customer_id (PK): FK في orders
- customer_unique_id: يجمع الحسابات المكررة لنفس الشخص
- customer_city: مدينة العميل
- lifetime_value: إجمالي الإيراد التاريخي بالجنيه (فوق 1000 = high-value)
- segment: ENUM (Low Value, Mid Value, High Value)
- churn_risk: ENUM (High, Medium, Low)
- total_orders: عدد الأوردرات
- avg_order_value: متوسط قيمة الأوردر

English aliases: customers table, buyer profiles, client data$$,
'ar+en','schema', 8, 1.3,
'{
  "schema":"ecommerce","table":"customers","rows":253574,
  "embedding_type":"schema","priority":8,"retrieval_weight":1.3,
  "tables":["ecommerce.customers"],
  "join_paths":["customers JOIN orders ON customers.customer_id = orders.customer_id"],
  "keywords":["customer","segment","lifetime_value","churn","city",
              "عميل","شريحة","قيمة عمرية","خطر التوقف"],
  "arabic_aliases":["العملاء","المشترون","المستخدمون"],
  "english_aliases":["customers","buyers","users","clients"]
}'::JSONB),

('schema_doc','ecommerce.sellers','Table: ecommerce.sellers',
$$بروفايل البائعين. ~5K row.

الأعمدة المهمة:
- seller_id (PK): FK في order_items
- seller_name: اسم البائع
- seller_city: مدينة البائع
- seller_rating: تقييم 0–5
- return_rate: نسبة الإرجاع 0.0–1.0 (فوق 0.15 = high-risk seller)
- payment_disputes: عدد النزاعات المالية (قيم عالية = نشاط مشبوه)
- is_verified: هل البائع موثق
- is_name_channel_boolean: قناة المبيعات

English aliases: sellers table, vendor profiles, merchant data$$,
'ar+en','schema', 8, 1.3,
'{
  "schema":"ecommerce","table":"sellers","rows":5000,
  "embedding_type":"schema","priority":8,"retrieval_weight":1.3,
  "tables":["ecommerce.sellers"],
  "join_paths":["sellers JOIN order_items ON sellers.seller_id = order_items.seller_id"],
  "keywords":["seller","vendor","return_rate","disputes","rating","risk",
              "بائع","تقييم","نسبة إرجاع","نزاعات"],
  "arabic_aliases":["البائعون","التجار","الموردون"],
  "english_aliases":["sellers","vendors","merchants","suppliers"]
}'::JSONB),

('schema_doc','ecommerce.order_items','Table: ecommerce.order_items',
$$بنود الأوردر (line items). ~435K row. علاقة many-to-one مع orders.

الأعمدة المهمة:
- order_id: FK → orders
- order_item_id: ترتيب البند في الأوردر
- product_id: FK → products
- seller_id: FK → sellers
- price: السعر الأصلي
- item_discount_pct: نسبة الخصم على البند 0.0–1.0
- price_after_discount: السعر الفعلي بعد الخصم — استخدمه في SUM للإيراد
- freight_value: قيمة الشحن
- logistics_cost: تكلفة اللوجستيك الفعلية

⚠️ استخدم price_after_discount دائماً وليس price عند حساب الإيراد.

English aliases: order items, line items, cart items$$,
'ar+en','schema', 8, 1.3,
'{
  "schema":"ecommerce","table":"order_items","rows":435481,
  "embedding_type":"schema","priority":8,"retrieval_weight":1.3,
  "tables":["ecommerce.order_items"],
  "join_paths":[
    "order_items JOIN orders ON order_items.order_id = orders.order_id",
    "order_items JOIN products ON order_items.product_id = products.product_id",
    "order_items JOIN sellers ON order_items.seller_id = sellers.seller_id"
  ],
  "keywords":["item","product","discount","price_after_discount","freight","logistics",
              "بنود","سعر","خصم","شحن"],
  "preferred_revenue_column":"price_after_discount",
  "arabic_aliases":["بنود الأوردر","عناصر الطلب"],
  "english_aliases":["order_items","line items","cart items"]
}'::JSONB),

('schema_doc','ecommerce.payments','Table: ecommerce.payments',
$$سجلات الدفع. ~297K row. ممكن يكون فيه أكتر من row للأوردر الواحد (أقساط).

الأعمدة المهمة:
- order_id: FK → orders
- payment_sequential: ترتيب الدفعة (1 = الدفعة الأساسية)
- payment_type: ENUM (credit_card, debit_card, voucher, cash_on_delivery)
- payment_value: قيمة الدفعة بالجنيه
- payment_status: ENUM (approved, partial, unpaid, missing)
- seller_paid_twice: TRUE = leakage scenario seller_paid_twice

⚠️ فلتر payment_sequential = 1 للحصول على طريقة الدفع الأساسية فقط.

English aliases: payments table, payment records, transactions$$,
'ar+en','schema', 8, 1.3,
'{
  "schema":"ecommerce","table":"payments","rows":297538,
  "embedding_type":"schema","priority":8,"retrieval_weight":1.3,
  "tables":["ecommerce.payments"],
  "join_paths":["payments JOIN orders ON payments.order_id = orders.order_id"],
  "keywords":["payment","credit_card","cash_on_delivery","seller_paid_twice","partial",
              "دفع","فيزا","كاش عند الاستلام","جزئي"],
  "gotcha":"Always filter payment_sequential = 1 for primary payment method",
  "arabic_aliases":["المدفوعات","الدفعات","سجلات الدفع"],
  "english_aliases":["payments","transactions","payment records"]
}'::JSONB),

('schema_doc','ecommerce.shipping','Table: ecommerce.shipping',
$$سجلات الشحن. row واحدة لكل أوردر.

الأعمدة المهمة:
- order_id: FK → orders
- carrier: شركة الشحن — ENUM (Aramex EG, Egypt Post, Bosta, Mylerz, Voo, R2S Express)
- shipping_status: ENUM (delivered, in_transit, cancelled, failed, never_shipped, pending)
- shipping_fee_charged: رسوم الشحن المحصلة
- actual_logistics_cost: التكلفة الفعلية للشحن
- fee_calculation_error: TRUE = wrong_shipping_fee leakage
- fee_to_cost_ratio (GENERATED): نسبة الرسوم للتكلفة (شاذ إذا > 2 أو < 0.5)

English aliases: shipping table, delivery records, logistics data$$,
'ar+en','schema', 8, 1.3,
'{
  "schema":"ecommerce","table":"shipping","rows":298323,
  "embedding_type":"schema","priority":8,"retrieval_weight":1.3,
  "tables":["ecommerce.shipping"],
  "join_paths":["shipping JOIN orders ON shipping.order_id = orders.order_id"],
  "keywords":["shipping","carrier","delivery","fee_calculation_error","never_shipped",
              "شحن","توصيل","شركة الشحن","رسوم"],
  "carriers":["Aramex EG","Egypt Post","Bosta","Mylerz","Voo","R2S Express"],
  "arabic_aliases":["الشحن","التوصيل","اللوجستيك"],
  "english_aliases":["shipping","delivery","logistics","carrier"]
}'::JSONB),

('schema_doc','ecommerce.reviews','Table: ecommerce.reviews',
$$تقييمات العملاء. ~262K row.

الأعمدة المهمة:
- review_id (PK)
- order_id: FK → orders
- customer_id: FK → customers
- rating: numeric(3,1) — من 1 لـ 5
- review_comment: نص التعليق
- review_date: تاريخ التقييم
- sentiment: ENUM (positive, neutral, negative)
- has_comment: TRUE = فيه تعليق نصي
- is_emoji_only: TRUE = تعليق emoji فقط
- rating_group: تصنيف التقييم

⚠️ review مع order_status = cancelled → review_contradicts_cancelled leakage

English aliases: reviews table, customer feedback, ratings$$,
'ar+en','schema', 7, 1.0,
'{
  "schema":"ecommerce","table":"reviews","rows":262935,
  "embedding_type":"schema","priority":7,"retrieval_weight":1.0,
  "tables":["ecommerce.reviews"],
  "join_paths":["reviews JOIN orders ON reviews.order_id = orders.order_id"],
  "keywords":["review","rating","sentiment","comment","feedback",
              "تقييم","مراجعة","رأي","مشاعر"],
  "leakage_trigger":"review on canceled order = review_contradicts_cancelled",
  "arabic_aliases":["التقييمات","المراجعات","آراء العملاء"],
  "english_aliases":["reviews","ratings","feedback","comments"]
}'::JSONB),

('schema_doc','ecommerce.refunds','Table: ecommerce.refunds',
$$سجلات الاسترداد. ~7808 row.

الأعمدة المهمة:
- order_id: FK → orders
- refund_amount: مبلغ الاسترداد
- refund_status: حالة الاسترداد
- refund_reason: ENUM (incorrect_refund, return_request, early_refund,
    late_delivery_compensation, item_not_as_described, customer_request)
- refund_date: تاريخ الاسترداد
- duplicate_refund: TRUE = duplicate_refund leakage
- processed_before_cancel: TRUE = refund_before_cancellation leakage

English aliases: refunds table, returns, reimbursements$$,
'ar+en','schema', 8, 1.3,
'{
  "schema":"ecommerce","table":"refunds","rows":7808,
  "embedding_type":"schema","priority":8,"retrieval_weight":1.3,
  "tables":["ecommerce.refunds"],
  "join_paths":["refunds JOIN orders ON refunds.order_id = orders.order_id"],
  "keywords":["refund","duplicate_refund","return","processed_before_cancel","compensation",
              "استرداد","إرجاع","تعويض","مكرر"],
  "arabic_aliases":["المستردات","الإرجاع","رد المبلغ"],
  "english_aliases":["refunds","returns","reimbursements","chargebacks"]
}'::JSONB),

('schema_doc','ecommerce.products','Table: ecommerce.products',
$$كتالوج المنتجات. ~50K row.

الأعمدة المهمة:
- product_id (PK): FK في order_items
- product_category_name: فئة المنتج
- unit_price_egp: السعر المدرج بالجنيه
- product_weight_g: الوزن بالجرام

⚠️ السعر الفعلي في البيع هو order_items.price_after_discount، ليس unit_price_egp.

English aliases: products table, catalog, items$$,
'ar+en','schema', 7, 1.0,
'{
  "schema":"ecommerce","table":"products","rows":50000,
  "embedding_type":"schema","priority":7,"retrieval_weight":1.0,
  "tables":["ecommerce.products"],
  "join_paths":["products JOIN order_items ON products.product_id = order_items.product_id"],
  "keywords":["product","category","weight","price","catalog",
              "منتج","فئة","كتالوج","وزن"],
  "gotcha":"Use order_items.price_after_discount for actual sale price, not unit_price_egp",
  "arabic_aliases":["المنتجات","الكتالوج","السلع"],
  "english_aliases":["products","catalog","items","SKUs"]
}'::JSONB),

('schema_doc','ml_output.order_anomaly_scores','Table: ml_output.order_anomaly_scores',
$$درجات الشذوذ من الـ ML model. row واحدة لكل أوردر.

الأعمدة المهمة:
- order_id (PK): FK → orders
- if_score: درجة Isolation Forest
- lof_score: درجة Local Outlier Factor
- ensemble_score: الدرجة المجمعة
  Low < 0.40 | Medium 0.40–0.65 | High 0.65–0.80 | Critical > 0.80
- anomaly_flag: 1 = leakage مكتشف | 0 = طبيعي
- risk_tier: ENUM (Low, Medium, High, Critical)
- anomaly_rank: ترتيب الشذوذ النسبي
- leakage_scenarios: TEXT[] — فلتر بـ WHERE ''scenario'' = ANY(leakage_scenarios)
- leakage_reason: نص خام من الـ ML model

English aliases: anomaly scores, ML scores, fraud scores$$,
'ar+en','schema', 9, 1.5,
'{
  "schema":"ml_output","table":"order_anomaly_scores",
  "embedding_type":"schema","priority":9,"retrieval_weight":1.5,
  "tables":["ml_output.order_anomaly_scores"],
  "join_paths":["order_anomaly_scores JOIN orders ON order_anomaly_scores.order_id = orders.order_id"],
  "keywords":["anomaly","ensemble_score","risk_tier","leakage_scenarios","isolation_forest",
              "شذوذ","درجة الخطر","اكتشاف","تسرب"],
  "score_ranges":{"Low":"< 0.40","Medium":"0.40-0.65","High":"0.65-0.80","Critical":"> 0.80"},
  "arabic_aliases":["درجات الشذوذ","نتائج النموذج"],
  "english_aliases":["anomaly scores","ML scores","risk scores","fraud scores"]
}'::JSONB),

('schema_doc','ml_output.order_leakage_reasons','Table: ml_output.order_leakage_reasons',
$$جدول junction: row واحدة لكل (order, leakage_type). الأفضل للفلترة على السيناريوهات.

الأعمدة:
- order_id: FK → orders
- leakage_type: leakage_scenario_t ENUM — السيناريو المحدد
- confidence: درجة الثقة (= ensemble_score)

PK: (order_id, leakage_type)
مثال الاستخدام: WHERE leakage_type = ''duplicate_refund''

⚠️ استخدم هذا الجدول للفلتر على سيناريو محدد، أفضل من array ANY().

English aliases: leakage reasons, scenario assignments$$,
'ar+en','schema', 9, 1.5,
'{
  "schema":"ml_output","table":"order_leakage_reasons",
  "embedding_type":"schema","priority":9,"retrieval_weight":1.5,
  "tables":["ml_output.order_leakage_reasons"],
  "join_paths":[
    "order_leakage_reasons JOIN orders ON order_leakage_reasons.order_id = orders.order_id",
    "order_leakage_reasons JOIN order_anomaly_scores ON order_leakage_reasons.order_id = order_anomaly_scores.order_id"
  ],
  "keywords":["leakage_type","scenario","confidence","junction","filter",
              "سيناريو","تسرب","فلتر"],
  "preferred_for":"Filtering by specific leakage scenario",
  "arabic_aliases":["أسباب التسرب","تصنيف السيناريوهات"],
  "english_aliases":["leakage reasons","scenario assignments","leakage types"]
}'::JSONB),

('schema_doc','ml_output.materialized_views','Materialized Views: ml_output',
$$أربع Materialized Views جاهزة — لا تحتاج JOINs إضافية.

1. ml_output.mv_leakage_dashboard
   كل أوردر مع بياناته الكاملة (customer, payment, shipping, ML scores).
   الاستخدام:
     SELECT * FROM ml_output.mv_leakage_dashboard WHERE anomaly_flag = 1;
     SELECT * FROM ml_output.mv_leakage_dashboard WHERE ''duplicate_refund'' = ANY(leakage_scenarios);
   الأعمدة الرئيسية: order_id, order_status, payment_status, total_revenue,
     profit_margin, risk_tier, ensemble_score, leakage_scenarios, customer_segment

2. ml_output.mv_monthly_leakage
   تجميع شهري جاهز.
   الأعمدة: month, month_label, total_orders, leakage_orders,
     leakage_rate_pct, total_revenue, revenue_at_risk
   مثال: SELECT month_label, leakage_rate_pct FROM ml_output.mv_monthly_leakage
          ORDER BY leakage_rate_pct DESC LIMIT 1;

3. ml_output.mv_seller_risk
   ملف مخاطر البائعين.
   الأعمدة: seller_name, leakage_rate_pct, total_orders,
     avg_anomaly_score, payment_disputes
   مثال: SELECT * FROM ml_output.mv_seller_risk ORDER BY leakage_rate_pct DESC LIMIT 10;

4. ml_output.mv_leakage_by_scenario
   تجميع لكل سيناريو leakage.
   الأعمدة: scenario, total_orders, revenue_at_risk, avg_anomaly_score, avg_profit_margin
   مثال: SELECT * FROM ml_output.mv_leakage_by_scenario ORDER BY revenue_at_risk DESC;

تحديث الـ views: CALL ml_output.refresh_all_views();

English aliases: materialized views, pre-aggregated tables, cached analytics$$,
'ar+en','schema', 10, 2.0,
'{
  "schema":"ml_output","type":"materialized_views",
  "embedding_type":"schema","priority":10,"retrieval_weight":2.0,
  "tables":[
    "ml_output.mv_leakage_dashboard",
    "ml_output.mv_monthly_leakage",
    "ml_output.mv_seller_risk",
    "ml_output.mv_leakage_by_scenario"
  ],
  "keywords":["materialized_view","dashboard","monthly","seller_risk","scenario_summary",
              "جاهز","إحصاء","ملخص","شهري"],
  "routing_hint":"ALWAYS prefer materialized views over raw JOINs for analytics queries",
  "preferred_for":["aggregation","trend_analysis","anomaly_investigation","simple_lookup"],
  "arabic_aliases":["الـ views الجاهزة","الجداول المجمعة"],
  "english_aliases":["materialized views","pre-built analytics","cached tables"]
}'::JSONB);


-- ================================================================
-- 2. LEAKAGE SCENARIOS — ONE DOCUMENT PER SCENARIO
-- ================================================================

INSERT INTO rag.documents
    (source_type, source_id, title, content, content_lang,
     embedding_type, priority, retrieval_weight, metadata)
VALUES

('leakage_scenario','scenario.delivered_no_payment',
 'Leakage Scenario: delivered_no_payment — تسليم بدون دفع',
$$السيناريو: delivered_no_payment
الاسم بالعربي: تسليم بدون دفع
الاسم بالإنجليزي: Delivered Without Payment

الوصف: أوردر تم تسليمه للعميل لكن مفيش دفع مسجل.

قاعدة الاكتشاف:
  order_status = ''delivered'' AND payment_status = ''missing''

الاستعلام المقترح:
  SELECT order_id, total_revenue, customer_segment, customer_city
  FROM ml_output.mv_leakage_dashboard
  WHERE order_status = ''delivered'' AND payment_status = ''missing''
  ORDER BY total_revenue DESC;

الجداول المرتبطة: orders, payments, mv_leakage_dashboard
مستوى الخطورة: High–Critical$$,
'ar+en','business_rule', 9, 1.5,
'{
  "scenario":"delivered_no_payment",
  "embedding_type":"business_rule","priority":9,"retrieval_weight":1.5,
  "tables":["ecommerce.orders","ecommerce.payments","ml_output.mv_leakage_dashboard"],
  "detection_columns":["order_status","payment_status"],
  "detection_values":{"order_status":"delivered","payment_status":"missing"},
  "preferred_view":"ml_output.mv_leakage_dashboard",
  "keywords":["delivered","missing payment","no payment","تسليم","بدون دفع"],
  "arabic_aliases":["تسليم بدون دفع","أوردر مُسلَّم غير مدفوع"],
  "english_aliases":["delivered no payment","missing payment after delivery","unpaid delivered order"]
}'::JSONB),

('leakage_scenario','scenario.shipped_then_cancelled',
 'Leakage Scenario: shipped_then_cancelled — شُحن ثم أُلغي',
$$السيناريو: shipped_then_cancelled
الاسم بالعربي: شُحن ثم أُلغي
الاسم بالإنجليزي: Shipped Then Cancelled

الوصف: تم شحن الأوردر أو تسليمه لكن تم إلغاؤه بعد ذلك.

قاعدة الاكتشاف:
  shipping_status IN (''delivered'',''in_transit'') AND order_status = ''canceled''

الاستعلام المقترح:
  SELECT order_id, total_revenue, risk_tier
  FROM ml_output.mv_leakage_dashboard
  WHERE ''shipped_then_cancelled'' = ANY(leakage_scenarios)
  ORDER BY ensemble_score DESC;

الجداول المرتبطة: orders, shipping, mv_leakage_dashboard$$,
'ar+en','business_rule', 9, 1.5,
'{
  "scenario":"shipped_then_cancelled",
  "embedding_type":"business_rule","priority":9,"retrieval_weight":1.5,
  "tables":["ecommerce.orders","ecommerce.shipping","ml_output.mv_leakage_dashboard"],
  "detection_columns":["shipping_status","order_status"],
  "keywords":["shipped","cancelled","in_transit","شحن","إلغاء"],
  "arabic_aliases":["شحن ثم إلغاء","أوردر ملغي بعد الشحن"],
  "english_aliases":["shipped then cancelled","cancelled after shipment"]
}'::JSONB),

('leakage_scenario','scenario.incorrect_refund_on_delivery',
 'Leakage Scenario: incorrect_refund_on_delivery — استرداد خاطئ بعد التسليم',
$$السيناريو: incorrect_refund_on_delivery
الاسم بالعربي: استرداد خاطئ بعد التسليم
الاسم بالإنجليزي: Incorrect Refund on Delivered Order

الوصف: تم إجراء استرداد بعنوان incorrect_refund بينما الأوردر مُسلَّم فعلاً.

قاعدة الاكتشاف:
  refund_reason = ''incorrect_refund'' AND order_status = ''delivered''

الاستعلام:
  SELECT o.order_id, r.refund_amount, o.total_revenue
  FROM ecommerce.orders o
  JOIN ecommerce.refunds r ON o.order_id = r.order_id
  WHERE r.refund_reason = ''incorrect_refund'' AND o.order_status = ''delivered''
  ORDER BY r.refund_amount DESC;

الجداول المرتبطة: orders, refunds, mv_leakage_dashboard$$,
'ar+en','business_rule', 8, 1.3,
'{
  "scenario":"incorrect_refund_on_delivery",
  "embedding_type":"business_rule","priority":8,"retrieval_weight":1.3,
  "tables":["ecommerce.orders","ecommerce.refunds","ml_output.mv_leakage_dashboard"],
  "detection_columns":["refund_reason","order_status"],
  "keywords":["incorrect_refund","delivered","refund","استرداد خاطئ","تسليم"],
  "arabic_aliases":["استرداد خاطئ","رد مبلغ بالغلط"],
  "english_aliases":["incorrect refund","wrong refund on delivery"]
}'::JSONB),

('leakage_scenario','scenario.duplicate_refund',
 'Leakage Scenario: duplicate_refund — استرداد مكرر',
$$السيناريو: duplicate_refund
الاسم بالعربي: استرداد مكرر
الاسم بالإنجليزي: Duplicate Refund

الوصف: نفس المبلغ تم استرداده أكثر من مرة لنفس الأوردر.

قاعدة الاكتشاف:
  refunds.duplicate_refund = TRUE

الاستعلام:
  SELECT order_id, total_revenue, risk_tier, ensemble_score
  FROM ml_output.mv_leakage_dashboard
  WHERE ''duplicate_refund'' = ANY(leakage_scenarios)
  ORDER BY ensemble_score DESC LIMIT 20;

أو باستخدام junction table (أدق):
  SELECT olr.order_id, o.total_revenue
  FROM ml_output.order_leakage_reasons olr
  JOIN ecommerce.orders o ON olr.order_id = o.order_id
  WHERE olr.leakage_type = ''duplicate_refund''
  ORDER BY o.total_revenue DESC;

الجداول المرتبطة: refunds, order_leakage_reasons, mv_leakage_dashboard$$,
'ar+en','business_rule', 10, 2.0,
'{
  "scenario":"duplicate_refund",
  "embedding_type":"business_rule","priority":10,"retrieval_weight":2.0,
  "tables":["ecommerce.refunds","ml_output.order_leakage_reasons","ml_output.mv_leakage_dashboard"],
  "detection_columns":["duplicate_refund"],
  "detection_values":{"duplicate_refund":true},
  "preferred_view":"ml_output.mv_leakage_dashboard",
  "keywords":["duplicate","refund","مكرر","استرداد","double refund"],
  "arabic_aliases":["استرداد مكرر","رد مبلغ مرتين"],
  "english_aliases":["duplicate refund","double refund","repeated refund"]
}'::JSONB),

('leakage_scenario','scenario.payment_approved_never_shipped',
 'Leakage Scenario: payment_approved_never_shipped — دفع معتمد بدون شحن',
$$السيناريو: payment_approved_never_shipped
الاسم بالعربي: دفع معتمد ولم يُشحن
الاسم بالإنجليزي: Payment Approved but Never Shipped

الوصف: تم اعتماد الدفع لكن لم يتم شحن الأوردر أبداً.

قاعدة الاكتشاف:
  payment_status = ''approved'' AND shipping_status = ''never_shipped''

الاستعلام:
  SELECT o.order_id, o.total_revenue, s.carrier
  FROM ecommerce.orders o
  JOIN ecommerce.shipping s ON o.order_id = s.order_id
  WHERE o.payment_status = ''approved'' AND s.shipping_status = ''never_shipped''
  ORDER BY o.total_revenue DESC;

الجداول المرتبطة: orders, shipping, payments$$,
'ar+en','business_rule', 9, 1.5,
'{
  "scenario":"payment_approved_never_shipped",
  "embedding_type":"business_rule","priority":9,"retrieval_weight":1.5,
  "tables":["ecommerce.orders","ecommerce.shipping","ecommerce.payments"],
  "detection_columns":["payment_status","shipping_status"],
  "detection_values":{"payment_status":"approved","shipping_status":"never_shipped"},
  "keywords":["approved","never_shipped","payment","shipping","دفع","لم يشحن"],
  "arabic_aliases":["دفع بدون شحن","اعتماد دفع ثم عدم شحن"],
  "english_aliases":["paid never shipped","payment without delivery","ghost order"]
}'::JSONB),

('leakage_scenario','scenario.logistics_exceeds_revenue',
 'Leakage Scenario: logistics_exceeds_revenue — تكاليف لوجستيك أعلى من الإيراد',
$$السيناريو: logistics_exceeds_revenue
الاسم بالعربي: تكاليف اللوجستيك تتجاوز الإيراد
الاسم بالإنجليزي: Logistics Cost Exceeds Revenue

الوصف: إجمالي تكاليف الشحن واللوجستيك أكبر من الإيراد المحقق.

قاعدة الاكتشاف:
  profit_margin < 0 (بسبب تكاليف الشحن)

الاستعلام:
  SELECT order_id, profit_margin, total_revenue, avg_discount_pct
  FROM ml_output.mv_leakage_dashboard
  WHERE profit_margin < 0
  ORDER BY profit_margin ASC LIMIT 20;

الجداول المرتبطة: orders, shipping, order_items, mv_leakage_dashboard$$,
'ar+en','business_rule', 8, 1.3,
'{
  "scenario":"logistics_exceeds_revenue",
  "embedding_type":"business_rule","priority":8,"retrieval_weight":1.3,
  "tables":["ecommerce.orders","ecommerce.shipping","ecommerce.order_items"],
  "detection_columns":["profit_margin"],
  "keywords":["logistics","profit_margin","negative profit","تكاليف","ربح سالب","لوجستيك"],
  "arabic_aliases":["تكاليف لوجستيك عالية","خسارة في الشحن"],
  "english_aliases":["logistics exceeds revenue","negative margin shipping","unprofitable delivery"]
}'::JSONB),

('leakage_scenario','scenario.cod_unpaid_after_delivery',
 'Leakage Scenario: cod_unpaid_after_delivery — كاش عند الاستلام غير مدفوع',
$$السيناريو: cod_unpaid_after_delivery
الاسم بالعربي: كاش عند الاستلام غير مدفوع
الاسم بالإنجليزي: Cash on Delivery — Unpaid After Delivery

الوصف: طلب بطريقة الدفع كاش عند الاستلام، تم التسليم لكن لم يُسجَّل الدفع.

قاعدة الاكتشاف:
  payment_type = ''cash_on_delivery''
  AND order_status = ''delivered''
  AND payment_status IN (''unpaid'',''missing'')

الاستعلام:
  SELECT o.order_id, o.total_revenue, o.customer_id
  FROM ecommerce.orders o
  JOIN ecommerce.payments p ON o.order_id = p.order_id AND p.payment_sequential = 1
  WHERE p.payment_type = ''cash_on_delivery''
    AND o.order_status = ''delivered''
    AND o.payment_status IN (''unpaid'',''missing'')
  ORDER BY o.total_revenue DESC;

الجداول المرتبطة: orders, payments$$,
'ar+en','business_rule', 9, 1.5,
'{
  "scenario":"cod_unpaid_after_delivery",
  "embedding_type":"business_rule","priority":9,"retrieval_weight":1.5,
  "tables":["ecommerce.orders","ecommerce.payments"],
  "detection_columns":["payment_type","order_status","payment_status"],
  "detection_values":{"payment_type":"cash_on_delivery","order_status":"delivered"},
  "keywords":["cash_on_delivery","COD","unpaid","كاش عند الاستلام","غير مدفوع"],
  "arabic_aliases":["كاش عند الاستلام بدون دفع","COD غير محصَّل"],
  "english_aliases":["COD unpaid","cash on delivery not collected","cash not received"]
}'::JSONB),

('leakage_scenario','scenario.high_discount_negative_profit',
 'Leakage Scenario: high_discount_negative_profit — خصم عالي بربح سالب',
$$السيناريو: high_discount_negative_profit
الاسم بالعربي: خصم عالي أدى لربح سالب
الاسم بالإنجليزي: High Discount Resulting in Negative Profit

الوصف: نسبة خصم فوق 50% تسببت في هامش ربح سالب.

قاعدة الاكتشاف:
  avg_discount_pct > 0.50 AND profit_margin < 0

الاستعلام:
  SELECT order_id, avg_discount_pct, profit_margin, total_revenue
  FROM ml_output.mv_leakage_dashboard
  WHERE avg_discount_pct > 0.50 AND profit_margin < 0
  ORDER BY profit_margin ASC;

الجداول المرتبطة: orders, order_items, mv_leakage_dashboard$$,
'ar+en','business_rule', 8, 1.3,
'{
  "scenario":"high_discount_negative_profit",
  "embedding_type":"business_rule","priority":8,"retrieval_weight":1.3,
  "tables":["ecommerce.orders","ecommerce.order_items","ml_output.mv_leakage_dashboard"],
  "detection_columns":["avg_discount_pct","profit_margin"],
  "detection_thresholds":{"avg_discount_pct":0.50,"profit_margin":0},
  "keywords":["discount","negative profit","margin","خصم عالي","ربح سالب","هامش"],
  "arabic_aliases":["خصم كبير","تخفيض مفرط"],
  "english_aliases":["high discount loss","negative margin discount","over-discounting"]
}'::JSONB),

('leakage_scenario','scenario.no_invoice_on_completion',
 'Leakage Scenario: no_invoice_on_completion — لا فاتورة عند الاكتمال',
$$السيناريو: no_invoice_on_completion
الاسم بالعربي: لا توجد فاتورة عند اكتمال الأوردر
الاسم بالإنجليزي: No Invoice on Order Completion

الوصف: أوردر اكتمل (delivered) بدون فاتورة مسجلة.

قاعدة الاكتشاف:
  order_status = ''delivered'' AND invoice_available = FALSE

الجداول المرتبطة: orders, mv_leakage_dashboard$$,
'ar+en','business_rule', 7, 1.0,
'{
  "scenario":"no_invoice_on_completion",
  "embedding_type":"business_rule","priority":7,"retrieval_weight":1.0,
  "tables":["ecommerce.orders","ml_output.mv_leakage_dashboard"],
  "detection_columns":["order_status","invoice_available"],
  "keywords":["invoice","no invoice","فاتورة","بدون فاتورة"],
  "arabic_aliases":["غياب الفاتورة","فاتورة مفقودة"],
  "english_aliases":["missing invoice","no invoice","invoice not generated"]
}'::JSONB),

('leakage_scenario','scenario.partial_payment_only',
 'Leakage Scenario: partial_payment_only — دفع جزئي فقط',
$$السيناريو: partial_payment_only
الاسم بالعربي: دفع جزئي فقط
الاسم بالإنجليزي: Partial Payment Only

الوصف: تم دفع جزء من قيمة الأوردر فقط.

قاعدة الاكتشاف:
  payment_status = ''partial''

الجداول المرتبطة: orders, payments, mv_leakage_dashboard$$,
'ar+en','business_rule', 7, 1.0,
'{
  "scenario":"partial_payment_only",
  "embedding_type":"business_rule","priority":7,"retrieval_weight":1.0,
  "tables":["ecommerce.orders","ecommerce.payments"],
  "detection_columns":["payment_status"],
  "detection_values":{"payment_status":"partial"},
  "keywords":["partial","payment","جزئي","دفعة ناقصة"],
  "arabic_aliases":["دفع ناقص","دفعة جزئية"],
  "english_aliases":["partial payment","incomplete payment","underpayment"]
}'::JSONB),

('leakage_scenario','scenario.refund_before_cancellation',
 'Leakage Scenario: refund_before_cancellation — استرداد قبل الإلغاء',
$$السيناريو: refund_before_cancellation
الاسم بالعربي: استرداد قبل الإلغاء
الاسم بالإنجليزي: Refund Processed Before Cancellation

الوصف: تمت معالجة الاسترداد قبل إلغاء الأوردر رسمياً.

قاعدة الاكتشاف:
  refunds.processed_before_cancel = TRUE

الجداول المرتبطة: orders, refunds$$,
'ar+en','business_rule', 8, 1.3,
'{
  "scenario":"refund_before_cancellation",
  "embedding_type":"business_rule","priority":8,"retrieval_weight":1.3,
  "tables":["ecommerce.orders","ecommerce.refunds"],
  "detection_columns":["processed_before_cancel"],
  "keywords":["refund","cancellation","before cancel","استرداد","قبل الإلغاء"],
  "arabic_aliases":["رد قبل الإلغاء","استرداد مبكر"],
  "english_aliases":["early refund","refund before cancel","premature refund"]
}'::JSONB),

('leakage_scenario','scenario.inventory_mismatch',
 'Leakage Scenario: inventory_mismatch — عدم تطابق المخزون',
$$السيناريو: inventory_mismatch
الاسم بالعربي: عدم تطابق المخزون
الاسم بالإنجليزي: Inventory Mismatch

الوصف: الكمية المُسجَّلة في النظام لا تطابق الكمية الفعلية.

قاعدة الاكتشاف:
  orders.inventory_mismatch = TRUE

الجداول المرتبطة: orders, order_items, products$$,
'ar+en','business_rule', 8, 1.3,
'{
  "scenario":"inventory_mismatch",
  "embedding_type":"business_rule","priority":8,"retrieval_weight":1.3,
  "tables":["ecommerce.orders","ecommerce.order_items","ecommerce.products"],
  "detection_columns":["inventory_mismatch"],
  "keywords":["inventory","mismatch","stock","مخزون","عدم تطابق"],
  "arabic_aliases":["فجوة مخزون","تعارض مخزون"],
  "english_aliases":["inventory mismatch","stock discrepancy","inventory gap"]
}'::JSONB),

('leakage_scenario','scenario.seller_paid_twice',
 'Leakage Scenario: seller_paid_twice — البائع دُفع له مرتين',
$$السيناريو: seller_paid_twice
الاسم بالعربي: البائع دُفع له مرتين
الاسم بالإنجليزي: Seller Paid Twice

الوصف: تم دفع مبلغ البائع مرتين لنفس الأوردر.

قاعدة الاكتشاف:
  payments.seller_paid_twice = TRUE

الجداول المرتبطة: payments, orders, sellers$$,
'ar+en','business_rule', 9, 1.5,
'{
  "scenario":"seller_paid_twice",
  "embedding_type":"business_rule","priority":9,"retrieval_weight":1.5,
  "tables":["ecommerce.payments","ecommerce.orders","ecommerce.sellers"],
  "detection_columns":["seller_paid_twice"],
  "keywords":["seller paid twice","double payment","بائع","دفع مرتين"],
  "arabic_aliases":["دفع مزدوج للبائع","دفع مرتين للتاجر"],
  "english_aliases":["seller double payment","vendor paid twice","duplicate vendor payment"]
}'::JSONB),

('leakage_scenario','scenario.wrong_shipping_fee',
 'Leakage Scenario: wrong_shipping_fee — رسوم شحن خاطئة',
$$السيناريو: wrong_shipping_fee
الاسم بالعربي: رسوم شحن خاطئة
الاسم بالإنجليزي: Wrong Shipping Fee Calculated

الوصف: تم احتساب رسوم الشحن بشكل خاطئ.
العمود fee_to_cost_ratio شاذ إذا > 2 أو < 0.5.

قاعدة الاكتشاف:
  shipping.fee_calculation_error = TRUE

الجداول المرتبطة: shipping, orders$$,
'ar+en','business_rule', 7, 1.0,
'{
  "scenario":"wrong_shipping_fee",
  "embedding_type":"business_rule","priority":7,"retrieval_weight":1.0,
  "tables":["ecommerce.shipping","ecommerce.orders"],
  "detection_columns":["fee_calculation_error","fee_to_cost_ratio"],
  "keywords":["shipping fee","calculation error","fee_to_cost_ratio","رسوم شحن","خطأ"],
  "arabic_aliases":["رسوم شحن خاطئة","حساب شحن خاطئ"],
  "english_aliases":["wrong shipping fee","incorrect freight charge","fee calculation error"]
}'::JSONB),

('leakage_scenario','scenario.review_contradicts_cancelled',
 'Leakage Scenario: review_contradicts_cancelled — تقييم على أوردر ملغي',
$$السيناريو: review_contradicts_cancelled
الاسم بالعربي: تقييم موجود على أوردر ملغي
الاسم بالإنجليزي: Review on a Cancelled Order

الوصف: وجود review وكأن الأوردر تم، بينما order_status = canceled.
يشير لتلاعب أو خطأ في البيانات.

قاعدة الاكتشاف:
  order_status = ''canceled'' AND reviews.has_comment = TRUE

الجداول المرتبطة: orders, reviews$$,
'ar+en','business_rule', 7, 1.0,
'{
  "scenario":"review_contradicts_cancelled",
  "embedding_type":"business_rule","priority":7,"retrieval_weight":1.0,
  "tables":["ecommerce.orders","ecommerce.reviews"],
  "detection_columns":["order_status","has_comment"],
  "keywords":["cancelled order review","fake review","تقييم","إلغاء","تناقض"],
  "arabic_aliases":["تقييم على أوردر ملغي","مراجعة متناقضة"],
  "english_aliases":["review on cancelled order","contradicting review","ghost review"]
}'::JSONB),

('leakage_scenario','scenario.delayed_delivery_compensation',
 'Leakage Scenario: delayed_delivery_compensation — تعويض تأخير التسليم',
$$السيناريو: delayed_delivery_compensation
الاسم بالعربي: تعويض تأخير التسليم
الاسم بالإنجليزي: Late Delivery Compensation

الوصف: أوردر تأخر في التسليم أكثر من 14 يوم وتم تعويض العميل.

قاعدة الاكتشاف:
  shipping_delay_days > 14 AND refund_reason = ''late_delivery_compensation''

الجداول المرتبطة: orders, shipping, refunds$$,
'ar+en','business_rule', 7, 1.0,
'{
  "scenario":"delayed_delivery_compensation",
  "embedding_type":"business_rule","priority":7,"retrieval_weight":1.0,
  "tables":["ecommerce.orders","ecommerce.shipping","ecommerce.refunds"],
  "detection_columns":["shipping_delay_days","refund_reason"],
  "detection_thresholds":{"shipping_delay_days":14},
  "keywords":["delay","compensation","late delivery","تأخير","تعويض","تسليم متأخر"],
  "arabic_aliases":["تعويض التأخير","تسليم بطيء"],
  "english_aliases":["late delivery compensation","shipping delay refund","delayed order refund"]
}'::JSONB);


-- ================================================================
-- 3. SQL TEMPLATES — ONE DOCUMENT PER QUERY PATTERN
-- ================================================================

INSERT INTO rag.documents
    (source_type, source_id, title, content, content_lang,
     embedding_type, priority, retrieval_weight, metadata)
VALUES

('sql_template','sql.leakage_count_revenue',
 'SQL Template: إجمالي أوردرات وإيرادات الـ leakage',
$$السؤال: كم عدد أوردرات الـ leakage وإجمالي الإيراد في خطر؟
النية: aggregation / simple_lookup

SQL:
SELECT
    COUNT(*)                    AS leakage_orders,
    SUM(total_revenue)          AS total_revenue_at_risk,
    AVG(profit_margin)          AS avg_profit_margin,
    COUNT(*) FILTER (WHERE risk_tier = ''Critical'') AS critical_count
FROM ml_output.mv_leakage_dashboard
WHERE anomaly_flag = 1;

المصدر المفضل: ml_output.mv_leakage_dashboard
لا تحتاج JOIN.$$,
'ar+en','sql_template', 10, 2.0,
'{
  "template_id":"leakage_count_revenue",
  "embedding_type":"sql_template","priority":10,"retrieval_weight":2.0,
  "intent":["aggregation","simple_lookup"],
  "tables":["ml_output.mv_leakage_dashboard"],
  "keywords":["leakage count","revenue at risk","إجمالي","أوردرات تسرب","إيراد في خطر"],
  "no_joins_required":true
}'::JSONB),

('sql_template','sql.top_scenarios',
 'SQL Template: أكثر سيناريوهات الـ leakage شيوعاً',
$$السؤال: أكثر سيناريو leakage شيوعاً / أعلى خسارة؟
النية: aggregation / anomaly_investigation

SQL:
SELECT
    scenario,
    total_orders,
    revenue_at_risk,
    avg_anomaly_score,
    avg_profit_margin
FROM ml_output.mv_leakage_by_scenario
ORDER BY revenue_at_risk DESC
LIMIT 10;

المصدر المفضل: ml_output.mv_leakage_by_scenario
لا تحتاج JOIN.$$,
'ar+en','sql_template', 10, 2.0,
'{
  "template_id":"top_scenarios",
  "embedding_type":"sql_template","priority":10,"retrieval_weight":2.0,
  "intent":["aggregation","anomaly_investigation"],
  "tables":["ml_output.mv_leakage_by_scenario"],
  "keywords":["scenarios","top leakage","most common","أكثر سيناريو","خسارة"],
  "no_joins_required":true
}'::JSONB),

('sql_template','sql.worst_month',
 'SQL Template: أسوأ شهر من حيث نسبة الـ leakage',
$$السؤال: أسوأ شهر من حيث نسبة الـ leakage أو الإيراد في خطر؟
النية: trend_analysis

SQL:
-- أسوأ شهر واحد:
SELECT month_label, leakage_rate_pct, revenue_at_risk, leakage_orders
FROM ml_output.mv_monthly_leakage
ORDER BY leakage_rate_pct DESC
LIMIT 1;

-- اتجاه شهري كامل:
SELECT month_label, leakage_rate_pct, revenue_at_risk, total_orders
FROM ml_output.mv_monthly_leakage
ORDER BY month ASC;

المصدر المفضل: ml_output.mv_monthly_leakage$$,
'ar+en','sql_template', 10, 2.0,
'{
  "template_id":"worst_month",
  "embedding_type":"sql_template","priority":10,"retrieval_weight":2.0,
  "intent":["trend_analysis","aggregation"],
  "tables":["ml_output.mv_monthly_leakage"],
  "keywords":["monthly","worst month","trend","شهري","أسوأ شهر","اتجاه"],
  "no_joins_required":true
}'::JSONB),

('sql_template','sql.top_risky_sellers',
 'SQL Template: أخطر البائعين',
$$السؤال: أخطر البائعين / البائعون ذوو أعلى نسبة تسرب؟
النية: anomaly_investigation / aggregation

SQL:
SELECT
    seller_name,
    leakage_rate_pct,
    total_orders,
    avg_anomaly_score,
    payment_disputes
FROM ml_output.mv_seller_risk
ORDER BY leakage_rate_pct DESC
LIMIT 10;

المصدر المفضل: ml_output.mv_seller_risk$$,
'ar+en','sql_template', 10, 2.0,
'{
  "template_id":"top_risky_sellers",
  "embedding_type":"sql_template","priority":10,"retrieval_weight":2.0,
  "intent":["anomaly_investigation","aggregation"],
  "tables":["ml_output.mv_seller_risk"],
  "keywords":["risky sellers","seller risk","payment disputes","بائع خطر","تسرب بائع"],
  "no_joins_required":true
}'::JSONB),

('sql_template','sql.negative_margin_orders',
 'SQL Template: أوردرات بهامش ربح سالب',
$$السؤال: أوردرات بهامش ربح سالب؟ خسارة في الإيراد؟
النية: anomaly_investigation

SQL:
SELECT
    order_id, profit_margin, total_revenue,
    avg_discount_pct, risk_tier
FROM ml_output.mv_leakage_dashboard
WHERE profit_margin < 0
ORDER BY profit_margin ASC
LIMIT 20;

-- مع تصنيف الخسارة:
SELECT
    CASE
        WHEN profit_margin < -0.5 THEN ''شديدة''
        WHEN profit_margin < -0.2 THEN ''عالية''
        ELSE ''متوسطة''
    END AS loss_level,
    COUNT(*) AS orders,
    SUM(total_revenue) AS revenue_lost
FROM ml_output.mv_leakage_dashboard
WHERE profit_margin < 0
GROUP BY 1 ORDER BY revenue_lost DESC;$$,
'ar+en','sql_template', 9, 1.5,
'{
  "template_id":"negative_margin_orders",
  "embedding_type":"sql_template","priority":9,"retrieval_weight":1.5,
  "intent":["anomaly_investigation","aggregation"],
  "tables":["ml_output.mv_leakage_dashboard"],
  "keywords":["negative margin","loss","profit_margin","ربح سالب","خسارة","هامش"],
  "no_joins_required":true
}'::JSONB),

('sql_template','sql.critical_risk_orders',
 'SQL Template: أوردرات الـ Critical Risk',
$$السؤال: الأوردرات ذات المخاطر العالية جداً؟ أوردرات Critical؟
النية: anomaly_investigation / simple_lookup

SQL:
SELECT
    order_id, total_revenue, profit_margin,
    ensemble_score, leakage_scenarios,
    order_status, payment_status
FROM ml_output.mv_leakage_dashboard
WHERE risk_tier = ''Critical''
ORDER BY ensemble_score DESC
LIMIT 50;

-- بالشريحة أيضاً:
SELECT risk_tier, COUNT(*), SUM(total_revenue)
FROM ml_output.mv_leakage_dashboard
WHERE anomaly_flag = 1
GROUP BY risk_tier ORDER BY 3 DESC;$$,
'ar+en','sql_template', 10, 2.0,
'{
  "template_id":"critical_risk_orders",
  "embedding_type":"sql_template","priority":10,"retrieval_weight":2.0,
  "intent":["anomaly_investigation","simple_lookup"],
  "tables":["ml_output.mv_leakage_dashboard"],
  "keywords":["critical","high risk","ensemble_score","أوردرات حرجة","خطر عالي"],
  "no_joins_required":true
}'::JSONB),

('sql_template','sql.scenario_filter',
 'SQL Template: فلترة بسيناريو محدد',
$$السؤال: أوردرات سيناريو [X]؟ كم أوردر فيه [scenario]؟
النية: simple_lookup / anomaly_investigation

-- الطريقة 1: mv_leakage_dashboard (array filter):
SELECT order_id, total_revenue, risk_tier, ensemble_score
FROM ml_output.mv_leakage_dashboard
WHERE ''SCENARIO_NAME'' = ANY(leakage_scenarios)
ORDER BY ensemble_score DESC LIMIT 20;

-- الطريقة 2: order_leakage_reasons (أدق وأسرع):
SELECT olr.order_id, o.total_revenue, o.order_status
FROM ml_output.order_leakage_reasons olr
JOIN ecommerce.orders o ON olr.order_id = o.order_id
WHERE olr.leakage_type = ''SCENARIO_NAME''
ORDER BY o.total_revenue DESC;

استبدل SCENARIO_NAME بـ: duplicate_refund, delivered_no_payment,
  seller_paid_twice, high_discount_negative_profit, إلخ$$,
'ar+en','sql_template', 10, 2.0,
'{
  "template_id":"scenario_filter",
  "embedding_type":"sql_template","priority":10,"retrieval_weight":2.0,
  "intent":["simple_lookup","anomaly_investigation"],
  "tables":["ml_output.mv_leakage_dashboard","ml_output.order_leakage_reasons"],
  "keywords":["filter scenario","leakage_type","ANY","فلتر سيناريو","اكتشاف حالات"],
  "parameterized":true,
  "parameter":"SCENARIO_NAME"
}'::JSONB);


-- ================================================================
-- 4. KPI / BUSINESS GLOSSARY DOCUMENTS
-- ================================================================

INSERT INTO rag.documents
    (source_type, source_id, title, content, content_lang,
     embedding_type, priority, retrieval_weight, metadata)
VALUES

('kpi_glossary','kpi.revenue_leakage',
 'KPI: Revenue Leakage — تسرب الإيراد',
$$المقياس: Revenue Leakage / تسرب الإيراد

التعريف:
  إجمالي الإيراد المفقود بسبب أخطاء العمليات أو الغش أو السياسات الخاطئة.

الحساب:
  SUM(total_revenue) FROM mv_leakage_dashboard WHERE anomaly_flag = 1

الوحدة: جنيه مصري (EGP)
المصدر: ml_output.mv_leakage_dashboard
مرادفات: إيراد ضائع، خسارة تشغيلية، revenue at risk

KPIs مرتبطة:
- Leakage Rate % = leakage_orders / total_orders * 100
- Revenue at Risk % = revenue_at_risk / total_revenue * 100$$,
'ar+en','metric', 9, 1.5,
'{
  "kpi":"revenue_leakage",
  "embedding_type":"metric","priority":9,"retrieval_weight":1.5,
  "tables":["ml_output.mv_leakage_dashboard"],
  "keywords":["revenue leakage","at risk","تسرب","إيراد ضائع","خسارة"],
  "arabic_aliases":["تسرب الإيراد","الإيراد المفقود","الإيراد في خطر"],
  "english_aliases":["revenue leakage","lost revenue","revenue at risk","financial leakage"]
}'::JSONB),

('kpi_glossary','kpi.profit_margin',
 'KPI: Profit Margin — هامش الربح',
$$المقياس: Profit Margin / هامش الربح

التعريف:
  نسبة الربح الصافي من الإيراد الإجمالي.

الحساب:
  profit_margin = total_profit / total_revenue
  (موجود في جدول orders وفي mv_leakage_dashboard)

القيم:
- > 0: ربح
- = 0: تعادل
- < 0: خسارة (leakage محتملة)

الإشارة التحذيرية: profit_margin < 0 → logistics_exceeds_revenue أو high_discount_negative_profit$$,
'ar+en','metric', 8, 1.3,
'{
  "kpi":"profit_margin",
  "embedding_type":"metric","priority":8,"retrieval_weight":1.3,
  "column":"profit_margin",
  "tables":["ecommerce.orders","ml_output.mv_leakage_dashboard"],
  "keywords":["profit margin","negative profit","هامش الربح","ربح سالب"],
  "arabic_aliases":["هامش الربح","نسبة الربح"],
  "english_aliases":["profit margin","net margin","profitability"]
}'::JSONB),

('kpi_glossary','kpi.leakage_rate',
 'KPI: Leakage Rate — نسبة التسرب',
$$المقياس: Leakage Rate % / نسبة التسرب

التعريف:
  نسبة أوردرات الـ leakage من إجمالي الأوردرات.

الحساب:
  leakage_rate_pct = (leakage_orders / total_orders) * 100

المصدر الجاهز: ml_output.mv_monthly_leakage (عمود leakage_rate_pct)$$,
'ar+en','metric', 8, 1.3,
'{
  "kpi":"leakage_rate",
  "embedding_type":"metric","priority":8,"retrieval_weight":1.3,
  "column":"leakage_rate_pct",
  "tables":["ml_output.mv_monthly_leakage"],
  "keywords":["leakage rate","percentage","نسبة التسرب","معدل"],
  "arabic_aliases":["نسبة التسرب","معدل الخسارة"],
  "english_aliases":["leakage rate","loss rate","anomaly rate"]
}'::JSONB),

('kpi_glossary','kpi.churn_risk',
 'KPI: Churn Risk — خطر فقدان العميل',
$$المقياس: Churn Risk / خطر فقدان العميل

التعريف:
  احتمالية توقف العميل عن الشراء.

القيم:
- High: احتمال مرتفع للمغادرة
- Medium: في المنطقة الرمادية
- Low: عميل منتظم ومستمر

المصدر: ecommerce.customers.churn_risk
الاستخدام:
  SELECT customer_id, lifetime_value, churn_risk
  FROM ecommerce.customers
  WHERE churn_risk = ''High'' ORDER BY lifetime_value DESC;$$,
'ar+en','metric', 7, 1.0,
'{
  "kpi":"churn_risk",
  "embedding_type":"metric","priority":7,"retrieval_weight":1.0,
  "column":"churn_risk",
  "tables":["ecommerce.customers"],
  "keywords":["churn","retention","customer risk","خطر العميل","توقف"],
  "arabic_aliases":["خطر فقدان العميل","احتمال التوقف"],
  "english_aliases":["churn risk","customer attrition","retention risk"]
}'::JSONB);


-- ================================================================
-- 5. JOIN-GRAPH RELATIONSHIP DOCUMENTS
-- ================================================================

INSERT INTO rag.documents
    (source_type, source_id, title, content, content_lang,
     embedding_type, priority, retrieval_weight, metadata)
VALUES

('join_graph','join.orders_core',
 'Join Graph: المسارات الأساسية من orders',
$$مسارات الـ JOIN الأساسية من جدول orders:

orders → customers:
  JOIN ecommerce.customers c ON o.customer_id = c.customer_id

orders → order_items:
  JOIN ecommerce.order_items oi ON o.order_id = oi.order_id

orders → payments (دفعة واحدة):
  JOIN ecommerce.payments p ON o.order_id = p.order_id AND p.payment_sequential = 1

orders → shipping:
  JOIN ecommerce.shipping s ON o.order_id = s.order_id

orders → reviews:
  LEFT JOIN ecommerce.reviews r ON o.order_id = r.order_id

orders → refunds:
  LEFT JOIN ecommerce.refunds rf ON o.order_id = rf.order_id

orders → ML scores:
  LEFT JOIN ml_output.order_anomaly_scores ms ON o.order_id = ms.order_id

⚠️ تجنب هذه الـ JOINs كلها دفعة واحدة — استخدم ml_output.mv_leakage_dashboard بدلاً من ذلك.$$,
'ar+en','schema', 9, 1.5,
'{
  "embedding_type":"schema","priority":9,"retrieval_weight":1.5,
  "central_table":"ecommerce.orders",
  "keywords":["join","relationship","foreign key","JOIN path","مسار","علاقة"],
  "routing_hint":"Use mv_leakage_dashboard instead of manual JOINs for analytics"
}'::JSONB),

('join_graph','join.seller_risk_path',
 'Join Graph: مسار بيانات مخاطر البائع',
$$مسار JOIN لاستخراج بيانات مخاطر البائع:

sellers → order_items → orders → anomaly_scores:
  FROM ecommerce.sellers s
  JOIN ecommerce.order_items oi ON s.seller_id = oi.seller_id
  JOIN ecommerce.orders o       ON oi.order_id = o.order_id
  LEFT JOIN ml_output.order_anomaly_scores ms ON o.order_id = ms.order_id

⚠️ الأفضل: استخدم ml_output.mv_seller_risk مباشرة — تجميع جاهز.$$,
'ar+en','schema', 8, 1.3,
'{
  "embedding_type":"schema","priority":8,"retrieval_weight":1.3,
  "tables":["ecommerce.sellers","ecommerce.order_items","ecommerce.orders","ml_output.order_anomaly_scores"],
  "keywords":["seller risk path","vendor join","مسار البائع"],
  "preferred_view":"ml_output.mv_seller_risk"
}'::JSONB);


-- ================================================================
-- 6. ANTI-PATTERN / SQL MISTAKE DOCUMENTS
-- ================================================================

INSERT INTO rag.documents
    (source_type, source_id, title, content, content_lang,
     embedding_type, priority, retrieval_weight, metadata)
VALUES

('anti_pattern','anti.dont_use_price',
 'Anti-Pattern: استخدام price بدلاً من price_after_discount',
$$❌ خطأ شائع:
  SELECT SUM(oi.price) ...  -- يتجاهل الخصومات!

✅ الصحيح:
  SELECT SUM(oi.price_after_discount) ...

السبب: عمود price هو السعر الأصلي قبل الخصم.
price_after_discount هو السعر الفعلي المدفوع.$$,
'ar+en','schema', 10, 2.0,
'{
  "anti_pattern":"use_price_instead_of_price_after_discount",
  "embedding_type":"schema","priority":10,"retrieval_weight":2.0,
  "tables":["ecommerce.order_items"],
  "keywords":["price","discount","revenue calculation","خطأ","سعر","خصم"],
  "correct_column":"price_after_discount",
  "wrong_column":"price"
}'::JSONB),

('anti_pattern','anti.payments_no_sequential_filter',
 'Anti-Pattern: الـ payments بدون فلتر payment_sequential',
$$❌ خطأ شائع:
  SELECT payment_type FROM ecommerce.payments WHERE order_id = ''X''
  -- يرجع كل الدفعات (أقساط متعددة)، يسبب تكرار

✅ الصحيح:
  SELECT payment_type FROM ecommerce.payments
  WHERE order_id = ''X'' AND payment_sequential = 1

السبب: أوردر واحد ممكن له عدة دفعات (أقساط).$$,
'ar+en','schema', 10, 2.0,
'{
  "anti_pattern":"missing_payment_sequential_filter",
  "embedding_type":"schema","priority":10,"retrieval_weight":2.0,
  "tables":["ecommerce.payments"],
  "keywords":["payment_sequential","duplicate rows","دفعات","تكرار"],
  "required_filter":"payment_sequential = 1"
}'::JSONB),

('anti_pattern','anti.raw_joins_instead_of_mv',
 'Anti-Pattern: استخدام raw JOINs بدلاً من Materialized Views',
$$❌ خطأ شائع:
  SELECT o.order_id, c.segment, ms.risk_tier
  FROM ecommerce.orders o
  JOIN ecommerce.customers c ON o.customer_id = c.customer_id
  JOIN ml_output.order_anomaly_scores ms ON o.order_id = ms.order_id
  -- بطيء على ملايين الصفوف

✅ الصحيح:
  SELECT order_id, customer_segment, risk_tier
  FROM ml_output.mv_leakage_dashboard
  WHERE anomaly_flag = 1

القاعدة: لأي سؤال تحليلي على الـ leakage، ابدأ بـ mv_leakage_dashboard.$$,
'ar+en','schema', 10, 2.0,
'{
  "anti_pattern":"raw_joins_over_materialized_views",
  "embedding_type":"schema","priority":10,"retrieval_weight":2.0,
  "keywords":["materialized view","raw join","performance","بطيء","بديل جاهز"],
  "preferred_view":"ml_output.mv_leakage_dashboard"
}'::JSONB),

('anti_pattern','anti.order_month_group_by',
 'Anti-Pattern: GROUP BY التاريخ بدون استخدام order_month',
$$❌ خطأ شائع:
  GROUP BY DATE_TRUNC(''month'', order_purchase_timestamp)
  -- يعيد حساب كل مرة ولا يستخدم العمود الـ GENERATED

✅ الصحيح:
  GROUP BY order_month
  -- عمود GENERATED جاهز وله index

أعمدة GENERATED في orders:
- order_month   → أول يوم في الشهر
- order_quarter → أول يوم في الربع
- order_year    → السنة$$,
'ar+en','schema', 9, 1.5,
'{
  "anti_pattern":"date_trunc_instead_of_generated_column",
  "embedding_type":"schema","priority":9,"retrieval_weight":1.5,
  "tables":["ecommerce.orders"],
  "keywords":["order_month","date_trunc","GROUP BY","generated column","شهري"],
  "generated_columns":["order_month","order_quarter","order_year"]
}'::JSONB);


-- ================================================================
-- 7. ENUM REFERENCE DOCUMENTS
-- ================================================================

INSERT INTO rag.documents
    (source_type, source_id, title, content, content_lang,
     embedding_type, priority, retrieval_weight, metadata)
VALUES

('enum_reference','enum.order_status',
 'ENUM Reference: order_status — حالات الأوردر',
$$ENUM: order_status (ecommerce.orders)
القيم الصحيحة الوحيدة:
- delivered    → تم التسليم ✓
- canceled     → ملغي ✗
- shipped      → في الطريق
- processing   → قيد المعالجة
- invoiced     → تمت الفوترة
- unavailable  → غير متاح

⚠️ لا يوجد: ''complete'', ''done'', ''finished'', ''paid''
⚠️ استخدم ''canceled'' وليس ''cancelled'' (بدون حرف L مزدوج)$$,
'ar+en','schema', 10, 2.0,
'{
  "enum_type":"order_status",
  "embedding_type":"schema","priority":10,"retrieval_weight":2.0,
  "table":"ecommerce.orders",
  "valid_values":["delivered","canceled","shipped","processing","invoiced","unavailable"],
  "keywords":["order_status","enum values","حالة الأوردر"],
  "common_mistakes":["cancelled","complete","done","finished","paid"]
}'::JSONB),

('enum_reference','enum.payment_status',
 'ENUM Reference: payment_status — حالات الدفع',
$$ENUM: payment_status (ecommerce.orders, ecommerce.payments)
القيم الصحيحة:
- approved  → مدفوع ومعتمد ✓
- partial   → دفع جزئي
- unpaid    → لم يُدفع
- missing   → لا يوجد سجل دفع (leakage!)

⚠️ لا يوجد: ''pending'', ''complete'', ''success'', ''failed''$$,
'ar+en','schema', 10, 2.0,
'{
  "enum_type":"payment_status",
  "embedding_type":"schema","priority":10,"retrieval_weight":2.0,
  "tables":["ecommerce.orders","ecommerce.payments"],
  "valid_values":["approved","partial","unpaid","missing"],
  "leakage_value":"missing",
  "keywords":["payment_status","enum","حالة الدفع"],
  "common_mistakes":["pending","complete","success","failed","paid"]
}'::JSONB),

('enum_reference','enum.risk_tier',
 'ENUM Reference: risk_tier — مستويات المخاطر',
$$ENUM: risk_tier (ml_output.order_anomaly_scores)
القيم وحدود ensemble_score:
- Low      → ensemble_score < 0.40
- Medium   → 0.40 ≤ ensemble_score < 0.65
- High     → 0.65 ≤ ensemble_score < 0.80
- Critical → ensemble_score ≥ 0.80

⚠️ لا يوجد: ''Extreme'', ''Severe'', ''Normal'', ''Warning'', ''Alert''$$,
'ar+en','schema', 10, 2.0,
'{
  "enum_type":"risk_tier",
  "embedding_type":"schema","priority":10,"retrieval_weight":2.0,
  "table":"ml_output.order_anomaly_scores",
  "valid_values":["Low","Medium","High","Critical"],
  "score_ranges":{"Low":"< 0.40","Medium":"0.40-0.65","High":"0.65-0.80","Critical":"> 0.80"},
  "keywords":["risk_tier","ensemble_score","مستوى خطر"],
  "common_mistakes":["Extreme","Severe","Normal","Warning","Alert"]
}'::JSONB),

('enum_reference','enum.shipping_status',
 'ENUM Reference: shipping_status — حالات الشحن',
$$ENUM: shipping_status (ecommerce.shipping)
القيم الصحيحة:
- delivered      → تم التسليم ✓
- in_transit     → في الطريق
- cancelled      → ملغي (بـ double L هنا)
- failed         → فشل التسليم
- never_shipped  → لم يُشحن أبداً (leakage!)
- pending        → معلق

⚠️ shipping_status = ''cancelled'' (بـ LL) لكن order_status = ''canceled'' (بـ L واحدة)$$,
'ar+en','schema', 10, 2.0,
'{
  "enum_type":"shipping_status",
  "embedding_type":"schema","priority":10,"retrieval_weight":2.0,
  "table":"ecommerce.shipping",
  "valid_values":["delivered","in_transit","cancelled","failed","never_shipped","pending"],
  "leakage_value":"never_shipped",
  "keywords":["shipping_status","حالة الشحن","carrier"],
  "spelling_note":"shipping uses cancelled (LL), orders uses canceled (L)"
}'::JSONB),

('enum_reference','enum.carriers',
 'ENUM Reference: carrier — شركات الشحن',
$$القيم الصحيحة لعمود carrier في ecommerce.shipping:
- ''Aramex EG''
- ''Egypt Post''
- ''Bosta''
- ''Mylerz''
- ''Voo''
- ''R2S Express''

⚠️ استخدم الأسماء بالضبط كما هي بما فيها المسافات وحروف الكبتال.$$,
'ar+en','schema', 9, 1.5,
'{
  "enum_type":"carrier",
  "embedding_type":"schema","priority":9,"retrieval_weight":1.5,
  "table":"ecommerce.shipping",
  "valid_values":["Aramex EG","Egypt Post","Bosta","Mylerz","Voo","R2S Express"],
  "keywords":["carrier","shipping company","شركة الشحن","أرامكس","بوسطة"]
}'::JSONB),

('enum_reference','enum.payment_type',
 'ENUM Reference: payment_type — طرق الدفع',
$$القيم الصحيحة لعمود payment_type في ecommerce.payments:
- ''credit_card''       → بطاقة ائتمان
- ''debit_card''        → بطاقة خصم
- ''voucher''           → كوبون / قسيمة
- ''cash_on_delivery''  → كاش عند الاستلام (COD)

⚠️ لا يوجد: ''cash'', ''online'', ''wallet'', ''fawry'', ''instapay''$$,
'ar+en','schema', 9, 1.5,
'{
  "enum_type":"payment_type",
  "embedding_type":"schema","priority":9,"retrieval_weight":1.5,
  "table":"ecommerce.payments",
  "valid_values":["credit_card","debit_card","voucher","cash_on_delivery"],
  "keywords":["payment_type","COD","credit","طريقة الدفع","كاش"],
  "common_mistakes":["cash","online","wallet","fawry","instapay"]
}'::JSONB);


-- ================================================================
-- 8. GENERATED COLUMN EXPLANATION DOCS
-- ================================================================

INSERT INTO rag.documents
    (source_type, source_id, title, content, content_lang,
     embedding_type, priority, retrieval_weight, metadata)
VALUES

('generated_column','gen.order_month',
 'Generated Column: order_month — التجميع الشهري',
$$العمود: order_month (ecommerce.orders)
النوع: DATE — GENERATED ALWAYS AS (DATE_TRUNC(''month'', order_purchase_timestamp))

الاستخدام الصحيح في GROUP BY الشهري:
  SELECT order_month, SUM(total_revenue), COUNT(*)
  FROM ecommerce.orders
  GROUP BY order_month
  ORDER BY order_month;

⚠️ لا تستخدم DATE_TRUNC(''month'', order_purchase_timestamp) يدوياً — هذا العمود جاهز ومع index.

أعمدة GENERATED مرتبطة:
- order_quarter: DATE_TRUNC(''quarter'', ...)
- order_year:    EXTRACT(year FROM ...)$$,
'ar+en','schema', 9, 1.5,
'{
  "generated_column":"order_month",
  "embedding_type":"schema","priority":9,"retrieval_weight":1.5,
  "table":"ecommerce.orders",
  "formula":"DATE_TRUNC(month, order_purchase_timestamp)",
  "use_for":"monthly GROUP BY",
  "keywords":["order_month","monthly grouping","date trunc","شهري","تجميع"],
  "related_columns":["order_quarter","order_year"]
}'::JSONB),

('generated_column','gen.fee_to_cost_ratio',
 'Generated Column: fee_to_cost_ratio — نسبة رسوم الشحن',
$$العمود: fee_to_cost_ratio (ecommerce.shipping)
النوع: NUMERIC — GENERATED ALWAYS AS (shipping_fee_charged / NULLIF(actual_logistics_cost, 0))

التفسير:
- = 1.0 → رسوم تساوي التكلفة (مثالي)
- > 2.0 → رسوم مبالغ فيها (شاذ)
- < 0.5 → رسوم أقل من التكلفة (خسارة في الشحن)

الاستخدام للكشف عن wrong_shipping_fee:
  SELECT order_id, shipping_fee_charged, actual_logistics_cost, fee_to_cost_ratio
  FROM ecommerce.shipping
  WHERE fee_to_cost_ratio > 2.0 OR fee_to_cost_ratio < 0.5
  ORDER BY fee_to_cost_ratio DESC;$$,
'ar+en','schema', 8, 1.3,
'{
  "generated_column":"fee_to_cost_ratio",
  "embedding_type":"schema","priority":8,"retrieval_weight":1.3,
  "table":"ecommerce.shipping",
  "formula":"shipping_fee_charged / actual_logistics_cost",
  "anomaly_thresholds":{"high":2.0,"low":0.5},
  "linked_scenario":"wrong_shipping_fee",
  "keywords":["fee_to_cost_ratio","shipping fee","generated","نسبة رسوم الشحن"]
}'::JSONB);


-- ================================================================
-- 9. ANOMALY INTERPRETATION DOCUMENTS
-- ================================================================

INSERT INTO rag.documents
    (source_type, source_id, title, content, content_lang,
     embedding_type, priority, retrieval_weight, metadata)
VALUES

('anomaly_interpretation','interp.ensemble_score',
 'Anomaly Interpretation: ensemble_score — تفسير درجة الشذوذ',
$$تفسير ensemble_score في ml_output.order_anomaly_scores:

الحساب: متوسط مرجح بين if_score (Isolation Forest) و lof_score (Local Outlier Factor)

النطاقات والتصرف المقترح:
- 0.00–0.39 (Low):     أوردر طبيعي — لا تدخل مطلوب
- 0.40–0.64 (Medium):  مراجعة دورية — راقب التكرار
- 0.65–0.79 (High):    تحقيق فوري — ممكن خسارة مالية
- 0.80–1.00 (Critical): تصعيد فوري — خسارة مؤكدة تقريباً

مثال:
  SELECT order_id, ensemble_score, risk_tier, leakage_scenarios
  FROM ml_output.mv_leakage_dashboard
  WHERE ensemble_score > 0.80
  ORDER BY ensemble_score DESC;$$,
'ar+en','metric', 9, 1.5,
'{
  "metric":"ensemble_score",
  "embedding_type":"metric","priority":9,"retrieval_weight":1.5,
  "table":"ml_output.order_anomaly_scores",
  "score_ranges":{"Low":"0.00-0.39","Medium":"0.40-0.64","High":"0.65-0.79","Critical":"0.80-1.00"},
  "keywords":["ensemble_score","anomaly score","risk score","درجة الشذوذ","تفسير"],
  "arabic_aliases":["درجة الشذوذ","درجة الخطر","نتيجة النموذج"],
  "english_aliases":["anomaly score","risk score","ML score","fraud score"]
}'::JSONB),

('anomaly_interpretation','interp.anomaly_flag',
 'Anomaly Interpretation: anomaly_flag — علامة الـ Leakage',
$$العمود: anomaly_flag في ml_output.order_anomaly_scores

القيم:
- 0 → الأوردر طبيعي — لا يوجد leakage مكتشف
- 1 → الأوردر مشبوه — يوجد leakage مكتشف

الاستخدام:
  WHERE anomaly_flag = 1   -- كل الأوردرات المشبوهة
  WHERE anomaly_flag = 0   -- الأوردرات الطبيعية فقط

ملاحظة: anomaly_flag = 1 لا يعني بالضرورة خطأً مؤكداً — الدرجة risk_tier تحدد مستوى الثقة.$$,
'ar+en','metric', 9, 1.5,
'{
  "metric":"anomaly_flag",
  "embedding_type":"metric","priority":9,"retrieval_weight":1.5,
  "table":"ml_output.order_anomaly_scores",
  "valid_values":[0,1],
  "keywords":["anomaly_flag","leakage detected","علامة التسرب","مشبوه"],
  "arabic_aliases":["علامة الشذوذ","مؤشر التسرب"],
  "english_aliases":["anomaly flag","leakage flag","fraud flag"]
}'::JSONB);


-- ================================================================
-- 10. ROUTING HINT DOCUMENTS
-- ================================================================

INSERT INTO rag.documents
    (source_type, source_id, title, content, content_lang,
     embedding_type, priority, retrieval_weight, metadata)
VALUES

('routing_hint','route.intent_map',
 'Routing: تصنيف نية الاستعلام وتوجيهه',
$$توجيه الاستعلامات حسب نوعها:

1. simple_lookup:
   كلمات: "كم عدد"، "أظهر"، "show me", "how many", "list"
   مصدر: mv_leakage_dashboard

2. aggregation:
   كلمات: "إجمالي"، "متوسط"، "نسبة"، "total", "average", "percentage"
   مصادر: mv_monthly_leakage, mv_leakage_by_scenario, mv_seller_risk

3. trend_analysis:
   كلمات: "شهري"، "ربعي"، "اتجاه"، "trend", "monthly", "over time"
   مصدر: mv_monthly_leakage

4. anomaly_investigation:
   كلمات: "خطر"، "مشبوه"، "leakage"، "critical"، "fraud", "anomaly"
   مصادر: mv_leakage_dashboard, order_leakage_reasons

5. sentiment_analysis:
   كلمات: "تقييم"، "رأي"، "شكوى"، "review", "sentiment", "feedback"
   مصدر: ecommerce.reviews

6. schema_discovery:
   كلمات: "جدول"، "عمود"، "schema", "table", "column"
   مصدر: rag.documents (source_type = schema_doc)$$,
'ar+en','routing', 10, 2.0,
'{
  "embedding_type":"routing","priority":10,"retrieval_weight":2.0,
  "intents":["simple_lookup","aggregation","trend_analysis","anomaly_investigation","sentiment_analysis","schema_discovery"],
  "keywords":["routing","intent","query type","توجيه","نية الاستعلام"]
}'::JSONB),

('routing_hint','route.preferred_sources',
 'Routing: المصدر المفضل لكل نوع سؤال',
$$قواعد اختيار المصدر المفضل:

  أوردرات leakage عامة       → mv_leakage_dashboard
  إحصاء شهري / ربعي         → mv_monthly_leakage
  ترتيب البائعين بالخطر      → mv_seller_risk
  مقارنة السيناريوهات        → mv_leakage_by_scenario
  فلتر سيناريو محدد          → order_leakage_reasons (أسرع)
  بيانات مدفوعات تفصيلية     → ecommerce.payments (+ filter seq=1)
  تقييمات وشكاوى عملاء       → ecommerce.reviews
  بيانات منتج تفصيلية        → ecommerce.order_items + products
  تعريف مقياس (KPI)          → rag.documents (kpi_glossary)

القاعدة العامة: ابدأ دائماً بالـ Materialized Views قبل الرجوع للجداول الأصلية.$$,
'ar+en','routing', 10, 2.0,
'{
  "embedding_type":"routing","priority":10,"retrieval_weight":2.0,
  "keywords":["preferred source","routing table","مصدر مفضل","توجيه"],
  "materialized_views_first":true
}'::JSONB);


-- ================================================================
-- 11. LINEAGE DOCUMENTS
-- ================================================================

INSERT INTO rag.documents
    (source_type, source_id, title, content, content_lang,
     embedding_type, priority, retrieval_weight, metadata)
VALUES

('lineage_doc','lineage.revenue_at_risk',
 'Lineage: revenue_at_risk — مصدر واشتقاق',
$$المقياس: revenue_at_risk

المصدر الأصلي: ecommerce.orders.total_revenue
التحويل:
  1. orders.total_revenue (مجموع price_after_discount في order_items)
  2. → ml_output.order_anomaly_scores.anomaly_flag = 1 (تصفية)
  3. → mv_leakage_dashboard.revenue_at_risk (تجميع)
  4. → mv_leakage_by_scenario.revenue_at_risk (تجميع حسب سيناريو)
  5. → mv_monthly_leakage.revenue_at_risk (تجميع شهري)

الاستعلام لإعادة الحساب من المصدر:
  SELECT SUM(o.total_revenue)
  FROM ecommerce.orders o
  JOIN ml_output.order_anomaly_scores ms ON o.order_id = ms.order_id
  WHERE ms.anomaly_flag = 1;$$,
'ar+en','lineage', 8, 1.3,
'{
  "metric":"revenue_at_risk",
  "embedding_type":"lineage","priority":8,"retrieval_weight":1.3,
  "source_table":"ecommerce.orders",
  "source_column":"total_revenue",
  "final_mv":"ml_output.mv_leakage_dashboard",
  "keywords":["lineage","revenue_at_risk","data flow","مصدر البيانات","اشتقاق"]
}'::JSONB),

('lineage_doc','lineage.profit_margin_calc',
 'Lineage: profit_margin — طريقة الحساب',
$$المقياس: profit_margin

المصدر: ecommerce.orders
الصيغة:
  profit_margin = total_profit / NULLIF(total_revenue, 0)

حيث:
  total_revenue = SUM(order_items.price_after_discount)
  total_profit  = total_revenue - total_costs
  total_costs   = SUM(logistics_cost) + overhead

القيم الشاذة:
  profit_margin < 0  → خسارة → leakage مرتبط بـ:
    - high_discount_negative_profit (avg_discount_pct > 0.5)
    - logistics_exceeds_revenue (تكاليف شحن عالية)$$,
'ar+en','lineage', 8, 1.3,
'{
  "metric":"profit_margin",
  "embedding_type":"lineage","priority":8,"retrieval_weight":1.3,
  "source_table":"ecommerce.orders",
  "formula":"total_profit / total_revenue",
  "keywords":["profit_margin","calculation","formula","هامش الربح","حساب"]
}'::JSONB);


-- ================================================================
-- 12. SUMMARY PROFILE DOCUMENTS
-- ================================================================

INSERT INTO rag.documents
    (source_type, source_id, title, content, content_lang,
     embedding_type, priority, retrieval_weight, metadata)
VALUES

('summary_profile','summary.high_risk_seller_profile',
 'Summary: ملف البائع عالي المخاطر',
$$ملف البائع عالي المخاطر (High-Risk Seller Profile):

السمات الرئيسية:
- leakage_rate_pct > 0.30 (أكثر من 30% من الأوردرات مشبوهة)
- return_rate > 0.15 (نسبة إرجاع عالية)
- payment_disputes عالية (نزاعات مالية متكررة)
- avg_anomaly_score > 0.65

السيناريوهات الأكثر ارتباطاً بالبائعين:
- seller_paid_twice
- shipped_then_cancelled
- inventory_mismatch
- high_discount_negative_profit

الاستعلام:
  SELECT * FROM ml_output.mv_seller_risk
  WHERE leakage_rate_pct > 0.30
  ORDER BY avg_anomaly_score DESC;$$,
'ar+en','metric', 8, 1.3,
'{
  "profile_type":"high_risk_seller",
  "embedding_type":"metric","priority":8,"retrieval_weight":1.3,
  "source_view":"ml_output.mv_seller_risk",
  "keywords":["high risk seller","vendor fraud","بائع خطر","تسرب بائع"],
  "thresholds":{"leakage_rate_pct":0.30,"return_rate":0.15,"avg_anomaly_score":0.65}
}'::JSONB),

('summary_profile','summary.high_value_at_risk_customer',
 'Summary: ملف العميل عالي القيمة في خطر',
$$ملف العميل عالي القيمة في خطر (High-Value Customer At Risk):

السمات:
- segment = ''High Value'' (lifetime_value > 1000 EGP)
- churn_risk = ''High''
- أوردرات برسوم خاطئة أو تسليم متأخر

الإجراء المقترح:
  حملة استرداد فورية + فحص يدوي للأوردرات

الاستعلام:
  SELECT c.customer_id, c.lifetime_value, c.churn_risk,
         COUNT(d.order_id) AS leakage_orders
  FROM ecommerce.customers c
  JOIN ml_output.mv_leakage_dashboard d ON c.customer_id = d.customer_id
  WHERE c.segment = ''High Value'' AND c.churn_risk = ''High''
    AND d.anomaly_flag = 1
  GROUP BY c.customer_id, c.lifetime_value, c.churn_risk
  ORDER BY c.lifetime_value DESC;$$,
'ar+en','metric', 8, 1.3,
'{
  "profile_type":"high_value_at_risk_customer",
  "embedding_type":"metric","priority":8,"retrieval_weight":1.3,
  "tables":["ecommerce.customers","ml_output.mv_leakage_dashboard"],
  "keywords":["high value customer","churn","at risk","عميل مهم","خطر التوقف"]
}'::JSONB);


-- ================================================================
-- 13. REVIEWS INSERT (runtime — requires ecommerce tables to exist)
-- ================================================================

-- Note: Run this section AFTER ecommerce schema is populated.
-- The INSERT uses a NOT EXISTS guard to prevent duplicates on re-runs.

INSERT INTO rag.documents
    (source_type, source_id, title, content, content_lang,
     embedding_type, priority, retrieval_weight, metadata)
SELECT
    'review'::rag.rag_source_t,
    r.order_id,
    'Customer Review: ' || r.order_id,
    CONCAT(
        'Order ID: ', r.order_id, E'\n',
        'Rating: ', r.rating_group, E'\n',
        'Sentiment: ', r.sentiment, E'\n',
        'Leakage Scenarios: ', COALESCE(
            (SELECT STRING_AGG(olr.leakage_type::TEXT, ', ')
             FROM ml_output.order_leakage_reasons olr
             WHERE olr.order_id = r.order_id), 'no_leakage'), E'\n',
        'Order Status: ', o.order_status, E'\n',
        'Review: ', r.review_comment
    ),
    'ar+en',
    'review'::rag.embedding_type_t,
    CASE
        WHEN ms.anomaly_flag = 1 AND r.sentiment = 'negative' THEN 5
        WHEN ms.anomaly_flag = 1 THEN 4
        WHEN r.sentiment = 'negative' THEN 3
        ELSE 2
    END,
    0.6,
    jsonb_build_object(
        'order_id',           r.order_id,
        'rating',             r.rating_group,
        'sentiment',          r.sentiment,
        'order_status',       o.order_status,
        'anomaly_flag',       COALESCE(ms.anomaly_flag, 0),
        'risk_tier',          ms.risk_tier,
        'embedding_type',     'review',
        'retrieval_weight',   0.6,
        'source_type_filter', 'review'
    )
FROM ecommerce.reviews r
JOIN ecommerce.orders o ON r.order_id = o.order_id
LEFT JOIN ml_output.order_anomaly_scores ms ON r.order_id = ms.order_id
WHERE r.review_comment IS NOT NULL
  AND LENGTH(TRIM(r.review_comment)) > 10
  AND r.is_emoji_only = FALSE
  AND NOT EXISTS (
    SELECT 1 FROM rag.documents rd
    WHERE rd.source_id = r.order_id AND rd.source_type = 'review'
  )
ORDER BY
    COALESCE(ms.anomaly_flag, 0) DESC,
    CASE r.sentiment WHEN 'negative' THEN 0 WHEN 'neutral' THEN 1 ELSE 2 END,
    r.review_date DESC
LIMIT 30000;


-- ================================================================
-- 14. LEAKAGE REASON DOCS (runtime — requires ecommerce tables)
-- ================================================================

INSERT INTO rag.documents
    (source_type, source_id, title, content, content_lang,
     embedding_type, priority, retrieval_weight, metadata)
SELECT
    'leakage_reason'::rag.rag_source_t,
    ms.order_id,
    'Leakage Report: ' || ms.order_id,
    CONCAT(
        'Order ID: ', ms.order_id, E'\n',
        'Risk Tier: ', ms.risk_tier, E'\n',
        'Anomaly Score: ', ms.ensemble_score, E'\n',
        'Order Status: ', o.order_status, E'\n',
        'Payment Status: ', o.payment_status, E'\n',
        'Total Revenue: ', o.total_revenue, ' EGP', E'\n',
        'Profit Margin: ', o.profit_margin, E'\n',
        'Shipping Delay Days: ', o.shipping_delay_days, E'\n',
        'Leakage Scenarios: ', COALESCE(
            (SELECT STRING_AGG(olr.leakage_type::TEXT, ' | ')
             FROM ml_output.order_leakage_reasons olr
             WHERE olr.order_id = ms.order_id), 'none'), E'\n',
        'Customer Segment: ', c.segment, E'\n',
        'City: ', c.customer_city
    ),
    'ar+en',
    'business_rule'::rag.embedding_type_t,
    CASE ms.risk_tier
        WHEN 'Critical' THEN 8
        WHEN 'High'     THEN 7
        WHEN 'Medium'   THEN 5
        ELSE 3
    END,
    CASE ms.risk_tier
        WHEN 'Critical' THEN 1.2
        WHEN 'High'     THEN 1.0
        ELSE 0.8
    END,
    jsonb_build_object(
        'order_id',       ms.order_id,
        'risk_tier',      ms.risk_tier,
        'ensemble_score', ms.ensemble_score,
        'anomaly_flag',   ms.anomaly_flag,
        'order_status',   o.order_status,
        'payment_status', o.payment_status,
        'total_revenue',  o.total_revenue,
        'embedding_type', 'business_rule',
        'source_type_filter', 'leakage_reason'
    )
FROM ml_output.order_anomaly_scores ms
JOIN ecommerce.orders o ON ms.order_id = o.order_id
JOIN ecommerce.customers c ON o.customer_id = c.customer_id
WHERE ms.anomaly_flag = 1;


-- ================================================================
-- 15. SQL GUARD RULES (Hallucination Prevention)
-- ================================================================

-- ----------------------------------------------------------------
-- FIX for original sql_guard:
--   The original used plain TEXT for patterns but compared with =,
--   meaning an exact-string match — useless for detecting patterns
--   inside generated SQL. Fixed by:
--     1. Adding a guard_mode column ('exact' | 'contains' | 'regex')
--     2. Providing a validation function that dispatches accordingly.
-- ----------------------------------------------------------------

ALTER TABLE rag.sql_guard ADD COLUMN IF NOT EXISTS
    guard_mode TEXT NOT NULL DEFAULT 'contains'
    CHECK (guard_mode IN ('exact', 'contains', 'regex'));

INSERT INTO rag.sql_guard (guard_type, guard_mode, pattern, message) VALUES
-- Fake columns — use 'contains' to catch them anywhere in a query
('fake_column',  'contains', 'orders.status',
 'Column does not exist. Use orders.order_status'),
('fake_column',  'contains', 'orders.amount',
 'Column does not exist. Use orders.total_revenue'),
('fake_column',  'contains', 'customers.name',
 'Column does not exist. Use customers.customer_unique_id or customer_city'),
('fake_column',  'contains', 'payments.amount',
 'Column does not exist. Use payments.payment_value'),
('fake_column',  'contains', 'order_items.final_price',
 'Column does not exist. Use order_items.price_after_discount'),

-- Fake ENUMs — exact quoted string values
('fake_enum',    'contains', '''complete''',
 'Invalid order_status value. Use ''delivered'' or ''processing'''),
('fake_enum',    'contains', '''success''',
 'Invalid payment_status value. Use ''approved'''),
('fake_enum',    'contains', '''pending_payment''',
 'Invalid status. Use payment_status = ''unpaid'''),
('fake_enum',    'contains', '''Extreme''',
 'Invalid risk_tier. Valid values: Low, Medium, High, Critical'),
('fake_enum',    'contains', '''Severe''',
 'Invalid risk_tier. Valid values: Low, Medium, High, Critical'),

-- Dangerous patterns — use regex for structural detection
('dangerous_join', 'regex',
 'reviews\s+.*JOIN\s+.*orders\s+.*JOIN\s+.*payments\s+.*JOIN\s+.*shipping',
 'Too many JOINs — use ml_output.mv_leakage_dashboard instead'),
('dangerous_join', 'regex',
 'order_items\s+.*JOIN\s+.*orders\s+.*WHERE\s+.*\bprice\b(?!_after_discount)',
 'Use price_after_discount instead of price for revenue calculations'),
('dangerous_join', 'regex',
 'FROM\s+ecommerce\.payments(?!.*payment_sequential)',
 'Missing payment_sequential = 1 filter — will return duplicate rows');

-- Validation function: call this from application layer before executing SQL
CREATE OR REPLACE FUNCTION rag.validate_sql(p_sql TEXT)
RETURNS TABLE (
    guard_type  TEXT,
    pattern     TEXT,
    message     TEXT
)
LANGUAGE plpgsql AS $$
BEGIN
    RETURN QUERY
    SELECT g.guard_type, g.pattern, g.message
    FROM rag.sql_guard g
    WHERE
        (g.guard_mode = 'exact'    AND p_sql = g.pattern)
     OR (g.guard_mode = 'contains' AND p_sql ILIKE '%' || g.pattern || '%')
     OR (g.guard_mode = 'regex'    AND p_sql ~* g.pattern);
END;
$$;


-- ================================================================
-- 16. SCHEMA AUTO-SYNC PROCEDURE
-- ================================================================

CREATE OR REPLACE PROCEDURE rag.sync_schema_docs()
LANGUAGE plpgsql AS $$
DECLARE
    r         RECORD;
    v_content TEXT;
    v_doc_id  BIGINT;
BEGIN
    FOR r IN
        SELECT
            c.table_schema || '.' || c.table_name AS full_table,
            c.table_name,
            c.table_schema,
            STRING_AGG(
                c.column_name || ' (' || c.data_type
                    || COALESCE(' - ' || pgd.description, '') || ')',
                E'\n'
                ORDER BY c.ordinal_position
            ) AS columns_desc
        FROM information_schema.columns c
        LEFT JOIN pg_catalog.pg_statio_all_tables st
            ON st.schemaname = c.table_schema
            AND st.relname   = c.table_name
        LEFT JOIN pg_catalog.pg_description pgd
            ON pgd.objoid    = st.relid
            AND pgd.objsubid = c.ordinal_position
        WHERE c.table_schema IN ('ecommerce', 'ml_output', 'marketing')
        GROUP BY c.table_schema, c.table_name
    LOOP
        v_content := 'Auto-synced schema: ' || r.full_table
                     || E'\n\n' || r.columns_desc;

        SELECT doc_id INTO v_doc_id
        FROM rag.documents
        WHERE source_type = 'schema_doc'
          AND source_id   = r.full_table
          AND is_active   = TRUE;

        IF FOUND THEN
            UPDATE rag.documents
            SET content    = v_content,
                updated_at = NOW()
            WHERE doc_id = v_doc_id;
        ELSE
            INSERT INTO rag.documents
                (source_type, source_id, title, content,
                 embedding_type, priority, retrieval_weight)
            VALUES
                ('schema_doc', r.full_table,
                 'Auto Schema: ' || r.full_table,
                 v_content, 'schema', 6, 0.8);
        END IF;
    END LOOP;

    RAISE NOTICE 'Schema sync complete at %', NOW();
END;
$$;


-- ================================================================
-- 17. HYBRID SEARCH FUNCTION (BM25 + Vector)
-- ================================================================

-- ----------------------------------------------------------------
-- FIX-1 applied: all three search functions now return
--   SETOF rag.search_result_t instead of RETURNS TABLE LIKE ...
-- ----------------------------------------------------------------

CREATE OR REPLACE FUNCTION rag.hybrid_search(
    p_query          TEXT,
    p_source_types   rag.rag_source_t[]  DEFAULT NULL,
    p_embedding      VECTOR(1536)        DEFAULT NULL,
    p_top_k          INTEGER             DEFAULT 8,
    p_vector_weight  NUMERIC             DEFAULT 0.6,
    p_bm25_weight    NUMERIC             DEFAULT 0.4
)
RETURNS SETOF rag.search_result_t
LANGUAGE plpgsql AS $$ BEGIN
    RETURN QUERY
    WITH bm25_results AS (
        SELECT d.doc_id,
               ts_rank_cd(d.content_tsv, plainto_tsquery('arabic', p_query) || plainto_tsquery('english', p_query)) AS bm25_score
        FROM rag.documents d
        WHERE d.is_active = TRUE
          AND (p_source_types IS NULL OR d.source_type = ANY(p_source_types))
          AND d.content_tsv @@ (plainto_tsquery('arabic', p_query) || plainto_tsquery('english', p_query))
        ORDER BY bm25_score DESC LIMIT p_top_k * 3
    ),
    vector_results AS (
        SELECT e.doc_id,
               CASE WHEN p_embedding IS NOT NULL THEN (1 - (e.embedding <=> p_embedding))::REAL ELSE 0.0::REAL END AS vector_score
        FROM (
            SELECT doc_id, embedding FROM rag.schema_embeddings
            UNION ALL SELECT doc_id, embedding FROM rag.business_embeddings
            UNION ALL SELECT doc_id, embedding FROM rag.metrics_embeddings
            UNION ALL SELECT doc_id, embedding FROM rag.review_embeddings
        ) e
        JOIN rag.documents d ON e.doc_id = d.doc_id
        WHERE d.is_active = TRUE
          AND (p_source_types IS NULL OR d.source_type = ANY(p_source_types))
        ORDER BY vector_score DESC LIMIT p_top_k * 3
    ),
    combined AS (
        SELECT COALESCE(b.doc_id, v.doc_id) AS doc_id,
               COALESCE(b.bm25_score, 0) AS bm25_score,
               COALESCE(v.vector_score, 0) AS vector_score
        FROM bm25_results b FULL OUTER JOIN vector_results v ON b.doc_id = v.doc_id
    ),
    -- 🔥 FIX: Rank within each source_type to prevent noise domination
    ranked_results AS (
        SELECT 
            d.doc_id,
            d.source_type,
            c.bm25_score,
            c.vector_score,
            ((p_bm25_weight * c.bm25_score + p_vector_weight * c.vector_score) * d.retrieval_weight) AS hybrid_score,
            -- بندي Rank لكل Type لوحده
            ROW_NUMBER() OVER(PARTITION BY d.source_type ORDER BY ((p_bm25_weight * c.bm25_score + p_vector_weight * c.vector_score) * d.retrieval_weight) DESC) as type_rank
        FROM combined c
        JOIN rag.documents d ON c.doc_id = d.doc_id
        WHERE d.is_active = TRUE
    )
    SELECT
        r.doc_id,
        r.source_type,
        d.title,
        d.content,
        d.metadata,
        r.bm25_score::REAL,
        r.vector_score::REAL,
        r.hybrid_score::REAL,
        d.priority,
        d.retrieval_weight
    FROM ranked_results r
    JOIN rag.documents d ON r.doc_id = d.doc_id
    -- بنسمح بأقصى 2 document من كل Type في الـ Top Results
    WHERE r.type_rank <= 2  
    ORDER BY r.hybrid_score DESC, d.priority DESC
    LIMIT p_top_k;
END;
 $$;

-- Analytics search: excludes reviews to prevent review dominance
CREATE OR REPLACE FUNCTION rag.search_analytics(
    p_query     TEXT,
    p_embedding VECTOR(1536) DEFAULT NULL,
    p_top_k     INTEGER      DEFAULT 8
)
RETURNS SETOF rag.search_result_t     -- FIX-1: was "RETURNS TABLE LIKE rag.hybrid_search"
LANGUAGE sql AS $$
    SELECT * FROM rag.hybrid_search(
        p_query,
        ARRAY[
            'schema_doc', 'leakage_scenario', 'sql_template',
            'kpi_glossary', 'join_graph', 'anti_pattern',
            'routing_hint', 'enum_reference', 'generated_column',
            'metric_definition', 'lineage_doc', 'anomaly_interpretation',
            'summary_profile'
        ]::rag.rag_source_t[],
        p_embedding,
        p_top_k
    );
$$;

-- Review-only search (sentiment analysis path)
CREATE OR REPLACE FUNCTION rag.search_reviews(
    p_query     TEXT,
    p_embedding VECTOR(1536) DEFAULT NULL,
    p_top_k     INTEGER      DEFAULT 5
)
RETURNS SETOF rag.search_result_t     -- FIX-1: was "RETURNS TABLE LIKE rag.hybrid_search"
LANGUAGE sql AS $$
    SELECT * FROM rag.hybrid_search(
        p_query,
        ARRAY['review']::rag.rag_source_t[],
        p_embedding,
        p_top_k
    );
$$;


-- ================================================================
-- 18. RETRIEVAL CACHE FUNCTIONS
-- ================================================================

CREATE OR REPLACE FUNCTION rag.get_cached_result(p_query_hash TEXT)
RETURNS JSONB
LANGUAGE sql AS $$
    SELECT result_json
    FROM rag.retrieval_cache
    WHERE query_hash = p_query_hash
      AND expires_at > NOW()
    LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION rag.set_cached_result(
    p_query_hash TEXT,
    p_query      TEXT,
    p_result     JSONB
)
RETURNS VOID
LANGUAGE sql AS $$
    INSERT INTO rag.retrieval_cache (cache_key, query_hash, result_json)
    VALUES (p_query_hash, p_query_hash, p_result)
    ON CONFLICT (cache_key) DO UPDATE
    SET result_json = EXCLUDED.result_json,
        hit_count   = rag.retrieval_cache.hit_count + 1,
        expires_at  = NOW() + INTERVAL '24 hours';
$$;


-- ================================================================
-- 19. PENDING EMBEDDING VIEW
-- ================================================================

CREATE VIEW rag.v_pending_embedding AS
SELECT doc_id, source_type, embedding_type, title, updated_at
FROM rag.documents
WHERE needs_reembedding = TRUE
  AND is_active         = TRUE
ORDER BY priority DESC, updated_at DESC;


-- ================================================================
-- 20. VERIFICATION QUERIES
-- ================================================================

-- Document count by source_type with quality metrics
SELECT
    source_type,
    COUNT(*)                               AS doc_count,
    AVG(priority)::NUMERIC(4,1)            AS avg_priority,
    AVG(retrieval_weight)::NUMERIC(4,2)    AS avg_weight,
    COUNT(*) FILTER (WHERE priority >= 9)  AS high_priority_count
FROM rag.documents
GROUP BY source_type
ORDER BY doc_count DESC;

-- Verify all leakage scenarios have detection columns documented
SELECT
    source_id                             AS scenario,
    metadata->>'detection_columns'        AS detection_cols,
    metadata->>'preferred_view'           AS preferred_view
FROM rag.documents
WHERE source_type = 'leakage_scenario'
ORDER BY priority DESC;

-- Confirm sql_guard rules are loaded with correct modes
SELECT guard_type, guard_mode, COUNT(*)
FROM rag.sql_guard
GROUP BY guard_type, guard_mode
ORDER BY guard_type;

-- Test validate_sql function (should flag the bad patterns)
SELECT * FROM rag.validate_sql(
    'SELECT SUM(orders.amount) FROM ecommerce.payments WHERE order_id = ''X'''
);

-- Confirm single merged trigger exists (not two separate ones)
SELECT tgname, tgtype, proname
FROM pg_trigger t
JOIN pg_proc p ON t.tgfoid = p.oid
WHERE tgrelid = 'rag.documents'::regclass
ORDER BY tgname;

-- Top documents by retrieval weight
SELECT source_type, title, priority, retrieval_weight
FROM rag.documents
ORDER BY retrieval_weight DESC, priority DESC
LIMIT 20;

-- Pending re-embedding queue
SELECT source_type, COUNT(*) AS pending
FROM rag.v_pending_embedding
GROUP BY source_type
ORDER BY pending DESC;



ALTER TABLE rag.schema_embeddings ALTER COLUMN embedding TYPE VECTOR(1024);
ALTER TABLE rag.business_embeddings ALTER COLUMN embedding TYPE VECTOR(1024);
ALTER TABLE rag.metrics_embeddings ALTER COLUMN embedding TYPE VECTOR(1024);
ALTER TABLE rag.review_embeddings ALTER COLUMN embedding TYPE VECTOR(1024);


SELECT * FROM rag.v_pending_embedding LIMIT 1;
