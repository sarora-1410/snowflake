/* =====================================================================
   FRAUD MONITORING IN SNOWFLAKE  (simplified project)
   Snowflake + advanced SQL + Semantic Views

   HOW TO RUN
   - Paste this whole file into a new Snowsight SQL file.
   - Run ONE PART at a time: highlight the part, click Run.
   - Every part starts by setting role / warehouse / database, so you can
     run parts in separate sessions without errors.
   - If a statement errors, stop and send me the error text.
   ===================================================================== */


/* ============================== PART 0 ==============================
   ENVIRONMENT
   Expected: SHOW SCHEMAS lists RAW, ANALYTICS, MART (+ PUBLIC, etc.)
   ==================================================================== */
USE ROLE ACCOUNTADMIN;

CREATE WAREHOUSE IF NOT EXISTS FRAUD_WH
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE;

CREATE DATABASE IF NOT EXISTS FINANCIAL_RISK_DB;

USE WAREHOUSE FRAUD_WH;
USE DATABASE FINANCIAL_RISK_DB;

CREATE SCHEMA IF NOT EXISTS RAW;
CREATE SCHEMA IF NOT EXISTS ANALYTICS;
CREATE SCHEMA IF NOT EXISTS MART;

SHOW SCHEMAS IN DATABASE FINANCIAL_RISK_DB;


/* ============================== PART 1 ==============================
   CREATE THE 4 RAW TABLES
   ==================================================================== */
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE FRAUD_WH;
USE DATABASE FINANCIAL_RISK_DB;

CREATE OR REPLACE TABLE RAW.CUSTOMERS (
    CUSTOMER_ID        NUMBER(10,0),
    FIRST_NAME         VARCHAR(50),
    LAST_NAME          VARCHAR(50),
    DATE_OF_BIRTH      DATE,
    COUNTRY            VARCHAR(50),
    CUSTOMER_SEGMENT   VARCHAR(30),
    ACCOUNT_OPEN_DATE  DATE,
    CREATED_AT         TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE RAW.ACCOUNTS (
    ACCOUNT_ID      NUMBER(10,0),
    CUSTOMER_ID     NUMBER(10,0),
    ACCOUNT_TYPE    VARCHAR(20),
    ACCOUNT_STATUS  VARCHAR(20),
    OPEN_DATE       DATE,
    CREATED_AT      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE RAW.TRANSACTIONS (
    TRANSACTION_ID       NUMBER(12,0),
    ACCOUNT_ID           NUMBER(10,0),
    CUSTOMER_ID          NUMBER(10,0),
    TRANSACTION_TS       TIMESTAMP_NTZ,
    AMOUNT               NUMBER(12,2),
    CHANNEL              VARCHAR(20),
    MERCHANT_CATEGORY    VARCHAR(30),
    TRANSACTION_COUNTRY  VARCHAR(50),
    CREATED_AT           TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE RAW.FRAUD_CASES (
    CASE_ID         NUMBER(10,0),
    TRANSACTION_ID  NUMBER(12,0),
    CUSTOMER_ID     NUMBER(10,0),
    CASE_DATE       DATE,
    FRAUD_TYPE      VARCHAR(30),
    LOSS_AMOUNT     NUMBER(12,2),
    CASE_STATUS     VARCHAR(20),
    CREATED_AT      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

SHOW TABLES IN SCHEMA RAW;


/* ============================== PART 2 ==============================
   GENERATE DATA (all done in SQL, no files to upload)
   - 1,000 customers, 1,000 accounts
   - 50,000 normal transactions over the last 90 days
   - PLANTED fraud so your queries find something:
       Pattern A: customers 1-20 make 5 purchases, 1 minute apart
       Pattern B: customers 101-150 make one very large purchase
   - Fraud cases confirmed for customers 1-15 (pattern A)
     and 101-130 (pattern B)
   Expected counts: customers 1000 | accounts 1000 | transactions 50150
                    | fraud_cases 105
   ==================================================================== */
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE FRAUD_WH;
USE DATABASE FINANCIAL_RISK_DB;

-- Start clean so re-running this part does not duplicate data
TRUNCATE TABLE RAW.CUSTOMERS;
TRUNCATE TABLE RAW.ACCOUNTS;
TRUNCATE TABLE RAW.TRANSACTIONS;
TRUNCATE TABLE RAW.FRAUD_CASES;

-- 2.1 Customers
INSERT INTO RAW.CUSTOMERS
    (CUSTOMER_ID, FIRST_NAME, LAST_NAME, DATE_OF_BIRTH, COUNTRY, CUSTOMER_SEGMENT, ACCOUNT_OPEN_DATE)
SELECT
    n,
    ARRAY_CONSTRUCT('Aarav','Priya','Rahul','Sneha','John','Emma','Liam','Olivia',
                    'Chen','Mei','Ahmed','Fatima','Carlos','Sofia','Hans','Anna')
                   [UNIFORM(0, 15, RANDOM())]::VARCHAR,
    ARRAY_CONSTRUCT('Sharma','Patel','Smith','Johnson','Wang','Li','Khan','Garcia',
                    'Muller','Rossi','Singh','Brown')
                   [UNIFORM(0, 11, RANDOM())]::VARCHAR,
    DATEADD(day, -UNIFORM(7300, 23000, RANDOM()), CURRENT_DATE()),
    ARRAY_CONSTRUCT('India','USA','UK','Germany','Singapore','UAE')[MOD(n, 6)]::VARCHAR,
    ARRAY_CONSTRUCT('RETAIL','PREMIUM','SME')[UNIFORM(0, 2, RANDOM())]::VARCHAR,
    DATEADD(day, -UNIFORM(200, 2000, RANDOM()), CURRENT_DATE())
FROM (
    SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS n
    FROM TABLE(GENERATOR(ROWCOUNT => 1000))
);

-- 2.2 Accounts (one per customer)
INSERT INTO RAW.ACCOUNTS (ACCOUNT_ID, CUSTOMER_ID, ACCOUNT_TYPE, ACCOUNT_STATUS, OPEN_DATE)
SELECT 100000 + CUSTOMER_ID,
       CUSTOMER_ID,
       IFF(MOD(CUSTOMER_ID, 3) = 0, 'SAVINGS', 'CHECKING'),
       'ACTIVE',
       ACCOUNT_OPEN_DATE
FROM RAW.CUSTOMERS;

-- 2.3 Normal transactions
INSERT INTO RAW.TRANSACTIONS
    (TRANSACTION_ID, CUSTOMER_ID, TRANSACTION_TS, AMOUNT, CHANNEL, MERCHANT_CATEGORY)
SELECT
    ROW_NUMBER() OVER (ORDER BY SEQ4()),
    UNIFORM(1, 1000, RANDOM()),
    DATEADD(minute, -UNIFORM(1, 129600, RANDOM()), CURRENT_TIMESTAMP()::TIMESTAMP_NTZ),
    ROUND(5 + ABS(NORMAL(60, 50, RANDOM())), 2),
    ARRAY_CONSTRUCT('POS','ONLINE','ATM','MOBILE')[UNIFORM(0, 3, RANDOM())]::VARCHAR,
    ARRAY_CONSTRUCT('GROCERY','FUEL','DINING','TRAVEL','ELECTRONICS','UTILITIES','CLOTHING')
                   [UNIFORM(0, 6, RANDOM())]::VARCHAR
FROM TABLE(GENERATOR(ROWCOUNT => 50000));

-- Fill in account and country from the customer
UPDATE RAW.TRANSACTIONS t
SET ACCOUNT_ID = 100000 + t.CUSTOMER_ID,
    TRANSACTION_COUNTRY = c.COUNTRY
FROM RAW.CUSTOMERS c
WHERE c.CUSTOMER_ID = t.CUSTOMER_ID;

-- 2.4 Planted pattern A: rapid card testing (5 purchases, 1 minute apart)
SET base_id = (SELECT MAX(TRANSACTION_ID) FROM RAW.TRANSACTIONS);

INSERT INTO RAW.TRANSACTIONS
    (TRANSACTION_ID, ACCOUNT_ID, CUSTOMER_ID, TRANSACTION_TS, AMOUNT, CHANNEL, MERCHANT_CATEGORY, TRANSACTION_COUNTRY)
SELECT
    $base_id + ROW_NUMBER() OVER (ORDER BY c.CUSTOMER_ID, g.i),
    100000 + c.CUSTOMER_ID,
    c.CUSTOMER_ID,
    DATEADD(minute, g.i, DATEADD(day, -c.CUSTOMER_ID, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ)),
    400 + g.i * 50,
    'ONLINE',
    'ELECTRONICS',
    c.COUNTRY
FROM RAW.CUSTOMERS c
CROSS JOIN (
    SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS i
    FROM TABLE(GENERATOR(ROWCOUNT => 5))
) g
WHERE c.CUSTOMER_ID BETWEEN 1 AND 20;

-- 2.5 Planted pattern B: one very large purchase
SET base_id = (SELECT MAX(TRANSACTION_ID) FROM RAW.TRANSACTIONS);

INSERT INTO RAW.TRANSACTIONS
    (TRANSACTION_ID, ACCOUNT_ID, CUSTOMER_ID, TRANSACTION_TS, AMOUNT, CHANNEL, MERCHANT_CATEGORY, TRANSACTION_COUNTRY)
SELECT
    $base_id + ROW_NUMBER() OVER (ORDER BY CUSTOMER_ID),
    100000 + CUSTOMER_ID,
    CUSTOMER_ID,
    DATEADD(day, -MOD(CUSTOMER_ID, 60), CURRENT_TIMESTAMP()::TIMESTAMP_NTZ),
    5000 + CUSTOMER_ID * 10,
    'ONLINE',
    'JEWELRY',
    COUNTRY
FROM RAW.CUSTOMERS
WHERE CUSTOMER_ID BETWEEN 101 AND 150;

-- 2.6 Confirmed fraud cases for part of the planted transactions
INSERT INTO RAW.FRAUD_CASES
    (CASE_ID, TRANSACTION_ID, CUSTOMER_ID, CASE_DATE, FRAUD_TYPE, LOSS_AMOUNT, CASE_STATUS)
SELECT
    ROW_NUMBER() OVER (ORDER BY TRANSACTION_ID),
    TRANSACTION_ID,
    CUSTOMER_ID,
    DATEADD(day, 1, TRANSACTION_TS::DATE),
    IFF(AMOUNT >= 5000, 'ACCOUNT_TAKEOVER', 'CARD_TESTING'),
    AMOUNT,
    'CONFIRMED'
FROM RAW.TRANSACTIONS
WHERE TRANSACTION_ID > 50000
  AND (CUSTOMER_ID BETWEEN 1 AND 15 OR CUSTOMER_ID BETWEEN 101 AND 130);

-- 2.7 Verify
SELECT 'CUSTOMERS'    AS TBL, COUNT(*) AS ROW_COUNT FROM RAW.CUSTOMERS
UNION ALL SELECT 'ACCOUNTS',     COUNT(*) FROM RAW.ACCOUNTS
UNION ALL SELECT 'TRANSACTIONS', COUNT(*) FROM RAW.TRANSACTIONS
UNION ALL SELECT 'FRAUD_CASES',  COUNT(*) FROM RAW.FRAUD_CASES;


/* ============================== PART 3 ==============================
   SIX ADVANCED SQL EXERCISES
   Run each query separately and read the result.
   ==================================================================== */
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE FRAUD_WH;
USE DATABASE FINANCIAL_RISK_DB;

-- Q1. Transactions within 2 minutes of the same customer's previous one
--     (window function: LAG). Expect ~80 planted rows plus a little noise.
WITH gaps AS (
    SELECT CUSTOMER_ID, TRANSACTION_ID, TRANSACTION_TS, AMOUNT,
           DATEDIFF('minute',
                    LAG(TRANSACTION_TS) OVER (PARTITION BY CUSTOMER_ID ORDER BY TRANSACTION_TS),
                    TRANSACTION_TS) AS MINS_SINCE_PREV
    FROM RAW.TRANSACTIONS
)
SELECT *
FROM gaps
WHERE MINS_SINCE_PREV <= 2
ORDER BY CUSTOMER_ID, TRANSACTION_TS;

-- Q2. Amounts far above the customer's own history (z-score > 3)
WITH stats AS (
    SELECT t.*,
           AVG(AMOUNT)    OVER (PARTITION BY CUSTOMER_ID) AS AVG_AMT,
           STDDEV(AMOUNT) OVER (PARTITION BY CUSTOMER_ID) AS STD_AMT
    FROM RAW.TRANSACTIONS t
)
SELECT CUSTOMER_ID, TRANSACTION_ID, AMOUNT,
       ROUND(AVG_AMT, 2) AS CUSTOMER_AVG,
       ROUND((AMOUNT - AVG_AMT) / NULLIF(STD_AMT, 0), 1) AS Z_SCORE
FROM stats
WHERE (AMOUNT - AVG_AMT) / NULLIF(STD_AMT, 0) > 3
ORDER BY Z_SCORE DESC;

-- Q3. Rolling 30-day spend per customer (window frame on a time range)
--     Try customer 1 (rapid pattern) and 101 (large amount).
--     If your account rejects the RANGE ... INTERVAL frame, tell me and
--     I will give you a self-join version.
SELECT CUSTOMER_ID, TRANSACTION_ID, TRANSACTION_TS, AMOUNT,
       SUM(AMOUNT) OVER (
           PARTITION BY CUSTOMER_ID
           ORDER BY TRANSACTION_TS
           RANGE BETWEEN INTERVAL '30 days' PRECEDING AND CURRENT ROW
       ) AS SPEND_LAST_30D
FROM RAW.TRANSACTIONS
WHERE CUSTOMER_ID IN (1, 101)
ORDER BY CUSTOMER_ID, TRANSACTION_TS;

-- Q4. Rank customers by risk. First a reusable flags view (rules live here),
--     then the ranking query.
CREATE OR REPLACE VIEW ANALYTICS.TRANSACTION_FLAGS AS
WITH base AS (
    SELECT t.*,
           DATEDIFF('minute',
                    LAG(TRANSACTION_TS) OVER (PARTITION BY CUSTOMER_ID ORDER BY TRANSACTION_TS),
                    TRANSACTION_TS) AS MINS_SINCE_PREV
    FROM RAW.TRANSACTIONS t
)
SELECT TRANSACTION_ID, CUSTOMER_ID, TRANSACTION_TS, AMOUNT, CHANNEL,
       MERCHANT_CATEGORY, TRANSACTION_COUNTRY,
       IFF(MINS_SINCE_PREV <= 2, 1, 0) AS FLAG_RAPID,
       IFF(AMOUNT >= 5000, 1, 0)       AS FLAG_HIGH_AMOUNT,
       IFF(MINS_SINCE_PREV <= 2, 1, 0) * 10
         + IFF(AMOUNT >= 5000, 1, 0) * 50 AS RISK_POINTS
FROM base;

SELECT CUSTOMER_ID,
       SUM(RISK_POINTS) AS TOTAL_RISK_POINTS,
       RANK() OVER (ORDER BY SUM(RISK_POINTS) DESC) AS RISK_RANK
FROM ANALYTICS.TRANSACTION_FLAGS
GROUP BY CUSTOMER_ID
QUALIFY RISK_RANK <= 20
ORDER BY RISK_RANK, CUSTOMER_ID;

-- Q5. Deduplicate (ROW_NUMBER + QUALIFY).
--     We simulate a bad load by duplicating 100 rows, then clean them.
CREATE OR REPLACE TABLE RAW.TRANSACTIONS_LOAD AS
SELECT * FROM RAW.TRANSACTIONS;

INSERT INTO RAW.TRANSACTIONS_LOAD
SELECT * FROM RAW.TRANSACTIONS WHERE TRANSACTION_ID <= 100;

-- Expect 50250 total rows vs 50150 unique
SELECT COUNT(*) AS TOTAL_ROWS, COUNT(DISTINCT TRANSACTION_ID) AS UNIQUE_TXNS
FROM RAW.TRANSACTIONS_LOAD;

CREATE OR REPLACE TABLE ANALYTICS.TRANSACTIONS_CLEAN AS
SELECT *
FROM RAW.TRANSACTIONS_LOAD
QUALIFY ROW_NUMBER() OVER (PARTITION BY TRANSACTION_ID ORDER BY CREATED_AT DESC) = 1;

SELECT COUNT(*) AS CLEAN_ROWS FROM ANALYTICS.TRANSACTIONS_CLEAN;   -- expect 50150

-- Q6. Fraud loss ratio by country (join + conditional aggregation)
SELECT t.TRANSACTION_COUNTRY,
       SUM(t.AMOUNT)                         AS TOTAL_VALUE,
       COALESCE(SUM(f.LOSS_AMOUNT), 0)       AS FRAUD_LOSS,
       ROUND(COALESCE(SUM(f.LOSS_AMOUNT), 0) / SUM(t.AMOUNT) * 100, 2) AS LOSS_RATIO_PCT
FROM RAW.TRANSACTIONS t
LEFT JOIN RAW.FRAUD_CASES f ON f.TRANSACTION_ID = t.TRANSACTION_ID
GROUP BY t.TRANSACTION_COUNTRY
ORDER BY LOSS_RATIO_PCT DESC;


/* ============================== PART 4 ==============================
   SNOWFLAKE FEATURES: Dynamic Table + Stream & Task
   ==================================================================== */
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE FRAUD_WH;
USE DATABASE FINANCIAL_RISK_DB;

-- 4.1 Dynamic Table: customer risk summary that Snowflake keeps fresh.
--     Score = 10/rapid flag + 50/high-amount flag + 25/fraud case, capped at 100.
--     Expect about 45 HIGH customers (1-15 and 101-130).
CREATE OR REPLACE DYNAMIC TABLE ANALYTICS.CUSTOMER_RISK_SUMMARY
    TARGET_LAG = '1 hour'
    WAREHOUSE  = FRAUD_WH
AS
SELECT s.*,
       CASE WHEN s.RISK_SCORE >= 70 THEN 'HIGH'
            WHEN s.RISK_SCORE >= 30 THEN 'MEDIUM'
            ELSE 'LOW' END AS RISK_BAND
FROM (
    SELECT c.CUSTOMER_ID, c.COUNTRY, c.CUSTOMER_SEGMENT,
           COALESCE(tx.TXN_COUNT, 0)         AS TXN_COUNT,
           COALESCE(tx.TOTAL_SPEND, 0)       AS TOTAL_SPEND,
           COALESCE(tx.RAPID_FLAGS, 0)       AS RAPID_FLAGS,
           COALESCE(tx.HIGH_AMOUNT_FLAGS, 0) AS HIGH_AMOUNT_FLAGS,
           COALESCE(fc.FRAUD_CASES, 0)       AS FRAUD_CASES,
           LEAST(100,
                 COALESCE(tx.RAPID_FLAGS, 0) * 10
               + COALESCE(tx.HIGH_AMOUNT_FLAGS, 0) * 50
               + COALESCE(fc.FRAUD_CASES, 0) * 25) AS RISK_SCORE
    FROM RAW.CUSTOMERS c
    LEFT JOIN (
        SELECT CUSTOMER_ID,
               COUNT(*)              AS TXN_COUNT,
               SUM(AMOUNT)           AS TOTAL_SPEND,
               SUM(FLAG_RAPID)       AS RAPID_FLAGS,
               SUM(FLAG_HIGH_AMOUNT) AS HIGH_AMOUNT_FLAGS
        FROM ANALYTICS.TRANSACTION_FLAGS
        GROUP BY CUSTOMER_ID
    ) tx ON tx.CUSTOMER_ID = c.CUSTOMER_ID
    LEFT JOIN (
        SELECT CUSTOMER_ID, COUNT(*) AS FRAUD_CASES
        FROM RAW.FRAUD_CASES
        GROUP BY CUSTOMER_ID
    ) fc ON fc.CUSTOMER_ID = c.CUSTOMER_ID
) s;

SELECT RISK_BAND, COUNT(*) AS CUSTOMERS
FROM ANALYTICS.CUSTOMER_RISK_SUMMARY
GROUP BY RISK_BAND
ORDER BY CUSTOMERS DESC;

-- 4.2 Stream + Task: automatically flag NEW large transactions.
CREATE OR REPLACE STREAM RAW.TRANSACTIONS_STREAM
    ON TABLE RAW.TRANSACTIONS
    APPEND_ONLY = TRUE;

CREATE TABLE IF NOT EXISTS ANALYTICS.ALERTS (
    TRANSACTION_ID  NUMBER(12,0),
    CUSTOMER_ID     NUMBER(10,0),
    AMOUNT          NUMBER(12,2),
    ALERT_REASON    VARCHAR(50),
    ALERTED_AT      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TASK ANALYTICS.FLAG_NEW_TRANSACTIONS
    WAREHOUSE = FRAUD_WH
    SCHEDULE  = '1 MINUTE'
WHEN SYSTEM$STREAM_HAS_DATA('RAW.TRANSACTIONS_STREAM')
AS
INSERT INTO ANALYTICS.ALERTS (TRANSACTION_ID, CUSTOMER_ID, AMOUNT, ALERT_REASON)
SELECT TRANSACTION_ID, CUSTOMER_ID, AMOUNT, 'HIGH_AMOUNT'
FROM RAW.TRANSACTIONS_STREAM
WHERE AMOUNT >= 5000;

-- Tasks are created suspended. Resume it:
ALTER TASK ANALYTICS.FLAG_NEW_TRANSACTIONS RESUME;

-- 4.3 Test it: insert a new large transaction, run the task now, check alerts.
INSERT INTO RAW.TRANSACTIONS
    (TRANSACTION_ID, ACCOUNT_ID, CUSTOMER_ID, TRANSACTION_TS, AMOUNT, CHANNEL, MERCHANT_CATEGORY, TRANSACTION_COUNTRY)
VALUES (999001, 100500, 500, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, 25000, 'ONLINE', 'JEWELRY', 'India');

EXECUTE TASK ANALYTICS.FLAG_NEW_TRANSACTIONS;

-- wait ~15 seconds, then:
SELECT * FROM ANALYTICS.ALERTS;     -- expect 1 row for transaction 999001

-- 4.4 IMPORTANT for credits: stop the schedule when you are done testing,
--     and remove the test row so later numbers stay clean.
ALTER TASK ANALYTICS.FLAG_NEW_TRANSACTIONS SUSPEND;
DELETE FROM RAW.TRANSACTIONS WHERE TRANSACTION_ID = 999001;


/* ============================== PART 5 ==============================
   SEMANTIC VIEW
   First a one-row-per-transaction fact view (fraud info flattened in),
   then the semantic view on top of it + the customer risk dynamic table.
   NOTE: I could not run this against your account. If CREATE SEMANTIC VIEW
   errors, paste the exact message; syntax is the most likely thing to need
   a small tweak.
   ==================================================================== */
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE FRAUD_WH;
USE DATABASE FINANCIAL_RISK_DB;

CREATE OR REPLACE VIEW ANALYTICS.FACT_TRANSACTIONS AS
SELECT t.TRANSACTION_ID,
       t.CUSTOMER_ID,
       t.ACCOUNT_ID,
       t.TRANSACTION_TS,
       t.TRANSACTION_TS::DATE                AS TRANSACTION_DATE,
       t.AMOUNT,
       t.CHANNEL,
       t.MERCHANT_CATEGORY,
       t.TRANSACTION_COUNTRY,
       COALESCE(f.FRAUD_TYPE, 'NONE')        AS FRAUD_TYPE,
       COALESCE(f.LOSS_AMOUNT, 0)            AS FRAUD_LOSS_AMOUNT,
       IFF(f.CASE_ID IS NOT NULL, 1, 0)      AS IS_CONFIRMED_FRAUD,
       fl.FLAG_RAPID,
       fl.FLAG_HIGH_AMOUNT,
       IFF(fl.RISK_POINTS > 0, 1, 0)         AS IS_SUSPICIOUS
FROM RAW.TRANSACTIONS t
LEFT JOIN RAW.FRAUD_CASES f ON f.TRANSACTION_ID = t.TRANSACTION_ID
JOIN ANALYTICS.TRANSACTION_FLAGS fl ON fl.TRANSACTION_ID = t.TRANSACTION_ID;

CREATE OR REPLACE SEMANTIC VIEW MART.SV_FRAUD_ANALYTICS
  TABLES (
    customers AS ANALYTICS.CUSTOMER_RISK_SUMMARY
      PRIMARY KEY (CUSTOMER_ID)
      WITH SYNONYMS = ('clients', 'account holders')
      COMMENT = 'One row per customer with a rolled-up risk score and risk band',
    transactions AS ANALYTICS.FACT_TRANSACTIONS
      PRIMARY KEY (TRANSACTION_ID)
      WITH SYNONYMS = ('payments', 'txns')
      COMMENT = 'One row per transaction with suspicious and confirmed-fraud indicators'
  )
  RELATIONSHIPS (
    transactions_to_customers AS transactions (CUSTOMER_ID) REFERENCES customers
  )
  FACTS (
    transactions.txn_amount AS AMOUNT
      COMMENT = 'Transaction amount',
    transactions.fraud_loss_value AS FRAUD_LOSS_AMOUNT
      COMMENT = 'Confirmed fraud loss on the transaction (0 when not fraud)',
    transactions.suspicious_flag AS IS_SUSPICIOUS
      COMMENT = '1 when the transaction tripped a fraud rule',
    customers.high_risk_flag AS IFF(RISK_BAND = 'HIGH', 1, 0)
      COMMENT = '1 when the customer is in the HIGH risk band',
    customers.risk_score_value AS RISK_SCORE
      COMMENT = 'Customer risk score from 0 to 100'
  )
  DIMENSIONS (
    customers.customer_key AS CUSTOMER_ID,
    customers.customer_country AS COUNTRY
      WITH SYNONYMS = ('country', 'home country')
      COMMENT = 'Customer home country',
    customers.segment AS CUSTOMER_SEGMENT
      WITH SYNONYMS = ('customer type', 'customer tier')
      COMMENT = 'RETAIL, PREMIUM or SME',
    customers.risk_level AS RISK_BAND
      WITH SYNONYMS = ('risk band', 'risk category')
      COMMENT = 'HIGH, MEDIUM or LOW',
    transactions.txn_channel AS CHANNEL
      WITH SYNONYMS = ('payment channel')
      COMMENT = 'POS, ONLINE, ATM or MOBILE',
    transactions.txn_merchant_category AS MERCHANT_CATEGORY
      WITH SYNONYMS = ('merchant type', 'category'),
    transactions.txn_country AS TRANSACTION_COUNTRY
      COMMENT = 'Country where the transaction took place',
    transactions.fraud_type_name AS FRAUD_TYPE
      COMMENT = 'Type of confirmed fraud, or NONE',
    transactions.txn_date AS TRANSACTION_DATE,
    transactions.txn_month AS DATE_TRUNC('month', TRANSACTION_DATE)
  )
  METRICS (
    transactions.total_transaction_value AS SUM(transactions.txn_amount)
      WITH SYNONYMS = ('total spend', 'transaction volume', 'total amount')
      COMMENT = 'Sum of all transaction amounts',
    transactions.transaction_count AS COUNT(transactions.TRANSACTION_ID)
      WITH SYNONYMS = ('number of transactions')
      COMMENT = 'Number of transactions',
    transactions.suspicious_transaction_count AS SUM(transactions.suspicious_flag)
      WITH SYNONYMS = ('flagged transactions', 'suspicious transactions')
      COMMENT = 'Transactions that tripped at least one fraud rule',
    transactions.total_fraud_loss AS SUM(transactions.fraud_loss_value)
      WITH SYNONYMS = ('fraud losses', 'fraud amount')
      COMMENT = 'Sum of confirmed fraud losses',
    transactions.fraud_loss_ratio AS SUM(transactions.fraud_loss_value) / NULLIF(SUM(transactions.txn_amount), 0)
      WITH SYNONYMS = ('fraud rate', 'loss ratio')
      COMMENT = 'Confirmed fraud loss divided by total transaction value',
    customers.high_risk_customers AS SUM(customers.high_risk_flag)
      WITH SYNONYMS = ('risky customers')
      COMMENT = 'Number of customers in the HIGH risk band',
    customers.average_risk_score AS AVG(customers.risk_score_value)
      COMMENT = 'Average customer risk score'
  )
  COMMENT = 'Fraud monitoring metrics: transaction value, suspicious activity, fraud loss and customer risk';

SHOW SEMANTIC VIEWS IN SCHEMA MART;
DESCRIBE SEMANTIC VIEW MART.SV_FRAUD_ANALYTICS;


/* ============================== PART 6 ==============================
   TEST THE SEMANTIC VIEW WITH SQL
   ==================================================================== */
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE FRAUD_WH;
USE DATABASE FINANCIAL_RISK_DB;

-- Value, fraud loss and loss ratio by customer country
SELECT *
FROM SEMANTIC_VIEW(
    MART.SV_FRAUD_ANALYTICS
    METRICS    transactions.total_transaction_value,
               transactions.total_fraud_loss,
               transactions.fraud_loss_ratio
    DIMENSIONS customers.customer_country
)
ORDER BY fraud_loss_ratio DESC;

-- Suspicious transactions by channel
SELECT *
FROM SEMANTIC_VIEW(
    MART.SV_FRAUD_ANALYTICS
    METRICS    transactions.suspicious_transaction_count,
               transactions.transaction_count
    DIMENSIONS transactions.txn_channel
);

-- Monthly trend
SELECT *
FROM SEMANTIC_VIEW(
    MART.SV_FRAUD_ANALYTICS
    METRICS    transactions.total_transaction_value,
               transactions.total_fraud_loss
    DIMENSIONS transactions.txn_month
)
ORDER BY txn_month;

-- High-risk customers by segment
SELECT *
FROM SEMANTIC_VIEW(
    MART.SV_FRAUD_ANALYTICS
    METRICS    customers.high_risk_customers,
               customers.average_risk_score
    DIMENSIONS customers.segment
);

/* THEN, in Snowsight, open Cortex Analyst (under AI & ML) and pick
   MART.SV_FRAUD_ANALYTICS. Ask in plain English, for example:
     - Which country has the highest fraud loss ratio?
     - How many high-risk customers are in each segment?
     - Show suspicious transactions by channel.
   Compare each answer with the SQL results above. If Cortex is not
   available in your account/region, skip this and tell me. */


/* ============================== PART 7 ==============================
   ROLES (RBAC): give analysts read-only access to the analytics layers
   but NOT to raw customer data.
   ==================================================================== */
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE FRAUD_WH;
USE DATABASE FINANCIAL_RISK_DB;

CREATE ROLE IF NOT EXISTS FRAUD_ANALYST;

GRANT USAGE ON WAREHOUSE FRAUD_WH TO ROLE FRAUD_ANALYST;
GRANT USAGE ON DATABASE FINANCIAL_RISK_DB TO ROLE FRAUD_ANALYST;
GRANT USAGE ON SCHEMA FINANCIAL_RISK_DB.ANALYTICS TO ROLE FRAUD_ANALYST;
GRANT USAGE ON SCHEMA FINANCIAL_RISK_DB.MART TO ROLE FRAUD_ANALYST;

GRANT SELECT ON ALL TABLES         IN SCHEMA FINANCIAL_RISK_DB.ANALYTICS TO ROLE FRAUD_ANALYST;
GRANT SELECT ON ALL VIEWS          IN SCHEMA FINANCIAL_RISK_DB.ANALYTICS TO ROLE FRAUD_ANALYST;
GRANT SELECT ON ALL DYNAMIC TABLES IN SCHEMA FINANCIAL_RISK_DB.ANALYTICS TO ROLE FRAUD_ANALYST;
GRANT SELECT ON ALL SEMANTIC VIEWS IN SCHEMA FINANCIAL_RISK_DB.MART      TO ROLE FRAUD_ANALYST;

SET me = CURRENT_USER();
GRANT ROLE FRAUD_ANALYST TO USER IDENTIFIER($me);

-- Test: switch role and try both queries. The first works, the second must fail.
USE ROLE FRAUD_ANALYST;
USE WAREHOUSE FRAUD_WH;

SELECT RISK_BAND, COUNT(*) AS CUSTOMERS
FROM FINANCIAL_RISK_DB.ANALYTICS.CUSTOMER_RISK_SUMMARY
GROUP BY RISK_BAND;                                   -- works

SELECT * FROM FINANCIAL_RISK_DB.RAW.CUSTOMERS LIMIT 5; -- should fail: no access to RAW

USE ROLE ACCOUNTADMIN;


/* ============================== CLEAN UP ============================
   Optional, to stop all credit use when you finish for the day:
     ALTER TASK ANALYTICS.FLAG_NEW_TRANSACTIONS SUSPEND;
     ALTER DYNAMIC TABLE ANALYTICS.CUSTOMER_RISK_SUMMARY SUSPEND;
   ==================================================================== */
