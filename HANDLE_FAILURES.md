# OpenFlow CDC Failure Handling

## Question

When errors occur in the Incremental Load processor group and the `MultiDatabaseUpdateTableState` processor marks replication as failed, does OpenFlow capture the previous records that failed when the problem is resolved?

## Answer

**No, OpenFlow does NOT automatically capture failed records when the problem is resolved.**

The failed records are lost and require a full re-snapshot of the affected table to recover.

---

## How the Error Handling Flow Works

### 1. Error Detection

Various processors in the Incremental Load group detect failures and route FlowFiles to "Update Failure Reason" processors that set a `failure.reason` attribute:

| Failure Type | Trigger |
|--------------|---------|
| `SNOWPIPE_UPLOAD_FAILED` | Upload to Snowpipe Streaming fails |
| `VALUE_MAPPING_ERROR` | Data type conversion fails |
| `CONTENT_MERGE_FAILED` | FlowFile merging fails |
| `SNOWFLAKE_OBJECT_OPERATION_FAILED` | DDL operations fail (alter table, create stream, etc.) |

### 2. Mark Table as Failed

The `MultiDatabaseUpdateTableState` processor ("Mark Replication as Failed"):
- Updates the table state to `Failed` in the TableStateService
- Records the failure reason from the `failure.reason` attribute
- Configuration: `Desired State = Failed`, `Overwrite Existing = true`

### 3. FlowFile Termination

All relationships on the "Mark Replication as Failed" processor are set to **auto-terminate**:
- `success` - auto-terminated
- `state exists` - auto-terminated  
- `comms failure` - retries, then auto-terminated

This means the FlowFile containing the failed records is **dropped** after the table state is updated.

---

## Why Records Are Lost

The CDC connector uses SQL Server Change Tracking (CT) tables, which operate as a **forward-only** log:

1. **CT Position Advances** - The change tracking position continues moving forward regardless of failures
2. **FlowFiles Are Dropped** - Failed records are discarded when the FlowFile is auto-terminated
3. **No Replay Mechanism** - When the problem is resolved, the connector resumes from the current CT position, not from where the failure occurred

---

## Table Replication States

The TableStateService tracks each table with one of these states:

| State | Meaning |
|-------|---------|
| `NEW` | Table discovered, replication not started |
| `SNAPSHOT_REPLICATION` | Initial snapshot in progress |
| `INCREMENTAL_REPLICATION` | Streaming real-time changes |
| `FAILED` | Replication failed (see failure reason) |

---

## Recovery Process

To recover a table in `FAILED` state and recapture missed records, a **full re-snapshot** is required:

### Step 1: Remove Table from Replication

Update the connector parameters to exclude the failed table from both:
- `Included Table Names`
- `Included Table Regex`

### Step 2: Wait for State Cleanup

Allow time for the change to propagate and verify the table is removed from the TableStateService.

### Step 3: Drop Destination Table in Snowflake

```sql
-- Use quoted identifiers if Object Identifier Resolution = CASE_SENSITIVE
DROP TABLE "<schema>"."<failed_table>";
```

### Step 4: Re-add Table to Replication

Update the inclusion parameters to add the table back. This triggers a fresh snapshot that will:
- Re-read all current data from the source table
- Recreate the destination table in Snowflake
- Resume incremental replication from the current CT position

---

## Key Takeaways

1. **Failed records are not automatically recovered** - They are dropped when the table is marked as failed
2. **Recovery requires a full re-snapshot** - There is no way to replay just the failed changes
3. **Act quickly on failures** - The longer a table stays in FAILED state, the more changes accumulate that will need to be re-captured via snapshot
4. **Monitor table states** - Use the TableStateService to detect FAILED tables before too much data is missed
