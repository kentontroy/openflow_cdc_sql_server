/*
 AI: 
 If you tell me which of the three “latest” meanings you’re targeting 
 overall / per ProductID / incremental ETL), I can give you the exact query tuned for that caseħ

 PROMPT:
 Latest means the current row value after both INSERTS and UPDATES. Even though the table used for 
 testing has a primary key, I want an answer that assumes that no primary key exists on the source 
 table, i.e. I've already set supports_net_changes = 0 when enabling CDC.

 AI:
 CDC alone cannot reliably produce “current row state per row” without some stable row identifier.
 Because when there’s no PK/unique key (and supports_net_changes = 0), CDC gives you a log of changes, 
 but it has no guaranteed way to say “these N changes belong to the same logical row” over time.
 This is what Debezium/Openflow style pipelines do: treat CDC as an event stream and materialize state elsewhere.
 Even without a PK, you can do this if you create a surrogate row identity at capture time (or in the source).

 AI:
 If you truly need “current row values” downstream, the industry-standard approach is:
 Add a surrogate key in the source (preferred), OR
 If you cannot, add a surrogate key at ingestion time and accept the semantics:
 “row identity is defined by the row’s values at time of insert” (i.e., immutable identity)
 updates are treated as “new row version” events
 Minimal pattern in SQL Server (downstream state table)
 Create a state table that stores:
 all captured columns
 __source_lsn, __source_seqval (watermarking)
 a row_signature (hash of all captured columns)
 optionally a logical_row_id if you can derive one
 Then process CDC incrementally by LSN windows:
 apply INSERT (op 2) as insert into state
 apply UPDATE by deleting old image signature (op 3) and inserting new image signature (op 4)
 apply DELETE (op 1) by deleting the deleted row signature
 This gives you a “current multiset of rows” (again: ambiguous if duplicates exist, but consistent as a multiset).
 Key honesty: if two rows are identical across all captured columns, the hash collides by design (same signature) 
 and you lose which one is which. That’s the unavoidable consequence of “no PK”.
 If you truly need current row values per logical row: you need some identity (PK/unique key/surrogate key). CDC 
 without a key cannot guarantee it.
 If you can accept multiset semantics: materialize a state table using (op 3 deletes old image, op 4 inserts new 
 image, op 2 inserts, op 1 deletes) keyed by a full-row signature.
 The trick is: instead of storing “one row per signature”, store (signature, row_payload, count). Then apply CDC events as deltas:

INSERT (op = 2): +1 for the new row image
DELETE (op = 1): -1 for the deleted row image
UPDATE (op = 3): -1 for the old row image
UPDATE (op = 4): +1 for the new row image

PROMPT:
Understood. The challenge though is that I need a pattern that has less maintenance given the large number of tables not having a 
primary key and targeted for CDC. That said, please explore Option A where I would store the row as JSON + signature + count

AI:
Below is a pattern I’ve used for this exact “many tables, no PK, CDC” scenario in SQL Server:
A single generic state table
A single generic watermark table
A single stored procedure that:
reads from any CDC change table
builds a canonical JSON object from the row using metadata (no per-table code)
hashes that canonical JSON to a signature
applies multiset deltas into the generic state table
This minimizes maintenance to “register capture instances”, not “write per-table procedures”.
*/

CREATE TABLE dbo.cdc_multiset_state (
  capture_instance sysname        NOT NULL,
  row_sig          varbinary(32)  NOT NULL,   -- SHA2_256
  row_json         nvarchar(max)  NOT NULL,   -- canonical JSON payload
  row_count        bigint         NOT NULL,
  last_lsn         binary(10)     NULL,
  last_seq         binary(10)     NULL,
  CONSTRAINT PK_cdc_multiset_state PRIMARY KEY (capture_instance, row_sig)
);

CREATE TABLE dbo.cdc_multiset_watermark (
  capture_instance sysname    NOT NULL CONSTRAINT PK_cdc_multiset_watermark PRIMARY KEY,
  last_lsn         binary(10) NULL,
  last_seq         binary(10) NOT NULL CONSTRAINT DF_cdc_multiset_watermark_last_seq DEFAULT (0x00000000000000000000),
  last_op          int        NOT NULL CONSTRAINT DF_cdc_multiset_watermark_last_op  DEFAULT (0)
);

-- Initialize once per capture
INSERT INTO dbo.cdc_multiset_watermark (capture_instance, last_lsn, last_seq, last_op)
VALUES (N'dbo_cdc_multiset_state', sys.fn_cdc_get_min_lsn(N'dbo_cdc_multiset_state'), 0x00000000000000000000, 0);

SELECT * FROM dbo.cdc_multiset_watermark;
GO
