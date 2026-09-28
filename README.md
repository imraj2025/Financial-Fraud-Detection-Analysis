# Financial Fraud Detection Analysis (SQL)

A MySQL analysis of **6.36 million mobile-money transactions** that investigates fraud patterns and scores candidate detection rules on precision and recall. It uses recursive CTEs, window functions, and conditional aggregation, and is written the way a fraud/risk analytics team would run ad hoc investigation and rule development.

**Stack:** MySQL 8.0+ · Recursive CTEs · Window functions · Conditional aggregation
**Dataset:** [PaySim](https://www.kaggle.com/datasets/ealaxi/paysim1), a synthetic mobile-money simulator (Kaggle)

---

## Key Results

All figures were computed on the full 6,362,620-row dataset, not a sample.

| Finding | Result |
|---|---|
| Fraud volume | 8,213 fraud cases (0.13%), all in `TRANSFER` (4,097) and `CASH_OUT` (4,116). `CASH_IN`, `DEBIT`, and `PAYMENT` have zero fraud. |
| Multi-hop layering | Recursive CTE over the 4,097 fraudulent transfers found **no chains deeper than 1 hop**. No fraudulent transfer is forwarded by its recipient. |
| Best detection rule | **Drained sender balance** catches **97.6% of fraud at 100% precision** (8,018 flagged, 0 false positives). |
| Existing system flag | `isFlaggedFraud` has 100% precision but only **0.2% recall** (16 rows). |
| Balance reconciliation | Fraud rate is **3.39%** among `TRANSFER`s where the recipient's ledger doesn't reconcile vs **0.0005%** where it does (about 7,000x). |
| Untouched recipient | 97.5% of `TRANSFER`s where the recipient balance stays at 0 are fraud. |

### Detection rule scorecard

Scope: `TRANSFER` + `CASH_OUT` only (2,770,409 rows, 8,213 fraud).

| Rule | Flagged | True positives | Precision | Recall |
|---|---:|---:|---:|---:|
| System flag (`isFlaggedFraud`) | 16 | 16 | 100.0% | 0.2% |
| Untouched recipient balance (0 → 0) | 5,776 | 4,070 | 70.5% | 49.6% |
| **Drained sender balance** (`amount = oldbalanceOrg`) | 8,018 | 8,018 | **100.0%** | **97.6%** |

---

## What the Analysis Covers

| # | Section | Technique | Question |
|---|---|---|---|
| 0 | Setup & profiling | Indexes, data-quality audit | Is the table analysis-ready? Where does fraud occur? |
| 1 | Fraud chain tracing | **Recursive CTE** | Are stolen funds layered across accounts? |
| 2 | Rolling fraud trend | **Window function** (`SUM() OVER`) | Does fraud arrive in bursts? |
| 3 | Multi-signal detection | Single-pass filtering | Which transfers trip every warning sign at once? |
| 4 | Destination reconciliation | Conditional classification | Does `oldbalanceDest + amount = newbalanceDest` predict fraud? |
| 5 | Untouched destinations | Aggregation by type | Does money leave the sender but never land? |
| 6 | Rule scorecard | Conditional aggregation | Which rule should run in production, and at what trade-off? |

### Design decisions worth noting

- **Recursive CTE performance.** The recursive member joins a pre-filtered `fraud_transfers` CTE (4,097 rows) instead of the 6.36M-row base table. Depth is capped at 5, and `step` must strictly increase between hops so chains cannot cycle.
- **Single-pass scorecard.** All three rules are flagged in one CTE and scored with `SUM(flag * isFraud)`, so the table is scanned once, not once per rule.
- **Floating-point tolerance.** Balance checks use `ABS(a - b) < 0.01` rather than exact equality.
- **Merchant exclusion.** Reconciliation analysis excludes merchant destinations (`M...`), whose balances aren't tracked in PaySim.
- **Window over time, not accounts.** Only 9,298 of 6.35M sender accounts transact more than once, and none has a second fraud, so a per-account rolling count could never exceed 1.

---

## Limitations (read before citing the numbers)

- **The 97.6% / 100% result is largely a property of the simulator.** PaySim's fraud generator empties the victim's account completely, so "amount equals sender balance" separates fraud from legitimate activity almost perfectly. Real-world fraud is rarely this clean, and in production this rule would need to be combined with other signals.
- **No train/test split.** The rules are simple, hand-written, and have no fitted parameters, but they were designed and scored on the same data.
- **Recall gap.** The drained-balance rule misses 195 fraud cases (2.4%).
- **The reconciliation gap is a risk ratio, not a detection rule.** Mismatch captures 99.95% of fraudulent transfers, but only 3.39% of mismatched transfers are fraud, so on its own it would generate about 29 false alarms per true hit. The matched-group rate rests on just 2 fraud cases out of 412,098, so the exact ratio is unstable.
- **The reconciliation signal is `TRANSFER`-specific.** For `CASH_OUT` the pattern is reversed (0.21% fraud among matches vs 0.11% among mismatches).
- **No multi-hop layering exists in this data.** The recursive CTE is a valid check but returned only depth-1 chains. Re-run it on real transaction data before drawing conclusions about layering.
- **The system-flag baseline is weak.** `isFlaggedFraud` fires on only 16 rows, so beating its recall is a low bar.

---

## Repository Contents

```
.
├── fraud_detection_analysisFF.sql   # Full annotated analysis (Sections 0-6)
└── README.md
```

The dataset (~490 MB) is not included. Download it from Kaggle (link above).

---

## How to Run

**Requirements:** MySQL 8.0+ (CTEs, recursive CTEs, and window functions).

1. **Download** `PS_20174392719_1491204439457_log.csv` from the [PaySim Kaggle page](https://www.kaggle.com/datasets/ealaxi/paysim1).

2. **Create the table:**

   ```sql
   CREATE DATABASE IF NOT EXISTS bank;
   USE bank;

   CREATE TABLE transactions (
       step            INT,
       type            VARCHAR(10),
       amount          DECIMAL(16,2),
       nameOrig        VARCHAR(20),
       oldbalanceOrg   DECIMAL(16,2),
       newbalanceOrig  DECIMAL(16,2),
       nameDest        VARCHAR(20),
       oldbalanceDest  DECIMAL(16,2),
       newbalanceDest  DECIMAL(16,2),
       isFraud         TINYINT,
       isFlaggedFraud  TINYINT
   );
   ```

3. **Load the data** (adjust the path; you may need `SET GLOBAL local_infile = 1;`):

   ```sql
   LOAD DATA LOCAL INFILE '/path/to/PS_20174392719_1491204439457_log.csv'
   INTO TABLE transactions
   FIELDS TERMINATED BY ','
   IGNORE 1 LINES;
   ```

4. **Run** `fraud_detection_analysisFF.sql`. Section 0.1 creates two supporting indexes. Building them on 6.36M rows takes a moment.

---

## Data Dictionary

| Column | Description |
|---|---|
| `step` | Simulation hour (1-743) |
| `type` | `CASH_IN` · `CASH_OUT` · `DEBIT` · `PAYMENT` · `TRANSFER` |
| `amount` | Transaction amount |
| `nameOrig` / `nameDest` | Sender / recipient account ID (`C` = customer, `M` = merchant) |
| `oldbalanceOrg` / `newbalanceOrig` | Sender balance before / after |
| `oldbalanceDest` / `newbalanceDest` | Recipient balance before / after |
| `isFraud` | 1 = confirmed fraud |
| `isFlaggedFraud` | 1 = flagged by the platform's built-in large-transfer rule |

---

## Author

**Rajan Singh**
