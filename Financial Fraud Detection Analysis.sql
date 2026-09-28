/* ============================================================================
   FINANCIAL FRAUD DETECTION — SQL ANALYSIS
   ============================================================================
   Author   : Rajan Singh
   Dataset  : PaySim — synthetic mobile-money transactions (Kaggle)
              6,362,620 rows | 743 hourly time steps | 8,213 confirmed fraud
              cases (0.13% of volume)
   Engine   : MySQL 8.0+ (CTEs, recursive CTEs, window functions)
   Table    : bank.transactions

   OBJECTIVE
   ---------
   Investigate transaction-level fraud patterns in a large mobile-money
   dataset and evaluate candidate detection rules on precision and recall,
   simulating the kind of ad hoc + rule-development analysis a fraud/risk
   analytics team would run in production.

   SCHEMA REFERENCE
   -----------------
   step             Simulation hour (1–743)
   type             CASH_IN | CASH_OUT | DEBIT | PAYMENT | TRANSFER
   amount           Transaction amount
   nameOrig         Sender account ID
   oldbalanceOrg    Sender balance before the transaction
   newbalanceOrig   Sender balance after the transaction
   nameDest         Recipient account ID (C = customer, M = merchant)
   oldbalanceDest   Recipient balance before the transaction
   newbalanceDest   Recipient balance after the transaction
   isFraud          1 = confirmed fraud
   isFlaggedFraud   1 = flagged by the platform's built-in large-transfer rule

   CONTENTS
   --------
   0. Environment setup & data profiling
   1. Fraud chain tracing            (recursive CTE)
   2. Rolling fraud trend            (window function)
   3. Multi-signal suspicious-transfer detection
   4. Destination balance reconciliation
   5. Untouched destination accounts
   6. Detection rule scorecard       (precision & recall)

   NOTE: Lines marked "Result:" report figures validated against the full
   6.36M-row dataset, not a sample.
   ============================================================================ */

USE bank;


/* ----------------------------------------------------------------------------
   0. ENVIRONMENT SETUP & DATA PROFILING
   ---------------------------------------------------------------------------- */

-- 0.1  Supporting indexes (one-time setup).
--      idx_txn_fraud_type_orig -> serves the fraud-only filter in Section 1.
--      idx_txn_flagged         -> makes the 16-row flagged-transaction lookup
--                                  in Section 3 an index seek instead of a
--                                  full table scan.
--      If nameOrig / nameDest were imported as TEXT rather than VARCHAR, add
--      a prefix length, e.g. nameOrig(20), before indexing.
CREATE INDEX idx_txn_fraud_type_orig ON transactions (isFraud, type, nameOrig, step);
CREATE INDEX idx_txn_flagged         ON transactions (isFlaggedFraud);

-- 0.2  Schema sanity check.
SELECT *
FROM transactions
LIMIT 10;

-- 0.3  Data-quality audit: confirm the table is analysis-ready.
-- Result: zero NULLs and zero negative amounts across all 6.36M rows —
--         no cleaning required before analysis.
SELECT
    COUNT(*) AS total_rows,
    SUM(CASE WHEN amount < 0 THEN 1 ELSE 0 END) AS negative_amounts,
    SUM(CASE WHEN step IS NULL OR type IS NULL OR amount IS NULL
              OR nameOrig IS NULL OR oldbalanceOrg IS NULL OR newbalanceOrig IS NULL
              OR nameDest IS NULL OR oldbalanceDest IS NULL OR newbalanceDest IS NULL
              OR isFraud IS NULL OR isFlaggedFraud IS NULL
             THEN 1 ELSE 0 END) AS rows_with_nulls
FROM transactions;

-- 0.4  Fraud incidence by transaction type.
-- Result: fraud is confined to TRANSFER (4,097 cases) and CASH_OUT
--         (4,116 cases). CASH_IN, DEBIT, and PAYMENT are dropped from the
--         rule analysis in Section 6 since they contribute zero fraud cases.
SELECT
    type,
    COUNT(*)                                  AS txn_count,
    SUM(isFraud)                              AS fraud_count,
    ROUND(100.0 * SUM(isFraud) / COUNT(*), 3) AS fraud_rate_pct
FROM transactions
GROUP BY type
ORDER BY fraud_count DESC;


/* ----------------------------------------------------------------------------
   1. FRAUD CHAIN TRACING — RECURSIVE CTE
   ----------------------------------------------------------------------------
   Business question : Are fraudulent funds being layered — passed from one
                        compromised account to the next to obscure their
                        origin — rather than cashed out in a single hop?

   Approach
     Anchor member    : every confirmed-fraud TRANSFER (hop 1).
     Recursive member : a later fraudulent TRANSFER sent by the previous
                         hop's recipient (hop n+1).

   Safeguards
     - step strictly increases between hops, so a chain cannot cycle back
       on itself.
     - depth is capped at 5 to bound recursion.

   Performance note
     The recursive member joins against the pre-filtered fraud_transfers CTE
     (4,097 rows), not the 6.36M-row base table. An earlier version that
     re-joined the full table at every recursion level timed out; filtering
     fraud transfers once up front resolved it.

   Result: every chain terminates at depth 1 — no fraudulent transfer in this
           dataset is ever forwarded by its recipient. Multi-hop layering is
           not present here (a useful negative finding for a synthetic
           dataset, and a check worth re-running on real transaction data).
   ---------------------------------------------------------------------------- */
WITH RECURSIVE fraud_transfers AS (
    SELECT nameOrig, nameDest, step, amount
    FROM transactions
    WHERE isFraud = 1
      AND type = 'TRANSFER'
),
fraud_chain AS (
    -- Anchor: first hop of every chain
    SELECT
        nameOrig AS initial_acc,
        nameDest AS next_acc,
        step,
        amount,
        1        AS depth
    FROM fraud_transfers

    UNION ALL

    -- Recursive step: extend each chain by one hop
    SELECT
        fc.initial_acc,
        ft.nameDest,
        ft.step,
        ft.amount,
        fc.depth + 1
    FROM fraud_chain AS fc
    JOIN fraud_transfers AS ft
      ON ft.nameOrig = fc.next_acc
     AND ft.step > fc.step
    WHERE fc.depth < 5
)
SELECT
    depth,
    COUNT(*)    AS chain_count,
    SUM(amount) AS total_amount
FROM fraud_chain
GROUP BY depth
ORDER BY depth;

-- To inspect individual multi-hop chains (should any exist), swap the final
-- SELECT for:
--   SELECT * FROM fraud_chain WHERE depth > 1 ORDER BY initial_acc, depth;


/* ----------------------------------------------------------------------------
   2. ROLLING FRAUD TREND — WINDOW FUNCTION
   ----------------------------------------------------------------------------
   Business question : Does fraud arrive in bursts, and if so, when?

   Approach : Aggregate to one row per simulation step, then apply a 5-row
              SUM() OVER window (current step + 4 preceding) to smooth
              short-term noise and expose spikes.

   Design note: The window runs across time, not per account — only 9,298 of
   6.35M sender accounts transact more than once, and none has a second
   fraudulent transaction, so an account-level rolling count would be
   uninformative (it could never exceed 1).

   Result: rolling fraud counts peak at ~89 cases per 5-hour window. Rolling
           *rates* spike hardest during low-volume overnight steps — a
           reminder to monitor count and rate together rather than either
           alone.
   ---------------------------------------------------------------------------- */
WITH step_summary AS (
    SELECT
        step,
        COUNT(*)     AS txn_count,
        SUM(isFraud) AS fraud_count
    FROM transactions
    GROUP BY step
),
rolling_fraud AS (
    SELECT
        step,
        fraud_count,
        SUM(fraud_count) OVER w AS fraud_rolling_5,
        SUM(txn_count)   OVER w AS txn_rolling_5
    FROM step_summary
    WINDOW w AS (ORDER BY step ROWS BETWEEN 4 PRECEDING AND CURRENT ROW)
)
SELECT
    step,
    fraud_count,
    fraud_rolling_5,
    ROUND(100.0 * fraud_rolling_5 / txn_rolling_5, 3) AS rolling_fraud_rate_pct
FROM rolling_fraud
WHERE fraud_rolling_5 > 0
ORDER BY fraud_rolling_5 DESC
LIMIT 20;


/* ----------------------------------------------------------------------------
   3. MULTI-SIGNAL SUSPICIOUS-TRANSFER DETECTION
   ----------------------------------------------------------------------------
   Business question : Which transfers trip every warning sign at once —
                        a large amount, a sender balance that didn't move,
                        and the platform's own fraud flag?

   Signals combined
     (a) transfer amount over 5,000,000
     (b) sender balance unchanged (oldbalanceOrg = newbalanceOrig)
     (c) isFlaggedFraud = 1 (system rule)

   Optimization note: an earlier version joined three separate CTEs on
   (nameOrig, step), scanning the 6.36M-row table three times. Filtering in a
   single pass lets the optimizer lead with the most selective predicate,
   isFlaggedFraud = 1 (16 rows total), via idx_txn_flagged.

   Result: 6 transfers (ranging 5.7M–10.0M) satisfy all three conditions —
           and all 6 are confirmed fraud. The unchanged sender balance is
           consistent with a transfer that the system blocked before it
           settled.
   ---------------------------------------------------------------------------- */
SELECT
    nameOrig,
    step,
    amount,
    oldbalanceOrg,
    newbalanceOrig
FROM transactions
WHERE isFlaggedFraud = 1
  AND type = 'TRANSFER'
  AND amount > 5000000
  AND oldbalanceOrg = newbalanceOrig
ORDER BY amount DESC;


/* ----------------------------------------------------------------------------
   4. DESTINATION BALANCE RECONCILIATION
   ----------------------------------------------------------------------------
   Business question : Does the recipient's balance actually reconcile with
                        the transaction, and does a mismatch predict fraud?

   Approach : Classify each customer-bound transaction as MATCH or MISMATCH
              against the ledger identity
                  oldbalanceDest + amount = newbalanceDest
              then compare fraud rates across the two groups.

   Notes
     - A 0.01 tolerance replaces exact equality, since floating-point
       comparisons are unreliable.
     - Merchant accounts (nameDest LIKE 'M%') are excluded — their balances
       aren't tracked in this dataset.
     - The identity describes a credit to the recipient, so TRANSFER is the
       most meaningful type to evaluate here.

   Result: 99.95% of fraudulent transfers (4,095 of 4,097) fail
           reconciliation. Fraud rate is 3.39% among mismatched transfers
           versus 0.0005% among matched ones — reconciliation mismatch is a
           strong standalone fraud signal.
   ---------------------------------------------------------------------------- */
WITH dest_check AS (
    SELECT
        type,
        isFraud,
        CASE
            WHEN ABS((oldbalanceDest + amount) - newbalanceDest) < 0.01 THEN 'MATCH'
            ELSE 'MISMATCH'
        END AS balance_check
    FROM transactions
    WHERE nameDest LIKE 'C%'
)
SELECT
    type,
    balance_check,
    COUNT(*)                                  AS txn_count,
    SUM(isFraud)                              AS fraud_count,
    ROUND(100.0 * SUM(isFraud) / COUNT(*), 3) AS fraud_rate_pct
FROM dest_check
GROUP BY type, balance_check
ORDER BY type, balance_check;


/* ----------------------------------------------------------------------------
   5. UNTOUCHED DESTINATION ACCOUNTS
   ----------------------------------------------------------------------------
   Business question : Are there transfers where money left the sender but
                        never actually landed anywhere?

   Approach : Restrict to TRANSFER and CASH_OUT — the only two types that
              contain any fraud — and flag rows where the recipient balance
              is 0 both before and after the transaction.

   Result: 4,174 TRANSFERs match this pattern, and 97.5% of them are fraud.
           Only 0.1% of matching CASH_OUT rows are fraud, so the signal is
           specific to TRANSFER. Combined across both types, 70.5% of
           matching rows are fraud versus a 0.30% baseline — one of the
           strongest single-condition signals in the dataset.
   ---------------------------------------------------------------------------- */

-- 5.1  Signal strength by transaction type
SELECT
    type,
    COUNT(*)                                  AS txn_count,
    SUM(isFraud)                              AS fraud_count,
    ROUND(100.0 * SUM(isFraud) / COUNT(*), 1) AS fraud_rate_pct
FROM transactions
WHERE type IN ('TRANSFER', 'CASH_OUT')
  AND amount > 0
  AND oldbalanceDest = 0
  AND newbalanceDest = 0
GROUP BY type;

-- 5.2  Largest matching transfers, queued for manual review
SELECT
    nameOrig,
    nameDest,
    step,
    amount,
    isFraud
FROM transactions
WHERE type = 'TRANSFER'
  AND amount > 0
  AND oldbalanceDest = 0
  AND newbalanceDest = 0
ORDER BY amount DESC
LIMIT 100;


/* ----------------------------------------------------------------------------
   6. DETECTION RULE SCORECARD — PRECISION & RECALL
   ----------------------------------------------------------------------------
   Business question : Of the candidate detection rules above, which should
                        actually run in production, and what trade-off does
                        each one make?

   Definitions
     precision = share of flagged transactions that are truly fraud
     recall    = share of all fraud that the rule successfully catches

   Approach : Flag every row against all three rules in one CTE, then use
              conditional aggregation (SUM of flag * isFraud) to compute true
              positives per rule without three separate passes over the data.

   Scope : TRANSFER and CASH_OUT only — 8,213 fraud cases across 2,770,409
           rows (the two types where fraud occurs at all; see Section 0.4).

   Result
     Rule                            Precision   Recall
     ------------------------------  ---------   ------
     System flag (isFlaggedFraud)      100.0%      0.2%   (16 rows total)
     Untouched recipient balance        70.5%     49.6%
     Drained sender balance            100.0%     97.6%

     The drained-sender rule is near-perfect because PaySim's fraud
     generator always empties the victim's account completely — a property
     of the synthetic data, not something to expect from real-world fraud,
     which is rarely this clean. In production this rule would need to be
     paired with additional signals rather than deployed on its own.
   ---------------------------------------------------------------------------- */
WITH rule_flags AS (
    SELECT
        isFraud,
        isFlaggedFraud AS flag_system,
        CASE WHEN amount > 0 AND oldbalanceDest = 0 AND newbalanceDest = 0
             THEN 1 ELSE 0 END AS flag_dest_untouched,
        CASE WHEN oldbalanceOrg > 0 AND ABS(amount - oldbalanceOrg) < 0.01
             THEN 1 ELSE 0 END AS flag_origin_drained
    FROM transactions
    WHERE type IN ('TRANSFER', 'CASH_OUT')
),
fraud_total AS (
    SELECT SUM(isFraud) AS total_fraud
    FROM rule_flags
)
SELECT
    'System flag (isFlaggedFraud)' AS rule_name,
    SUM(flag_system)               AS flagged_txns,
    SUM(flag_system * isFraud)     AS true_positives,
    ROUND(100.0 * SUM(flag_system * isFraud) / NULLIF(SUM(flag_system), 0), 1) AS precision_pct,
    ROUND(100.0 * SUM(flag_system * isFraud) / MAX(total_fraud), 1)            AS recall_pct
FROM rule_flags CROSS JOIN fraud_total

UNION ALL

SELECT
    'Untouched recipient balance',
    SUM(flag_dest_untouched),
    SUM(flag_dest_untouched * isFraud),
    ROUND(100.0 * SUM(flag_dest_untouched * isFraud) / NULLIF(SUM(flag_dest_untouched), 0), 1),
    ROUND(100.0 * SUM(flag_dest_untouched * isFraud) / MAX(total_fraud), 1)
FROM rule_flags CROSS JOIN fraud_total

UNION ALL

SELECT
    'Drained sender balance',
    SUM(flag_origin_drained),
    SUM(flag_origin_drained * isFraud),
    ROUND(100.0 * SUM(flag_origin_drained * isFraud) / NULLIF(SUM(flag_origin_drained), 0), 1),
    ROUND(100.0 * SUM(flag_origin_drained * isFraud) / MAX(total_fraud), 1)
FROM rule_flags CROSS JOIN fraud_total;
