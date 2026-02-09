EXEC sys.sp_cdc_help_change_data_capture;

EXEC sys.sp_cdc_disable_table
  @source_schema = N'dbo',
  @source_name = N'test_sales_events',
  @capture_instance = N'dbo_test_sales_events';

EXEC sys.sp_cdc_help_change_data_capture;

-- EXEC sys.sp_cdc_disable_db;
GO
