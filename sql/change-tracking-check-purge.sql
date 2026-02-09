-- Purge the history
DECLARE @CaptureInstance VARCHAR(255);
SELECT @CaptureInstance = (SELECT capture_instance
FROM cdc.change_tables
WHERE
    OBJECT_SCHEMA_NAME(source_object_id) = 'dbo'
    AND OBJECT_NAME(source_object_id) = 'test_sales_events'
);
SELECT @CaptureInstance;

-- The sys.fn_cdc_get_max_lsn() system function in SQL Server does not 
-- take any parameters and returns the single, database-wide maximum 
-- LSN (Log Sequence Number) across all capture instances. 
-- All capture instances in a database share the same max sequence number
-- even though their min sequence number may be different
DECLARE @MaxLSN BINARY(10);
SELECT @MaxLSN = sys.fn_cdc_get_max_lsn();
EXEC sys.sp_cdc_cleanup_change_table 
    @capture_instance = @CaptureInstance,
    @low_water_mark = @MaxLSN

-- Declaring a variable and Setting to zero first
DECLARE @CleanupFailedBit INT;
SELECT @CleanupFailedBit = 0;

-- Execute cleanup and obtain output bit
EXECUTE sys.sp_cdc_cleanup_change_table
    @capture_instance = @CaptureInstance,
    @low_water_mark = @MaxLSN, 
    @threshold = 1,
    @fCleanupFailed = @CleanupFailedBit OUTPUT;

-- Leverage @cleanup_failed_bit output to check the status.
SELECT IIF (@CleanupFailedBit > 0, 'CLEANUP FAILURE', 'CLEANUP SUCCESS');

GO

