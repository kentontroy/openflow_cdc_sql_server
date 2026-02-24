# Incremental Load: Inner working and Schema change Detection 

This document explains how the **Incremental Load** processor group in OpenFlow detects and responds to source table schema changes, and provides details about the **Create Journal Table** child processor group.

## Overview

The Incremental Load processor group is responsible for reading data from the source database's CDC (Change Data Capture) stream and performing incremental replication for enabled tables. A key feature of this flow is its ability to detect schema changes in source tables and propagate those changes to the destination Snowflake tables.

## Architecture Components

### Controller Services

| Service | Type | Purpose |
|---------|------|---------|
| **Source Table Schema Registry** | `MultiDatabaseStateManagedCdcSchemaRegistry` | Maintains a registry of source table schemas and tracks schema generations |
| **Table State Store** | `MultiDatabaseStandardTableStateService` | Tracks replication state for each table (New, Snapshot Replication, Incremental Replication, Failed) |
| **Table Column Filter** | `MultiDatabaseJsonTableColumnFilter` | Filters columns during replication based on configuration |

### Data Flow Summary

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           INCREMENTAL LOAD                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌──────────────────────┐                                                   │
│  │ Read SQLServer       │                                                   │
│  │ Change Tracking      │──► Set Source Table FQN ──► Determine Destination │
│  │ tables               │                                                   │
│  └──────────────────────┘                                                   │
│                                       │                                     │
│                                       ▼                                     │
│                          ┌────────────────────────┐                         │
│                          │ Merge Rows Into        │                         │
│                          │ Bigger FlowFiles       │                         │
│                          └────────────────────────┘                         │
│                                       │                                     │
│                                       ▼                                     │
│                    ┌─────────────────────────────────────┐                  │
│                    │      PROCESS SCHEMA CHANGES         │                  │
│                    │  (MultiDatabaseEnrichCdcStream)     │                  │
│                    └─────────────────────────────────────┘                  │
│                         │           │           │                           │
│                    success    schema update   failure                       │
│                         │           │           │                           │
│                         ▼           ▼           ▼                           │
│                    ┌────────┐  ┌─────────────────┐  ┌──────────────┐       │
│                    │Upload  │  │ Create Journal  │  │Mark as Failed│       │
│                    │to      │  │ Table (PG)      │  └──────────────┘       │
│                    │Snowpipe│  └─────────────────┘                         │
│                    └────────┘                                               │
│                         │                                                   │
│                         ▼                                                   │
│                    ┌────────────────────────────────────┐                  │
│                    │ Wait for Snapshot Load to Finish   │                  │
│                    └────────────────────────────────────┘                  │
│                         │                                                   │
│                         ▼                                                   │
│                    ┌────────────────────────────────────┐                  │
│                    │     Merge Journal to Destination   │                  │
│                    └────────────────────────────────────┘                  │
│                         │                                                   │
│                    ddl  │                                                   │
│                         ▼                                                   │
│                    ┌────────────────────────────────────┐                  │
│                    │      Alter Destination Table       │                  │
│                    └────────────────────────────────────┘                  │
│                         │                                                   │
│                         ▼                                                   │
│                    ┌────────────────────────────────────┐                  │
│                    │         Drop Journal Stream        │                  │
│                    └────────────────────────────────────┘                  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Schema Change Detection

### How Schema Changes Are Detected

The **Process Schema Changes** processor (`MultiDatabaseEnrichCdcStream`) is the central component for schema change detection. It performs the following:

1. **Reads incoming CDC records** from the source database
2. **Compares the current record schema** against the registered schema in the **Source Table Schema Registry**
3. **Detects DDL events** such as column additions, column removals, or type changes
4. **Routes FlowFiles** based on whether schema changes are detected

### Process Schema Changes Processor

| Property | Value |
|----------|-------|
| **Type** | `com.snowflake.openflow.runtime.processors.database.MultiDatabaseEnrichCdcStream` |
| **Description** | Handles DDL events from the CDC stream, checking whether the journal and destination table need to be updated |

#### Output Relationships

| Relationship | Description |
|--------------|-------------|
| `success` | Records with no schema changes - proceeds to Snowpipe upload |
| `schema update` | DDL events detected - triggers journal table recreation |
| `skipped ddl event` | DDL events that don't require action |
| `table not in state` | Tables not being tracked for replication |
| `failure` | Processing errors - marks replication as failed |

### Schema Generation Tracking

The system uses a **schema generation** counter (`table.schema.generation`) to track schema versions:

- Each schema change increments the generation number
- Journal tables are named with the generation suffix: `{TABLE_NAME}_JOURNAL_{generation}`
- This allows multiple journal table versions to coexist during schema transitions

---

## Schema Change Response Flow

When a schema change is detected, the following sequence occurs:

### Step 1: Schema Update Detection

The `Process Schema Changes` processor detects a schema mismatch and routes the FlowFile to the `schema update` relationship.

### Step 2: Journal Table Recreation

The FlowFile is sent to the **Create Journal Table** processor group (see detailed section below), which:
- Converts the new schema to journal format
- Creates a new journal table with the updated generation number
- Creates a corresponding Snowflake stream on the new journal table

### Step 3: Destination Table Alteration

The **Alter Destination Table** processor (`UpdateSnowflakeTable`) modifies the destination table to match the new schema:

| Property | Value | Description |
|----------|-------|-------------|
| **Update Type** | `Alter Table` | Performs ALTER TABLE operations |
| **Add Column Strategy** | `Alter Table` | Adds new columns via ALTER |
| **Drop Column Strategy** | `Alter Table` | Handles column drops via ALTER |
| **Column Removal Strategy** | `Rename Column` | Renames removed columns with suffix |
| **Removed Column Name Suffix** | `__SNOWFLAKE_DELETED` | Suffix for soft-deleted columns |
| **Alter Column Type Strategy** | `Fail` | Type changes cause failure (requires manual intervention) |

### Step 4: Old Journal Stream Cleanup

The **Drop Journal Stream** processor removes the Snowflake stream associated with the old journal table generation.

### Drop First DDL Logic

A `RouteOnAttribute` processor called **Drop First DDL** prevents the initial schema registration from triggering unnecessary DDL operations:

```
Condition: ${table.schema.initial:equals(true):not()}
```

This ensures that only subsequent schema changes (not the initial schema) trigger the full DDL propagation workflow.

---

## Create Journal Table Processor Group

### Purpose

The **Create Journal Table** processor group is a child of Incremental Load that handles the creation of journal tables in Snowflake.

> **Important**: Journal tables are used for **ALL** CDC replication, not just schema changes. Every INSERT, UPDATE, and DELETE from the source flows through a journal table before being merged into the destination.

### When is Create Journal Table Invoked?

| Scenario | What Happens |
|----------|--------------|
| **Initial table setup** | Creates the first journal table (e.g., `CUSTOMER_JOURNAL_1`) and its stream |
| **Schema change detected** | Creates a NEW journal table with incremented generation (e.g., `CUSTOMER_JOURNAL_2`) |
| **Normal DML operations** | Uses the EXISTING journal table - no new creation needed |

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    JOURNAL TABLE LIFECYCLE                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  INITIAL SETUP                     NORMAL OPERATION                         │
│  ─────────────────                 ─────────────────                        │
│  Table first enabled               All DML (INSERT/UPDATE/DELETE)           │
│         │                                   │                               │
│         ▼                                   ▼                               │
│  ┌─────────────────┐               ┌─────────────────┐                      │
│  │ Create Journal  │               │ Use EXISTING    │                      │
│  │ Table Group     │               │ Journal Table   │  (no creation)       │
│  └─────────────────┘               └─────────────────┘                      │
│         │                                   │                               │
│         ▼                                   ▼                               │
│  CUSTOMER_JOURNAL_1          ───►  CUSTOMER_JOURNAL_1  ───►  CUSTOMER       │
│  (new table created)               (receives all DML)        (destination)  │
│                                                                             │
│                                                                             │
│  SCHEMA CHANGE                                                              │
│  ─────────────────                                                          │
│  Column added/removed                                                       │
│         │                                                                   │
│         ▼                                                                   │
│  ┌─────────────────┐                                                        │
│  │ Create Journal  │                                                        │
│  │ Table Group     │  (invoked again)                                       │
│  └─────────────────┘                                                        │
│         │                                                                   │
│         ▼                                                                   │
│  CUSTOMER_JOURNAL_2          ───►  Future DML goes here                     │
│  (NEW table created)                                                        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### How It Works: Journal Tables and Snowflake Streams

The replication process uses two key Snowflake objects working together for **all data changes**:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     HOW CDC REPLICATION WORKS                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   SOURCE DATABASE                      SNOWFLAKE                            │
│   ┌──────────────┐                    ┌──────────────────────────────────┐ │
│   │              │                    │                                  │ │
│   │  Customer    │   CDC Records      │  CUSTOMER_JOURNAL_1  (table)     │ │
│   │  Table       │ ─────────────────► │  ┌────────────────────────────┐  │ │
│   │              │   (INSERT,         │  │ ID | NAME | OP  | _COMMIT  │  │ │
│   │              │    UPDATE,         │  │ 1  | Bob  | I   | 00001    │  │ │
│   │              │    DELETE)         │  │ 1  | Rob  | U   | 00002    │  │ │
│   └──────────────┘                    │  │ 2  | Sue  | I   | 00003    │  │ │
│                                       │  └────────────────────────────┘  │ │
│                                       │              │                   │ │
│                                       │              │                   │ │
│                                       │  CUSTOMER_JOURNAL_1_STREAM       │ │
│                                       │  ┌────────────────────────────┐  │ │
│                                       │  │ "I see 3 new rows that     │  │ │
│                                       │  │  haven't been merged yet"  │  │ │
│                                       │  └────────────────────────────┘  │ │
│                                       │              │                   │ │
│                                       │              │ MERGE             │ │
│                                       │              ▼                   │ │
│                                       │  CUSTOMER  (destination table)   │ │
│                                       │  ┌────────────────────────────┐  │ │
│                                       │  │ ID | NAME                  │  │ │
│                                       │  │ 1  | Rob   (was Bob)       │  │ │
│                                       │  │ 2  | Sue                   │  │ │
│                                       │  └────────────────────────────┘  │ │
│                                       │                                  │ │
│                                       └──────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

### How PutSnowpipeStreaming Uses the Journal Table

The **Upload Rows via Snowpipe Streaming** processor (`PutSnowpipeStreaming`) is the component that writes CDC records into the journal table. Here's how it works:

#### Step 1: Target Table Configuration

The processor is configured to write to the **journal table**, not the destination table:

| Property | Value |
|----------|-------|
| **Table** | `${destination.table.name}_JOURNAL_${table.schema.generation}` |
| **Schema** | `${destination.schema.name}` |
| **Database** | `#{Destination Database}` |

For example, if replicating a `CUSTOMER` table with schema generation `1`, the processor writes to:
```
DESTINATION_DB.NIFI_DBO.CUSTOMER_JOURNAL_1
```

#### Step 2: Snowpipe Streaming Ingestion

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                   SNOWPIPE STREAMING FLOW                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  FlowFile containing CDC records (JSON)                                     │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ {"ID":1,"NAME":"Bob","_CDC_OP":"I","_CDC_COMMIT_VERSION":100}       │   │
│  │ {"ID":1,"NAME":"Rob","_CDC_OP":"U","_CDC_COMMIT_VERSION":101}       │   │
│  │ {"ID":2,"NAME":"Sue","_CDC_OP":"I","_CDC_COMMIT_VERSION":102}       │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                              │                                              │
│                              ▼                                              │
│              ┌───────────────────────────────┐                              │
│              │  PutSnowpipeStreaming         │                              │
│              │  ─────────────────────────────│                              │
│              │  • Opens streaming channel    │                              │
│              │  • Reads JSON records         │                              │
│              │  • Streams to Snowflake       │                              │
│              │  • Confirms delivery          │                              │
│              └───────────────────────────────┘                              │
│                              │                                              │
│                              ▼                                              │
│              ┌───────────────────────────────┐                              │
│              │  CUSTOMER_JOURNAL_1           │  (Snowflake Table)           │
│              │  ─────────────────────────────│                              │
│              │  ID | NAME | _CDC_OP | ...    │                              │
│              │  1  | Bob  | I       | ...    │                              │
│              │  1  | Rob  | U       | ...    │                              │
│              │  2  | Sue  | I       | ...    │                              │
│              └───────────────────────────────┘                              │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Key Configuration Properties:**

| Property | Value | Purpose |
|----------|-------|---------|
| **Delivery Guarantee** | `At least once` | Ensures no data loss |
| **Client Lag** | `1 sec` | Max time before flushing to Snowflake |
| **Max Batch Size** | `5000` | Records per batch |
| **Concurrency Group** | `${destination.schema.name}.${destination.table.name}` | Ensures ordered writes per table |

#### Step 3: The Merge Process

After PutSnowpipeStreaming writes to the journal table, the **Merge Journal to Destination** processor reads from the journal table's **Stream** and applies changes to the destination:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        THE COMPLETE FLOW                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  1. CAPTURE                    2. UPLOAD                   3. MERGE         │
│  ───────────                   ─────────                   ─────────        │
│                                                                             │
│  ┌─────────────┐              ┌─────────────┐             ┌─────────────┐   │
│  │ Read SQL    │              │ Snowpipe    │             │ Merge to    │   │
│  │ Server CDC  │──► FlowFile ─│ Streaming   │──► Journal ─│ Destination │   │
│  │ Tables      │              │ (upload)    │    Table    │ (MERGE SQL) │   │
│  └─────────────┘              └─────────────┘             └─────────────┘   │
│                                      │                           │          │
│                                      ▼                           ▼          │
│                               CUSTOMER_JOURNAL_1          CUSTOMER          │
│                               (staging table)             (final table)     │
│                                      │                           │          │
│                                      │                           │          │
│                               CUSTOMER_JOURNAL_1_STREAM          │          │
│                               (tracks unmerged rows)─────────────┘          │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Why this two-step process?**

1. **Snowpipe Streaming is fast** - Writes records to the journal table with sub-second latency
2. **MERGE is expensive** - Runs less frequently, batching many changes together
3. **Stream tracks progress** - Knows exactly which journal rows haven't been merged yet
4. **Failure isolation** - If MERGE fails, the data is safe in the journal table

---

### How the Merge is Scheduled and Executed

The merge from journal table to destination is **not** a Snowflake Task. Instead, it is controlled by NiFi processors and executed via SQL against Snowflake.

#### Where is "Merge Journal to Destination" in the Flow?

The `Merge Journal to Destination` processor is located in the **Incremental Load** processor group. Here is its position in the data flow:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                  INCREMENTAL LOAD - Merge Path                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Upload Rows via Snowpipe Streaming                                         │
│  (PutSnowpipeStreaming)                                                     │
│         │                                                                   │
│         │ success                                                           │
│         ▼                                                                   │
│  Remove Rows from FlowFile ──────► Wait for Snapshot Load to Finish         │
│  (ReplaceText)                     (MultiDatabaseWaitForTableState)         │
│                                           │                                 │
│                                           │ success                         │
│                                           ▼                                 │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  Schedule Warehouse  (MergeContent)                                 │   │
│  │  • CRON Schedule: #{Merge Task Schedule CRON}                       │   │
│  │  • Batches FlowFiles by table before releasing                      │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                           │                                 │
│                                           │ merged                          │
│                                           ▼                                 │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  ★ Merge Journal to Destination ★                                   │   │
│  │    (MultiDatabaseMergeSnowflakeJournalTable)                        │   │
│  │                                                                     │   │
│  │  • Executes MERGE SQL against Snowflake                             │   │
│  │  • Reads from Journal Stream (unmerged rows)                        │   │
│  │  • Applies INSERTs, UPDATEs, DELETEs to destination table           │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                          │                    │                             │
│                     ddl  │                    │ failure                     │
│                          ▼                    ▼                             │
│              Alter Destination Table    Mark Replication as Failed          │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

#### The Merge Scheduling Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     MERGE SCHEDULING AND EXECUTION                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  Schedule Warehouse (MergeContent processor)                        │   │
│  │  ───────────────────────────────────────────                        │   │
│  │  • Scheduling: CRON_DRIVEN                                          │   │
│  │  • CRON Expression: #{Merge Task Schedule CRON}                     │   │
│  │  • Default: "* * * * * ?" (every second - continuous)               │   │
│  │  • Groups FlowFiles by: source.table.fqn                            │   │
│  │  • Max Bin Age: 10 seconds                                          │   │
│  │  • Purpose: Batch multiple changes before triggering merge          │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                              │                                              │
│                              │ (FlowFiles released on schedule)             │
│                              ▼                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  Merge Journal to Destination (MultiDatabaseMergeSnowflakeJournalTable) │
│  │  ───────────────────────────────────────────────────────────────────│   │
│  │  • Connects to Snowflake via Connection Pool                        │   │
│  │  • Reads from: JOURNAL_TABLE_STREAM (unmerged rows)                 │   │
│  │  • Executes: MERGE INTO destination_table ...                       │   │
│  │  • Retry Count: 10,000 attempts on failure                          │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                              │                                              │
│                              ▼                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  Snowflake executes MERGE statement                                 │   │
│  │  ───────────────────────────────────────────────────────────────────│   │
│  │                                                                     │   │
│  │  MERGE INTO CUSTOMER AS dest                                        │   │
│  │  USING (                                                            │   │
│  │    SELECT * FROM CUSTOMER_JOURNAL_1_STREAM                          │   │
│  │  ) AS src                                                           │   │
│  │  ON dest.ID = src.ID                                                │   │
│  │  WHEN MATCHED AND src._CDC_OP = 'D' THEN DELETE                     │   │
│  │  WHEN MATCHED AND src._CDC_OP = 'U' THEN UPDATE SET ...             │   │
│  │  WHEN NOT MATCHED AND src._CDC_OP = 'I' THEN INSERT ...             │   │
│  │                                                                     │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

#### Key Components

| Component | Type | Role |
|-----------|------|------|
| **Schedule Warehouse** | NiFi `MergeContent` processor | Controls WHEN merges happen via CRON schedule |
| **Merge Journal to Destination** | NiFi `MultiDatabaseMergeSnowflakeJournalTable` processor | Executes the MERGE SQL against Snowflake |
| **Snowflake Warehouse** | Snowflake compute | Runs the actual MERGE query |

#### The CRON Schedule Parameter

The merge frequency is controlled by the `Merge Task Schedule CRON` parameter:

| Setting | CRON Expression | Behavior |
|---------|-----------------|----------|
| **Continuous** (default) | `* * * * * ?` | Merge runs every second |
| **Every minute** | `0 * * * * ?` | Merge runs at the start of each minute |
| **Hourly** | `0 0 * * * ?` | Merge runs at the top of each hour |
| **Business hours only** | `* * 9-17 ? * MON-FRI` | Merge runs 9 AM - 5 PM weekdays |

**Why schedule merges?**

- **Cost control**: Snowflake warehouse only runs (and incurs cost) when merges execute
- **Batch efficiency**: Accumulating more changes before merging is more efficient
- **Off-peak processing**: Schedule merges during low-usage periods

#### How the MERGE SQL Works

The `Merge Journal to Destination` processor generates and executes a MERGE statement that:

1. **Reads from the Stream** - `CUSTOMER_JOURNAL_1_STREAM` returns only rows not yet consumed
2. **Matches on primary key** - Identifies existing rows in destination
3. **Applies changes by operation type**:
   - `_CDC_OP = 'I'` → INSERT new row
   - `_CDC_OP = 'U'` → UPDATE existing row  
   - `_CDC_OP = 'D'` → DELETE existing row
4. **Advances the Stream** - After successful MERGE, the Stream's offset advances automatically

```sql
-- Conceptual MERGE statement (generated by the processor)
MERGE INTO "NIFI_DBO"."CUSTOMER" AS dest
USING (
  SELECT * FROM "NIFI_DBO"."CUSTOMER_JOURNAL_1_STREAM"
) AS src
ON dest."ID" = src."ID"
WHEN MATCHED AND src."_CDC_OP" = 'D' THEN 
  DELETE
WHEN MATCHED AND src."_CDC_OP" IN ('U', 'I') THEN 
  UPDATE SET 
    dest."NAME" = src."NAME",
    dest."EMAIL" = src."EMAIL"
WHEN NOT MATCHED AND src."_CDC_OP" = 'I' THEN 
  INSERT ("ID", "NAME", "EMAIL") 
  VALUES (src."ID", src."NAME", src."EMAIL");
```

---

**Journal Table**: A staging table that receives all CDC records (inserts, updates, deletes) from the source. Each record includes the operation type and a commit sequence number.

**Snowflake Stream**: An object that watches the journal table and tracks which rows are "new" (not yet merged). Think of it as a bookmark that remembers: *"Last time I checked, I had processed up to row X."*

**The Merge Process**:
1. CDC records flow into the journal table
2. The Stream identifies which records are new since the last merge
3. A MERGE statement applies those changes to the destination table
4. The Stream automatically advances its bookmark

### Why This Design?

This two-object pattern provides several benefits:

1. **Exactly-once delivery**: The Stream guarantees each change is processed exactly once
2. **Batch efficiency**: Changes accumulate in the journal, then merge in batches (not row-by-row)
3. **Schema versioning**: The `_1` in `CUSTOMER_JOURNAL_1` is the schema generation - when the source schema changes, a new journal table (`CUSTOMER_JOURNAL_2`) is created
4. **Failure recovery**: If a merge fails, the Stream still knows where it left off

### Processor Group Details

| Property | Value |
|----------|-------|
| **Execution Engine** | STATELESS |
| **FlowFile Concurrency** | SINGLE_FLOWFILE_PER_NODE |
| **Parameter Context** | SQLServer Ingestion Parameters (1) |

### Processors in Create Journal Table

#### 1. Convert To Journal Schema

| Type | `MultiDatabaseConvertToJournalSchema` |
|------|---------------------------------------|
| **Purpose** | Converts the source table schema to the journal table schema format |
| **Description** | Adds CDC metadata columns (operation type, timestamps, etc.) to the base schema |

#### 2. Create Schema If Not Exists

| Type | `UpdateSnowflakeSchema` |
|------|-------------------------|
| **Purpose** | Ensures the destination schema exists in Snowflake |
| **Schema Name** | `${destination.schema.name}` |

#### 3. Create Journal Table

| Type | `UpdateSnowflakeTable` |
|------|------------------------|
| **Purpose** | Creates the journal table with the converted schema |
| **Table Name** | `${source.table.name}_JOURNAL_${table.schema.generation}` |
| **Update Type** | `Create Table` |
| **Creation Parameters** | `DEFAULT_DDL_COLLATION = ''` |
| **Constraints** | No primary key or NOT NULL constraints (staging table) |

#### 4. Create Journal Table Stream

| Type | `UpdateSnowflakeStream` |
|------|-------------------------|
| **Purpose** | Creates a Snowflake stream on the journal table for change tracking |
| **Stream Name** | `${source.table.name}_JOURNAL_${table.schema.generation}_STREAM` |
| **Source Table** | `${source.table.name}_JOURNAL_${table.schema.generation}` |
| **Stream Parameters** | `APPEND_ONLY=TRUE` |

The `APPEND_ONLY=TRUE` parameter optimizes the stream for insert-only operations, which is appropriate for journal tables that only receive new CDC records.

#### 5. Error Handling

If any step fails:
1. **Update Failure Reason**: Sets `failure.reason` to `SNOWFLAKE_OBJECT_OPERATION_FAILED`
2. **Mark Replication as Failed**: Updates the table state to `Failed` in the Table State Store

### Flow Diagram

```
         ┌──────────────────────────────────────────┐
         │         CREATE JOURNAL TABLE             │
         │           (Processor Group)              │
         ├──────────────────────────────────────────┤
         │                                          │
    ──►  │  ┌─────────────────────────────────┐    │
  (ddl   │  │    Convert To Journal Schema     │    │
  input) │  └─────────────────────────────────┘    │
         │                    │                     │
         │                    ▼ success             │
         │  ┌─────────────────────────────────┐    │
         │  │   Create Schema If Not Exists    │    │
         │  └─────────────────────────────────┘    │
         │                    │                     │
         │                    ▼ success             │
         │  ┌─────────────────────────────────┐    │
         │  │      Create Journal Table        │    │
         │  │  {TABLE}_JOURNAL_{generation}    │    │
         │  └─────────────────────────────────┘    │
         │                    │                     │
         │                    ▼ success             │
         │  ┌─────────────────────────────────┐    │
         │  │   Create Journal Table Stream    │    │
         │  │  {TABLE}_JOURNAL_{gen}_STREAM    │    │
         │  └─────────────────────────────────┘    │
         │                    │                     │
         │           failure  │  success/exists     │
         │              │     │                     │
         │              ▼     │                     │
         │  ┌─────────────────────────────────┐    │
         │  │   Mark Replication as Failed     │    │
         │  └─────────────────────────────────┘    │
         │                                          │
         └──────────────────────────────────────────┘
```

---

## Additional Components

### Merge Journal to Destination

After data is uploaded via Snowpipe Streaming, the **Merge Journal to Destination** processor (`MultiDatabaseMergeSnowflakeJournalTable`) performs the final merge:

| Property | Value |
|----------|-------|
| **Purpose** | Merges pending changes from journal table into destination |
| **DDL Handling** | Routes DDL events to `Alter Destination Table` |
| **Merge Query Retry Count** | 10000 |

### Stream Staleness Prevention

A sibling processor group handles **Stream Staleness Prevention**:

> *"Prevents streams on Journal tables to become stale when data is not actively pushed within the data retention period."*

This is critical because Snowflake streams can become stale if not consumed within the data retention period, which would break incremental replication.

---

## Configuration Parameters

Key parameters in the **SQLServer Ingestion Parameters** context:

| Parameter | Description |
|-----------|-------------|
| `Starting Change Tracking Position` | Where to start reading CDC changes |
| `Re-read Tables in State` | Whether to re-read tables already in tracking |
| `Included Table Regex` | Regex pattern for tables to include |
| `Included Table Names` | Explicit list of tables to include |
| `Column Filter JSON` | Column filtering configuration |
| `Merge Task Schedule CRON` | CRON schedule for merge operations |

---

## Error Handling and Recovery

### Failure States

When errors occur, the flow sets specific failure reasons:

| Failure Reason | Trigger |
|----------------|---------|
| `SNOWFLAKE_OBJECT_OPERATION_FAILED` | Failed to create/alter Snowflake objects |
| `SNOWPIPE_UPLOAD_FAILED` | Failed to upload data via Snowpipe |
| `CONTENT_MERGE_FAILED` | Failed to merge content or create FlowFiles |
| `VALUE_MAPPING_ERROR` | Failed to map source values to destination |

### Recovery Process

Tables marked as `Failed` require manual intervention:
1. Investigate the failure reason in the processor bulletins
2. Resolve the underlying issue (permissions, connectivity, schema conflicts)
3. Update the table state to allow retry
4. Restart the affected processors

---

## Best Practices

1. **Monitor Schema Registry**: Regularly check the Source Table Schema Registry for schema generation counts
2. **Review Merge Schedules**: Adjust `Merge Task Schedule CRON` based on data volume and latency requirements
3. **Handle Type Changes Manually**: Column type changes cause failures by design - plan schema migrations carefully
4. **Stream Retention**: Ensure merge operations run frequently enough to prevent stream staleness
5. **Soft Deletes**: Removed columns are renamed with `__SNOWFLAKE_DELETED` suffix rather than dropped, preserving data

---

## Related Documentation

- [Snowflake Streams Documentation](https://docs.snowflake.com/en/user-guide/streams-intro)
- [Change Data Capture Concepts](https://docs.snowflake.com/en/user-guide/streams-intro#data-retention-period-and-staleness)
- [OpenFlow Connector Documentation](https://docs.snowflake.com/en/user-guide/data-load-snowpipe-streaming-overview)
