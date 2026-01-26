ALTER TABLE SalesLT.Product DISABLE CHANGE_TRACKING;
ALTER DATABASE "sql-db-0408286" SET CHANGE_TRACKING = OFF;

SELECT * FROM sys.change_tracking_databases WHERE database_id = DB_ID('sql-db-0408286');
SELECT t.name, c.is_track_columns_updated_on 
FROM sys.change_tracking_tables c JOIN sys.tables t ON c.object_id = t.object_id WHERE t.name = 'sql-db-0408286';

EXEC sys.sp_cdc_enable_db

EXEC sys.sp_cdc_enable_table
    @source_schema = N'SalesLT',
    @source_name   = N'Product',
    @role_name     = NULL,
    @supports_net_changes = 0;

SELECT * FROM cdc.change_tables;
GO
