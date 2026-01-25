-- CASE stops at the first matching WHEN
/* 
Compare multiset watermark vs latest op=4 tuple in CT for ProductID=707 
CASE stops at the first matching WHEN
*/

DECLARE
  @wm_lsn  binary(10),
  @wm_seq  binary(10),
  @wm_op   int,
  @ct_lsn  binary(10),
  @ct_seq  binary(10),
  @ct_op   int;

-- watermark (from dbo.cdc_multiset_watermark)
SELECT
  @wm_lsn = last_lsn,
  @wm_seq = last_seq,
  @wm_op  = last_op
FROM dbo.cdc_multiset_watermark
WHERE capture_instance = N'SalesLT_Product';

-- latest op=4 tuple for ProductID=707 (from cdc.SalesLT_Product_CT)
SELECT TOP (1)
  @ct_lsn = __$start_lsn,
  @ct_seq = __$seqval,
  @ct_op  = __$operation
FROM cdc.SalesLT_Product_CT
WHERE ProductID = 707
  AND __$operation = 4
ORDER BY __$start_lsn DESC, __$seqval DESC;

-- Show captured values
SELECT
  @wm_lsn AS wm_lsn, @wm_seq AS wm_seq, @wm_op AS wm_op,
  @ct_lsn AS ct_lsn, @ct_seq AS ct_seq, @ct_op AS ct_op;

-- Handle missing values
IF @wm_lsn IS NULL
BEGIN
  PRINT 'Watermark row not found (or last_lsn is NULL) for capture instance SalesLT_Product.';
  RETURN;
END;

IF @ct_lsn IS NULL
BEGIN
  PRINT 'No op=4 rows found in cdc.SalesLT_Product_CT for ProductID=707.';
  RETURN;
END;

-- Lexicographic compare: (wm_lsn, wm_seq, wm_op) ? (ct_lsn, ct_seq, ct_op)
DECLARE @cmp int;
SET @cmp =
  CASE
    WHEN @wm_lsn < @ct_lsn THEN -1
    WHEN @wm_lsn > @ct_lsn THEN  1
    WHEN @wm_seq < @ct_seq THEN -1
    WHEN @wm_seq > @ct_seq THEN  1
    WHEN @wm_op  < @ct_op  THEN -1
    WHEN @wm_op  > @ct_op  THEN  1
    ELSE 0
  END;

SELECT
  @cmp AS comparison_result,  -- -1 = watermark behind CT tuple, 0 = equal, 1 = watermark ahead
  CASE @cmp
    WHEN -1 THEN 'Watermark is BEHIND the CT tuple (apply should have work to do).'
    WHEN  0 THEN 'Watermark EQUALS the CT tuple (apply will do nothing for that tuple).'
    WHEN  1 THEN 'Watermark is AHEAD of the CT tuple (CT tuple will not be processed unless you rewind).'
  END AS interpretation;
