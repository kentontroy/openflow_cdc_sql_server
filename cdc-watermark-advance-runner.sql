CREATE OR ALTER PROCEDURE dbo.apply_cdc_multiset_all
AS
BEGIN
  SET NOCOUNT ON;

  DECLARE @ci sysname;

  DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT capture_instance
    FROM cdc.change_tables;

  OPEN cur;
  FETCH NEXT FROM cur INTO @ci;

  WHILE @@FETCH_STATUS = 0
  BEGIN
    EXEC dbo.apply_cdc_multiset_generic @capture_instance = @ci;
    FETCH NEXT FROM cur INTO @ci;
  END

  CLOSE cur;
  DEALLOCATE cur;
END;
GO
