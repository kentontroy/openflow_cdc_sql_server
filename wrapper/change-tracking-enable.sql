EXEC dbo.enable_change_tracking_for_table
    @table_name = N'test_sales_events';
GO

DECLARE @LastSyncVersion BIGINT =
  CHANGE_TRACKING_MIN_VALID_VERSION(OBJECT_ID('dbo.test_sales_events'));
SELECT CT.*
FROM CHANGETABLE(CHANGES dbo.test_sales_events, @LastSyncVersion) AS CT;   

GO
