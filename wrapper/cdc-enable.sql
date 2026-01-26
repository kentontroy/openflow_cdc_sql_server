EXEC sys.sp_cdc_enable_table
  @source_schema = N'dbo',
  @source_name   = N'cdc_test_sales_events',
  @role_name     = NULL,
  @supports_net_changes = 0;
GO
