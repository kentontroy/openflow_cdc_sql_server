DROP TABLE IF EXISTS dbo.cdc_test_sales_events;
GO

CREATE TABLE dbo.cdc_test_sales_events (
  col_text   varchar(400)   NOT NULL,   -- encoded event dimensions
  col_number decimal(12,2)  NOT NULL,   -- price or amount
  col_ts     datetime2(3)   NOT NULL    -- event timestamp
);
GO

DECLARE @rows int = 10000;

WITH n AS (
  SELECT TOP (@rows)
    ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS rn
  FROM sys.all_objects a
  CROSS JOIN sys.all_objects b
),
dims AS (
  SELECT
    rn,
    CONCAT('SKU-', FORMAT(rn % 250, '0000'))      AS sku,
    CASE rn % 6
      WHEN 0 THEN 'US-NE'
      WHEN 1 THEN 'US-SE'
      WHEN 2 THEN 'US-MW'
      WHEN 3 THEN 'US-SW'
      WHEN 4 THEN 'US-W'
      ELSE 'CA'
    END                                          AS region,
    CASE rn % 4
      WHEN 0 THEN 'WEB'
      WHEN 1 THEN 'STORE'
      WHEN 2 THEN 'PARTNER'
      ELSE 'MARKETPLACE'
    END                                          AS channel,
    CASE rn % 5
      WHEN 0 THEN 'PRICE_SET'
      WHEN 1 THEN 'DISCOUNT'
      WHEN 2 THEN 'RESTOCK'
      WHEN 3 THEN 'SALE'
      ELSE 'RETURN'
    END                                          AS event_type,
    DATEADD(minute, rn, '2025-01-01T00:00:00')    AS ts,
    -- a deterministic base price per SKU (10.00 to ~209.00)
    CAST(10.00 + (rn % 250) * 0.80 AS decimal(12,2)) AS base_price
  FROM n
),
events AS (
  SELECT
    rn,
    sku, region, channel, event_type, ts,
    CASE event_type
      WHEN 'PRICE_SET' THEN base_price
      WHEN 'DISCOUNT'  THEN CAST(base_price * (CASE WHEN rn % 3 = 0 THEN 0.90 WHEN rn % 3 = 1 THEN 0.80 ELSE 0.70 END) AS decimal(12,2))
      WHEN 'SALE'      THEN CAST(base_price * (CASE WHEN rn % 4 = 0 THEN 1.00 WHEN rn % 4 = 1 THEN 0.95 WHEN rn % 4 = 2 THEN 0.85 ELSE 0.75 END) AS decimal(12,2))
      WHEN 'RETURN'    THEN CAST(base_price * -1.00 AS decimal(12,2))  -- negative amount to represent refunds
      ELSE base_price  -- RESTOCK keeps base_price; semantics in text
    END AS amount
  FROM dims
)
INSERT INTO dbo.cdc_test_sales_events (col_text, col_number, col_ts)
SELECT
  -- Encode richer context into the varchar (easy to parse later, still 1 varchar column)
  CONCAT(
    '{',
      '"sku":"', sku, '",',
      '"region":"', region, '",',
      '"channel":"', channel, '",',
      '"event_type":"', event_type, '",',
      '"batch":', (rn / 500), ',',
      '"dup_group":', (rn % 20),
    '}'
  ) AS col_text,
  amount     AS col_number,
  ts         AS col_ts
FROM events;

-- Add a deliberate duplicate block (same text/number/timestamp) to test multiset counts
INSERT INTO dbo.cdc_test_sales_events (col_text, col_number, col_ts)
SELECT TOP (200)
  col_text, col_number, col_ts
FROM dbo.cdc_test_sales_events
ORDER BY NEWID();
GO
