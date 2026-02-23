CREATE OR ALTER PROCEDURE dbo.enable_cdc_for_table
  @source_schema sysname,
  @source_name   sysname,
  @supports_net_changes bit = 0,
  @role_name sysname = NULL
AS
BEGIN
  SET NOCOUNT ON;

  -- Enable CDC at DB level if needed
  IF EXISTS (SELECT 1 FROM sys.databases WHERE name = DB_NAME() AND is_cdc_enabled = 1)
    PRINT 'CDC already enabled for database ' + QUOTENAME(DB_NAME()) + '.';
  ELSE
  BEGIN
    PRINT 'Enabling CDC for database ' + QUOTENAME(DB_NAME()) + '...';
    EXEC sys.sp_cdc_enable_db;
  END

  DECLARE @obj_id int = OBJECT_ID(QUOTENAME(@source_schema) + N'.' + QUOTENAME(@source_name));
  IF @obj_id IS NULL
    THROW 50000, 'Source table not found in current database.', 1;

  -- Enable CDC for table if not already enabled
  IF EXISTS (SELECT 1 FROM cdc.change_tables WHERE source_object_id = @obj_id)
    PRINT 'CDC already enabled for ' + QUOTENAME(@source_schema) + '.' + QUOTENAME(@source_name) + '.';
  ELSE
  BEGIN
    PRINT 'Enabling CDC for ' + QUOTENAME(@source_schema) + '.' + QUOTENAME(@source_name) + '...';
    EXEC sys.sp_cdc_enable_table
      @source_schema        = @source_schema,
      @source_name          = @source_name,
      @role_name            = @role_name,
      @supports_net_changes = @supports_net_changes;
  END

  SELECT * FROM cdc.change_tables ORDER BY capture_instance;
END;
GO
