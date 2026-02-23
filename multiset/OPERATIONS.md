# OPERATIONS.md — CDC Multiset State

## State Tables

### cdc_multiset_state
Stores the *current multiset of row images*.

- Keyed by `(capture_instance, row_sig)`
- `row_count > 0` means the row image is alive
- Row images are represented as canonical JSON (`row_json`)

### cdc_multiset_watermark
Tracks progress through CDC.

```
(capture_instance, last_lsn, last_seq, last_op)
```

Meaning:
> “All CDC rows ≤ this tuple have already been processed.”

---

## Apply Procedure Logic

Each execution of `dbo.apply_cdc_multiset_generic` performs:

1. Read watermark
2. Select CDC rows where:
   ```
   (LSN, SEQ, OP) > watermark
   ```
3. Build `row_json` for each CT row
4. Apply deltas:
   - op 2 / 4 → +1
   - op 1 / 3 → -1
5. Merge into `cdc_multiset_state`
6. Advance watermark to the max CT tuple processed

---

## Why `(LSN, SEQ, OP)` Is Required

CDC UPDATEs emit two rows with the same `(LSN, SEQ)`:
- op=3 (before image)
- op=4 (after image)

Using `(LSN, SEQ, OP)` ensures:
```
(LSN, SEQ, 3) < (LSN, SEQ, 4)
```

This prevents skipping after-images.

---

## Rebuild Procedure

A correct rebuild must:

1. Clear state
2. Reset watermark to:
   ```
   (sys.fn_cdc_get_min_lsn(instance), 0x0, 0)
   ```
3. Replay CDC until watermark reaches CT max

Failure to rewind watermark while clearing state will permanently skip data.

---

## Automation

CDC does not push changes. You must poll.

### Recommended automation
- SQL Server: SQL Agent
- Azure SQL: Elastic Jobs / Azure Functions

Scheduled command:
```sql
EXEC dbo.apply_cdc_multiset_all;
```

Typical cadence: 30–60 seconds.

---

## Debugging Checklist

1. Is watermark < CT max tuple?
2. Is state empty while watermark is advanced?
3. Are op=3/op=4 sharing the same LSN/SEQ?
4. Was state cleared without rewinding watermark?

---

## Known Constraints

- No true PK → derived “current row”
- Eventual consistency (CDC async)
- JSON format must remain stable across rebuilds
