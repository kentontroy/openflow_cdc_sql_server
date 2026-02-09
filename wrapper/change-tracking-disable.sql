-- Disable CT for a table, and turn off DB CT only if no CT tables remain

EXEC dbo.disable_change_tracking_for_table
    @table_name = N'test_sales_events',
    @disable_db_if_unused = 1;
GO
