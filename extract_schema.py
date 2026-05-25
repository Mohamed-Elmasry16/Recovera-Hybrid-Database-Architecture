import json
import os
from pathlib import Path

import pandas as pd
from sqlalchemy import create_engine, text

# =============================================================================
# CONFIG  — edit these
# =============================================================================

DB_CONFIG = {
    "host":     "localhost",
    "port":     5433,
    "database": "revenue_leakage",
    "user":     "postgres",          # use superuser for schema extraction
    "password": "postgres",
}

OUTPUT_DIR        = "schema_output"
SAMPLE_ROWS_LIMIT = 3                # rows per table in sample (keep small)

EXCLUDED_SCHEMAS = (
    "pg_catalog",
    "information_schema",
    "pg_toast",
)

# Tables where we skip sample rows (sensitive or huge binary columns)
SKIP_SAMPLES = {
    "rag.chunks",          # embedding vector column breaks JSON
}

# =============================================================================
# SETUP
# =============================================================================

conn_str = (
    f"postgresql+psycopg2://"
    f"{DB_CONFIG['user']}:{DB_CONFIG['password']}@"
    f"{DB_CONFIG['host']}:{DB_CONFIG['port']}/{DB_CONFIG['database']}"
)
engine = create_engine(conn_str)
Path(OUTPUT_DIR).mkdir(parents=True, exist_ok=True)


def q(sql: str) -> pd.DataFrame:
    with engine.connect() as conn:
        return pd.read_sql(text(sql), conn)


def save(data, filename: str):
    path = os.path.join(OUTPUT_DIR, filename)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False, default=str)
    print(f"  [✓] {path}")


# =============================================================================
# 1. TABLES
# =============================================================================
print("\n[1] Tables...")

tables_df = q(f"""
    SELECT table_schema, table_name
    FROM information_schema.tables
    WHERE table_schema NOT IN {EXCLUDED_SCHEMAS}
      AND table_type = 'BASE TABLE'
    ORDER BY table_schema, table_name
""")
save(tables_df.to_dict("records"), "tables.json")

# =============================================================================
# 2. COLUMNS  (with comments + generated flag)
# =============================================================================
print("\n[2] Columns + comments + generated flag...")

columns_df = q(f"""
    SELECT
        c.table_schema,
        c.table_name,
        c.column_name,
        c.data_type,
        c.udt_name,                          -- enum type name lives here
        c.is_nullable,
        c.column_default,
        c.ordinal_position,
        c.is_generated,                      -- 'ALWAYS' if GENERATED column
        c.generation_expression,
        pg_catalog.col_description(
            (c.table_schema||'.'||c.table_name)::regclass::oid,
            c.ordinal_position
        ) AS column_comment                  -- FIX-3: captures your COMMENT ON COLUMN
    FROM information_schema.columns c
    WHERE c.table_schema NOT IN {EXCLUDED_SCHEMAS}
    ORDER BY c.table_schema, c.table_name, c.ordinal_position
""")
save(columns_df.to_dict("records"), "columns.json")

# =============================================================================
# 3. TABLE COMMENTS
# =============================================================================
print("\n[3] Table comments...")

table_comments_df = q(f"""
    SELECT
        n.nspname   AS table_schema,
        c.relname   AS table_name,
        obj_description(c.oid, 'pg_class') AS table_comment
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind = 'r'
      AND n.nspname NOT IN {EXCLUDED_SCHEMAS}
      AND obj_description(c.oid, 'pg_class') IS NOT NULL
    ORDER BY n.nspname, c.relname
""")
save(table_comments_df.to_dict("records"), "table_comments.json")

# =============================================================================
# 4. PRIMARY KEYS
# =============================================================================
print("\n[4] Primary keys...")

pk_df = q("""
    SELECT
        tc.table_schema, tc.table_name,
        kcu.column_name, tc.constraint_name
    FROM information_schema.table_constraints tc
    JOIN information_schema.key_column_usage kcu
        ON tc.constraint_name = kcu.constraint_name
        AND tc.table_schema   = kcu.table_schema
    WHERE tc.constraint_type = 'PRIMARY KEY'
    ORDER BY tc.table_schema, tc.table_name
""")
save(pk_df.to_dict("records"), "primary_keys.json")

# =============================================================================
# 5. FOREIGN KEYS
# =============================================================================
print("\n[5] Foreign keys...")

fk_df = q("""
    SELECT
        tc.table_schema, tc.table_name, kcu.column_name,
        ccu.table_schema AS ref_schema,
        ccu.table_name   AS ref_table,
        ccu.column_name  AS ref_column
    FROM information_schema.table_constraints   tc
    JOIN information_schema.key_column_usage    kcu
        ON tc.constraint_name = kcu.constraint_name
        AND tc.table_schema   = kcu.table_schema
    JOIN information_schema.constraint_column_usage ccu
        ON ccu.constraint_name = tc.constraint_name
    WHERE tc.constraint_type = 'FOREIGN KEY'
    ORDER BY tc.table_schema, tc.table_name
""")
save(fk_df.to_dict("records"), "foreign_keys.json")

# =============================================================================
# 6. ENUMS  — FIX-2: original script missed this entirely
# =============================================================================
print("\n[6] ENUM types...")

enums_df = q("""
    SELECT
        n.nspname                   AS enum_schema,
        t.typname                   AS enum_name,
        array_agg(e.enumlabel
            ORDER BY e.enumsortorder) AS enum_values
    FROM pg_type        t
    JOIN pg_enum        e ON e.enumtypid = t.oid
    JOIN pg_namespace   n ON n.oid       = t.typnamespace
    GROUP BY n.nspname, t.typname
    ORDER BY n.nspname, t.typname
""")
save(enums_df.to_dict("records"), "enums.json")
print(f"  Found {len(enums_df)} ENUM types")

# =============================================================================
# 7. INDEXES  (partial indexes flagged — your DB uses them heavily)
# =============================================================================
print("\n[7] Indexes...")

indexes_df = q(f"""
    SELECT
        schemaname, tablename, indexname,
        indexdef,
        CASE WHEN indexdef LIKE '%WHERE%' THEN true ELSE false END AS is_partial
    FROM pg_indexes
    WHERE schemaname NOT IN {EXCLUDED_SCHEMAS}
    ORDER BY schemaname, tablename, indexname
""")
save(indexes_df.to_dict("records"), "indexes.json")

# =============================================================================
# 8. VIEWS
# =============================================================================
print("\n[8] Views...")

views_df = q(f"""
    SELECT schemaname, viewname, definition
    FROM pg_views
    WHERE schemaname NOT IN {EXCLUDED_SCHEMAS}
    ORDER BY schemaname, viewname
""")
save(views_df.to_dict("records"), "views.json")

# =============================================================================
# 9. MATERIALIZED VIEWS  (with column list — original missed columns)
# =============================================================================
print("\n[9] Materialized views + columns...")

matviews_df = q("""
    SELECT
        mv.schemaname, mv.matviewname,
        array_agg(a.attname ORDER BY a.attnum) AS columns,
        obj_description(c.oid, 'pg_class')     AS mv_comment
    FROM pg_matviews mv
    JOIN pg_class c
        ON c.relname   = mv.matviewname
    JOIN pg_namespace n
        ON n.nspname   = mv.schemaname
        AND n.oid      = c.relnamespace
    JOIN pg_attribute a
        ON a.attrelid  = c.oid
        AND a.attnum   > 0
        AND NOT a.attisdropped
    GROUP BY mv.schemaname, mv.matviewname, c.oid
    ORDER BY mv.schemaname, mv.matviewname
""")
save(matviews_df.to_dict("records"), "materialized_views.json")

# =============================================================================
# 10. ROW COUNTS  — FIX-1: use pg_stat estimates (instant, vs COUNT(*) minutes)
# =============================================================================
print("\n[10] Row counts (fast estimates)...")

row_counts_df = q(f"""
    SELECT
        schemaname  AS schema,
        relname     AS table_name,
        n_live_tup  AS estimated_rows
    FROM pg_stat_user_tables
    WHERE schemaname NOT IN {EXCLUDED_SCHEMAS}
    ORDER BY schemaname, relname
""")
save(row_counts_df.to_dict("records"), "row_counts.json")

# =============================================================================
# 11. SAMPLE ROWS  (skip vector tables)
# =============================================================================
print("\n[11] Sample rows (non-vector tables)...")

# Columns that hold vector data — skip them in samples
VECTOR_COLS = {"embedding"}

samples = {}
with engine.connect() as conn:
    for _, row in tables_df.iterrows():
        schema, table = row["table_schema"], row["table_name"]
        key = f"{schema}.{table}"

        if key in SKIP_SAMPLES:
            print(f"  [skip] {key} (vector table)")
            continue

        # Find non-vector columns for this table
        tbl_cols = columns_df[
            (columns_df["table_schema"] == schema) &
            (columns_df["table_name"]   == table)
        ]
        safe_cols = [
            f'"{c}"'
            for c in tbl_cols["column_name"]
            if c not in VECTOR_COLS and tbl_cols[
                tbl_cols["column_name"] == c
            ]["udt_name"].values[0] != "vector"
        ]

        if not safe_cols:
            continue

        try:
            sql = (
                f'SELECT {", ".join(safe_cols)} '
                f'FROM "{schema}"."{table}" '
                f'LIMIT {SAMPLE_ROWS_LIMIT}'
            )
            df = pd.read_sql(text(sql), conn)
            samples[key] = df.to_dict("records")
            print(f"  {key}: {len(df)} rows")
        except Exception as e:
            print(f"  [ERROR] {key}: {e}")

save(samples, "sample_rows.json")

# =============================================================================
# 12. PULL YOUR EXISTING CONTEXT TABLES  (schema_metadata + chatbot_enums)
# =============================================================================
print("\n[12] Pulling ml_output.schema_metadata & chatbot_enums...")

try:
    meta_df  = q("SELECT * FROM ml_output.schema_metadata ORDER BY table_schema, table_name")
    enums2_df = q("SELECT * FROM ml_output.chatbot_enums   ORDER BY enum_name, enum_value")
    save(meta_df.to_dict("records"),   "schema_metadata.json")
    save(enums2_df.to_dict("records"), "chatbot_enums.json")
    print(f"  schema_metadata: {len(meta_df)} tables")
    print(f"  chatbot_enums:   {len(enums2_df)} values")
except Exception as e:
    print(f"  [WARN] Could not pull context tables: {e}")

# =============================================================================
# 13. COMPACT LLM FORMAT  (this is what the agent loads at runtime)
#     One token-efficient string with everything the LLM needs
# =============================================================================
print("\n[13] Building compact LLM schema context...")

# Build enum lookup: {udt_name: [values]}
enum_lookup = {}
for _, row in enums_df.iterrows():
    enum_lookup[row["enum_name"]] = row["enum_values"]

# Build FK lookup
fk_by_table = {}
for _, fk in fk_df.iterrows():
    k = f"{fk['table_schema']}.{fk['table_name']}"
    fk_by_table.setdefault(k, []).append(
        f"{fk['column_name']} → {fk['ref_schema']}.{fk['ref_table']}.{fk['ref_column']}"
    )

# Build table comment lookup
tc_lookup = {
    f"{r['table_schema']}.{r['table_name']}": r["table_comment"]
    for _, r in table_comments_df.iterrows()
}

# Build row count lookup
rc_lookup = {
    f"{r['schema']}.{r['table_name']}": r["estimated_rows"]
    for _, r in row_counts_df.iterrows()
}

# Build MV column lookup
mv_lookup = {
    f"{r['schemaname']}.{r['matviewname']}": r["columns"]
    for _, r in matviews_df.iterrows()
}

# ── Render compact format ─────────────────────────────────────
lines = ["# DATABASE SCHEMA — Revenue Leakage Platform\n"]
lines.append("All money in EGP. Read-only access. Primary join key: order_id\n")

# Group columns by table
col_grouped = columns_df.groupby(["table_schema", "table_name"])

# ── BASE TABLES ───────────────────────────────────────────────
lines.append("\n## BASE TABLES\n")

for (schema, table), grp in col_grouped:
    key   = f"{schema}.{table}"
    count = rc_lookup.get(key, "?")
    tc    = tc_lookup.get(key, "")
    lines.append(f"### {key}  (~{count:,} rows)" if isinstance(count, int)
                 else f"### {key}")
    if tc:
        lines.append(f"_{tc}_")

    for _, col in grp.iterrows():
        udt     = col["udt_name"]
        dtype   = col["data_type"]
        gen     = " [GENERATED]" if col["is_generated"] == "ALWAYS" else ""
        comment = f"  // {col['column_comment']}" if col["column_comment"] else ""
        null    = "" if col["is_nullable"] == "YES" else " NOT NULL"

        # Inline enum values
        if udt in enum_lookup:
            vals = " | ".join(f"'{v}'" for v in enum_lookup[udt])
            lines.append(f"  - {col['column_name']}: ENUM({vals}){null}{gen}{comment}")
        else:
            lines.append(f"  - {col['column_name']}: {dtype}{null}{gen}{comment}")

    # FKs
    if key in fk_by_table:
        lines.append("  FK:")
        for fk in fk_by_table[key]:
            lines.append(f"    {fk}")

    # Sample rows
    if key in samples and samples[key]:
        lines.append(f"  Sample ({min(2, len(samples[key]))} rows):")
        for r in samples[key][:2]:
            # Trim long text values
            trimmed = {
                k: (str(v)[:60] + "…" if isinstance(v, str) and len(str(v)) > 60 else v)
                for k, v in r.items()
            }
            lines.append(f"    {json.dumps(trimmed, ensure_ascii=False, default=str)}")

    lines.append("")

# ── MATERIALIZED VIEWS ────────────────────────────────────────
lines.append("\n## MATERIALIZED VIEWS  (prefer these for chatbot queries)\n")

for _, mv in matviews_df.iterrows():
    key = f"{mv['schemaname']}.{mv['matviewname']}"
    count = rc_lookup.get(key, "?")
    comment = mv.get("mv_comment") or ""
    lines.append(f"### {key}  (~{count:,} rows)" if isinstance(count, int)
                 else f"### {key}")
    if comment:
        lines.append(f"_{comment}_")
    cols = mv["columns"]
    if cols:
        lines.append("  Columns: " + ", ".join(cols))
    lines.append("")

# ── ENUMS ─────────────────────────────────────────────────────
lines.append("\n## ENUM TYPES\n")
for _, row in enums_df.iterrows():
    vals = " | ".join(f"'{v}'" for v in row["enum_values"])
    lines.append(f"- {row['enum_name']}: {vals}")

compact_text = "\n".join(lines)

# Save as text (loaded by agent at startup)
compact_path = os.path.join(OUTPUT_DIR, "llm_schema_context.txt")
with open(compact_path, "w", encoding="utf-8") as f:
    f.write(compact_text)
print(f"  [✓] {compact_path}")
print(f"  Size: {len(compact_text):,} chars  (~{len(compact_text)//4:,} tokens)")

# =============================================================================
# 14. RAG DOCUMENTS  (richer than original)
# =============================================================================
print("\n[14] Building RAG documents...")

documents = []

for (schema, table), grp in col_grouped:
    key = f"{schema}.{table}"
    tc  = tc_lookup.get(key, "")

    doc = [f"# Table: {key}"]
    if tc:
        doc.append(f"Description: {tc}\n")

    doc.append("## Columns")
    for _, col in grp.iterrows():
        udt     = col["udt_name"]
        gen_tag = " [GENERATED — do not filter on directly]" if col["is_generated"] == "ALWAYS" else ""
        comment = f" — {col['column_comment']}" if col["column_comment"] else ""
        if udt in enum_lookup:
            vals = ", ".join(f"'{v}'" for v in enum_lookup[udt])
            doc.append(f"- {col['column_name']} ENUM: {vals}{gen_tag}{comment}")
        else:
            doc.append(f"- {col['column_name']} ({col['data_type']}){gen_tag}{comment}")

    if key in fk_by_table:
        doc.append("\n## Foreign Keys")
        for fk in fk_by_table[key]:
            doc.append(f"- {fk}")

    if key in samples and samples[key]:
        doc.append("\n## Sample Rows")
        for r in samples[key][:2]:
            doc.append(json.dumps(r, ensure_ascii=False, default=str))

    documents.append({"table": key, "content": "\n".join(doc)})

# Add MV docs
for _, mv in matviews_df.iterrows():
    key     = f"{mv['schemaname']}.{mv['matviewname']}"
    comment = mv.get("mv_comment") or ""
    cols    = mv["columns"] or []
    doc = [
        f"# Materialized View: {key}",
        f"Description: {comment}" if comment else "",
        f"Columns: {', '.join(cols)}" if cols else "",
    ]
    documents.append({"table": key, "content": "\n".join(doc)})

save(documents, "rag_documents.json")

# Markdown
md_path = os.path.join(OUTPUT_DIR, "DATABASE_DOCUMENTATION.md")
with open(md_path, "w", encoding="utf-8") as f:
    f.write("# Database Documentation\n\n")
    for doc in documents:
        f.write(doc["content"] + "\n\n---\n\n")
print(f"  [✓] {md_path}")

# =============================================================================
# DONE
# =============================================================================
print("\n" + "=" * 70)
print("DONE")
print("=" * 70)
print(f"""
Generated Files:
  tables.json                  — all base tables
  columns.json                 — columns + comments + generated flag
  table_comments.json          — COMMENT ON TABLE values
  primary_keys.json
  foreign_keys.json
  enums.json                   — NEW: all ENUM types & values
  indexes.json                 — partial indexes flagged
  views.json
  materialized_views.json      — now includes column list
  row_counts.json              — fast estimates (not COUNT*)
  sample_rows.json             — vector columns skipped
  schema_metadata.json         — from ml_output.schema_metadata
  chatbot_enums.json           — from ml_output.chatbot_enums
  rag_documents.json           — enriched RAG docs
  DATABASE_DOCUMENTATION.md

  ★ llm_schema_context.txt     — LOAD THIS IN YOUR AGENT
""")