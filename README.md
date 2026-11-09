# Fraud Monitoring in Snowflake

A small end-to-end project built in Snowflake to practice **advanced SQL**, **Snowflake engineering** and **Semantic Views**. It generates synthetic banking transactions with planted fraud patterns, detects them with SQL rules, scores customer risk, and exposes governed business metrics through a Semantic View that can be queried in plain English with Cortex Analyst.

All data is synthetic and generated inside Snowflake with SQL. No real customer data is used.

## Architecture

```
RAW                      ANALYTICS                          MART
---------------          ------------------------------     ---------------------
CUSTOMERS                TRANSACTION_FLAGS (view)           SV_FRAUD_ANALYTICS
ACCOUNTS         ---->   FACT_TRANSACTIONS (view)   ---->   (Semantic View)
TRANSACTIONS             CUSTOMER_RISK_SUMMARY (dynamic
FRAUD_CASES              table)
                         ALERTS (filled by Stream + Task)
```

## What it demonstrates

| Area | What is in the project |
|---|---|
| Advanced SQL | Window functions (`LAG`, `AVG`/`STDDEV OVER`, `RANK`), time-range window frames, `QUALIFY`, deduplication with `ROW_NUMBER`, conditional aggregation |
| Snowflake engineering | Data generation with `GENERATOR`, a Stream and Task for incremental alerts, a Dynamic Table for customer risk, views as a rules layer |
| Governance | A read-only `FRAUD_ANALYST` role with access to analytics and mart schemas but not raw customer data |
| Semantic layer | `SV_FRAUD_ANALYTICS` with relationships, facts, dimensions, synonyms, descriptions and a verified query |

## Data

Generated in SQL: 1,000 customers, 1,000 accounts, 50,150 transactions and 105 fraud cases. Two fraud patterns are planted so the detection queries have something to find:

- **Rapid card testing:** customers 1-20 make five purchases one minute apart.
- **Large purchases:** customers 101-150 make one very large purchase.

Confirmed fraud cases exist for customers 1-15 and 101-130.

## Detection and risk scoring

Per transaction (`ANALYTICS.TRANSACTION_FLAGS`):

- `FLAG_RAPID`: at most 2 minutes since the same customer's previous transaction
- `FLAG_HIGH_AMOUNT`: amount of 5,000 or more

Per customer (`ANALYTICS.CUSTOMER_RISK_SUMMARY`, a dynamic table):

- Score = 10 per rapid flag + 50 per high-amount flag + 25 per fraud case, capped at 100
- Bands: HIGH (70 and above), MEDIUM (30 to 69), LOW (below 30)

## Semantic View metrics

| Metric | Meaning |
|---|---|
| `total_transaction_value` | Sum of transaction amounts |
| `transaction_count` | Number of transactions |
| `suspicious_transaction_count` | Transactions that tripped a fraud rule |
| `total_fraud_loss` | Sum of confirmed fraud losses |
| `fraud_loss_ratio` | Fraud loss divided by transaction value |
| `high_risk_customers` | Customers in the HIGH band |
| `average_risk_score` | Average customer risk score |

## Verified results

Results from SQL and from Cortex Analyst (plain English) agreed:

- **High-risk customers by segment:** PREMIUM 13, RETAIL 14, SME 18 (45 total, matching the planted data).
- **Country with the highest fraud loss ratio:** Germany at about 0.0606. The ranking between countries is small and driven by random data, so it is not a real-world finding.

## How to run

1. Create a Snowflake account (a trial works).
2. Open a SQL file in Snowsight and paste `fraud_project.sql`.
3. Run it **one part at a time** (highlight a part, click Run). Parts 0 to 7 build everything in order.
4. Open Cortex Analyst (AI & ML), pick `FINANCIAL_RISK_DB.MART.SV_FRAUD_ANALYTICS` and ask questions such as "How many high-risk customers are in each segment?"

The script uses an X-Small warehouse with a 60-second auto-suspend. The Task and Dynamic Table consume credits while active, so suspend them when you finish:

```sql
ALTER TASK ANALYTICS.FLAG_NEW_TRANSACTIONS SUSPEND;
ALTER DYNAMIC TABLE ANALYTICS.CUSTOMER_RISK_SUMMARY SUSPEND;
```

ormance tuning
