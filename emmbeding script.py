import psycopg2
import requests
import json
import time
import logging
from psycopg2.extras import execute_values

# ==========================================
# 1. Logging Configuration
# ==========================================
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s"
)

# ==========================================
# 2. Configuration
# ==========================================
JINA_API_KEY = " put your api key"
JINA_URL = "https://api.jina.ai/v1/embeddings"
JINA_MODEL = "jina-embeddings-v5-text-small"

DB_CONFIG = {
    "dbname": "revenue_leakage",
    "user": "postgres",
    "password": "postgres",
    "host": "localhost",
    "port": "5433"
}

BATCH_SIZE = 50      # Number of documents to send per API call
MAX_RETRIES = 3      # Max retries for API failures/rate limits
API_DELAY = 0.5      # Delay between batches to respect rate limits

# Maps embedding_type from the database to the target vector table
EMBEDDING_TABLE_MAP = {
    'schema': 'rag.schema_embeddings',
    'business_rule': 'rag.business_embeddings',
    'metric': 'rag.metrics_embeddings',
    'review': 'rag.review_embeddings',
    'sql_template': 'rag.schema_embeddings',
    'routing': 'rag.schema_embeddings',
    'glossary': 'rag.metrics_embeddings',
    'lineage': 'rag.metrics_embeddings'
}

# ==========================================
# 3. API Session Setup (Faster)
# ==========================================
session = requests.Session()
session.headers.update({
    "Content-Type": "application/json",
    "Authorization": f"Bearer {JINA_API_KEY}"
})

# ==========================================
# 4. API Call with Retry Logic
# ==========================================
def get_embeddings(texts):
    payload = {
        "model": JINA_MODEL,
        "task": "retrieval.passage",  # Use 'passage' for storing documents
        "normalized": True,
        "input": texts
    }

    for attempt in range(MAX_RETRIES):
        try:
            res = session.post(JINA_URL, data=json.dumps(payload))

            if res.status_code == 200:
                data = res.json()
                # Sort by index to ensure order matches input
                sorted_data = sorted(data["data"], key=lambda x: x["index"])
                return [item["embedding"] for item in sorted_data]

            elif res.status_code == 429:
                wait = 2 ** attempt  # Exponential backoff
                logging.warning(f"Rate limit hit. Sleeping for {wait}s...")
                time.sleep(wait)

            else:
                logging.error(f"API error {res.status_code}: {res.text}")
                time.sleep(2)

        except Exception as e:
            logging.error(f"Request failed: {e}")
            time.sleep(2)

    return None

# ==========================================
# 5. Database Connection & Fetch
# ==========================================
conn = psycopg2.connect(**DB_CONFIG)
cursor = conn.cursor()

# FIX: Querying the base table directly instead of the limited view
# to ensure we get 'content' and 'priority' columns
cursor.execute("""
    SELECT doc_id, source_type, embedding_type, title, content 
    FROM rag.documents
    WHERE needs_reembedding = TRUE AND is_active = TRUE
    ORDER BY priority DESC
""")

pending_docs = cursor.fetchall()
logging.info(f"Found {len(pending_docs)} documents pending embedding.")

# ==========================================
# 6. Processing Loop
# ==========================================
total_processed = 0
failed_batches = 0
embedding_dim = None

for i in range(0, len(pending_docs), BATCH_SIZE):

    batch = pending_docs[i:i + BATCH_SIZE]

    # Combine title and content for richer context
    texts = [
        f"{title}\n\n{content}"
        for _, _, _, title, content in batch
    ]

    embeddings = get_embeddings(texts)

    if not embeddings:
        logging.error(f"Batch {i//BATCH_SIZE + 1} failed completely after retries.")
        failed_batches += 1
        continue

    # Detect vector dimension once from the first successful response
    if embedding_dim is None:
        embedding_dim = len(embeddings[0])
        logging.info(f"Embedding dimension detected: {embedding_dim}")

    # Prepare data for bulk inserts, grouped by target table
    insert_map = {}

    for idx, doc in enumerate(batch):
        doc_id, source_type, embedding_type, title, content = doc
        vector = embeddings[idx]

        # Validate vector dimension
        if len(vector) != embedding_dim:
            logging.warning(f"Skipping doc {doc_id} due to dimension mismatch.")
            continue

        table = EMBEDDING_TABLE_MAP.get(embedding_type, "rag.schema_embeddings")

        if table not in insert_map:
            insert_map[table] = []

        # Format vector as string: [0.1,0.2,...]
        vector_str = "[" + ",".join(map(str, vector)) + "]"

        insert_map[table].append((doc_id, vector_str))

    # Execute database operations
    try:
        # 1. Bulk insert vectors into their respective tables
        for table_name, rows in insert_map.items():
            execute_values(
                cursor,
                f"""
                INSERT INTO {table_name} (doc_id, embedding)
                VALUES %s
                ON CONFLICT (doc_id)
                DO UPDATE SET embedding = EXCLUDED.embedding,
                              created_at = NOW();
                """,
                rows
            )

        # 2. Bulk update the needs_reembedding flag
        doc_ids = tuple(doc[0] for doc in batch)
        
        if doc_ids:
            # Use IN clause for bulk update instead of execute_values
            cursor.execute(
                """
                UPDATE rag.documents
                SET needs_reembedding = FALSE
                WHERE doc_id IN %s;
                """,
                (doc_ids,)  # Must be a tuple inside a tuple for psycopg2
            )

        conn.commit()

        total_processed += len(batch)
        logging.info(
            f"Batch {i//BATCH_SIZE + 1} done | "
            f"Processed: {total_processed}/{len(pending_docs)}"
        )

        time.sleep(API_DELAY)

    except Exception as e:
        conn.rollback()
        failed_batches += 1
        logging.error(f"DB Error in batch {i//BATCH_SIZE + 1}: {e}")

# ==========================================
# 7. Cleanup & Final Report
# ==========================================
cursor.close()
conn.close()

logging.info("=" * 30)
logging.info("EMBEDDING PROCESS COMPLETE")
logging.info(f"Total successfully processed: {total_processed}")
logging.info(f"Total failed batches: {failed_batches}")
logging.info("=" * 30)