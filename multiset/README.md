# CDC Multiset State Materialization (SQL Server / Azure SQL)

## Overview

This project materializes **current row state** from **SQL Server CDC** into a derived table using a **multiset (bag) model**.  
It is designed to work **without relying on a primary key** on the source table.

The approach replays CDC change events incrementally, maintaining a state table that reflects the **current set of row images** implied by CDC up to a tracked watermark.

---

## Architecture Diagram

```
┌──────────────┐
│  Source DB   │
│ (User Tables)│
└──────┬───────┘
       │ DML (INSERT / UPDATE / DELETE)
       ▼
┌──────────────┐
│ SQL Server   │
│ Transaction  │
│ Log          │
└──────┬───────┘
       │ (CDC Capture Job)
       ▼
┌────────────────────────┐
│ cdc.<capture>_CT table │
│  - __$start_lsn        │
│  - __$seqval           │
│  - __$operation        │
│  - captured columns   │
└──────┬─────────────────┘
       │ (scheduled poll)
       ▼
┌──────────────────────────────┐
│ dbo.apply_cdc_multiset_*     │
│  - read watermark            │
│  - select new CT rows        │
│  - compute row_json + hash   │
│  - apply +/- deltas          │
│  - advance watermark         │
└──────┬───────────────────────┘
       │
       ▼
┌──────────────────────────────┐
│ dbo.cdc_multiset_state       │
│  - row_json                  │
│  - row_sig                   │
│  - row_count                 │
│  - last_lsn / last_seq       │
└──────────────────────────────┘
```

---

## Core Concepts

See **OPERATIONS.md** for detailed operational behavior, rebuild procedures, automation, and debugging guidance.

---

## Summary

This system:
- Replays CDC events incrementally
- Maintains a multiset of current row images
- Uses `(LSN, SEQ, OP)` to avoid UPDATE edge cases
- Advances watermark only based on `_CT`
- Requires scheduled polling for automation

For operational details, see **OPERATIONS.md**.
