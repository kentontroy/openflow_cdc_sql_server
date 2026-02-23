SELECT COUNT(1) FROM dbo.test_sales_events;

SELECT TOP (10) *
FROM dbo.test_sales_events
ORDER BY NEWID();

SET NOCOUNT ON;

SELECT
  DB_NAME() AS db,
  @@SPID    AS spid,
  @@TRANCOUNT AS trancount,
  SESSIONPROPERTY('IMPLICIT_TRANSACTIONS') AS implicit_tran;
 /*
 <schema>_<table_name>_CT
 Keeping a history of all changes
 https://learn.microsoft.com/en-us/sql/relational-databases/system-tables/cdc-capture-instance-ct-transact-sql?view=sql-server-ver17
 __$operation == 1 = delete
 __$operation == 2 = insert
 __$operation == 3 = update (old values)
 __$operation == 4 = update (new values)
*/

EXEC sys.sp_cdc_help_jobs;

EXEC sys.sp_cdc_help_change_data_capture
    @source_schema = N'dbo',
    @source_name   = N'test_sales_events';

SELECT TOP(200) 
  __$start_lsn, __$seqval, __$operation,
  sku, region, channel, event_type, price, ts
FROM cdc.dbo_test_sales_events_CT s
ORDER BY __$start_lsn DESC, __$seqval DESC;

/*
SELECT capture_instance, state_rv, state_rv_bigint, row_count, row_json, last_lsn, last_seq
FROM dbo.cdc_multiset_state
WHERE capture_instance = N'dbo_test_sales_events'
ORDER BY state_rv_bigint DESC;
*/

GO