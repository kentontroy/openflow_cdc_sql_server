EXEC dbo.enable_cdc_for_table 
  @source_schema = N'dbo',
  @source_name = N'test_sales_events',
  @supports_net_changes = 1;
GO
