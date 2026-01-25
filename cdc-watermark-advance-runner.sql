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

/*
If _CT is empty (or there are no rows newer than the watermark), @to_* will be NULL 
and apply should return without updating the watermark. So it won’t jump forward in that case either.
So: with CT-derived @to_*, the watermark stays ≤ CT max tuple, always.

Consider the logic:

SELECT TOP (1) @to_lsn=__$start_lsn, @to_seq=__$seqval, @to_op=__$operation
FROM cdc.<instance>_CT
WHERE (tuple) > (watermark)
ORDER BY __$start_lsn DESC, __$seqval DESC, __$operation DESC;

UPDATE dbo.cdc_multiset_watermark
SET last_lsn=@to_lsn, last_seq=@to_seq, last_op=@to_op

*/
