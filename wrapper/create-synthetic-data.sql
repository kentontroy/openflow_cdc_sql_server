DROP TABLE IF EXISTS dbo.test_sales_events;
GO

CREATE TABLE dbo.test_sales_events (
  sku varchar(200) NOT NULL,
  region varchar(50) NOT NULL, 
  channel varchar(50) NOT NULL,
  event_type varchar(50) NOT NULL, 
  price decimal(12,2)  NOT NULL,
  ts datetime2(3)   NOT NULL,
  CONSTRAINT PK_YourTable PRIMARY KEY CLUSTERED (sku, region, channel)
);
GO

DECLARE @rows int = 10000;

DECLARE @sku_cnt     int = 417;  -- minimum to reach 10,000 unique PKs with 6 regions and 4 channels
DECLARE @region_cnt  int = 6;
DECLARE @channel_cnt int = 4;

-- Sanity check: ensure we have enough unique PK combinations
DECLARE @max_rows int = @sku_cnt * @region_cnt * @channel_cnt;
IF @rows > @max_rows
BEGIN
  THROW 50001, 'Not enough unique (sku, region, channel) combinations for the requested @rows.', 1;
END;

WITH n AS (
  SELECT TOP (@rows)
    ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS rn0  -- 0-based
  FROM sys.all_objects a
  CROSS JOIN sys.all_objects b
),
dims AS (
  SELECT
    rn0,

    -- Unique PK enumeration across sku x region x channel
    CONCAT('SKU-', FORMAT(rn0 % @sku_cnt, '0000')) AS sku,

    CASE ((rn0 / (@sku_cnt * @channel_cnt)) % @region_cnt)
      WHEN 0 THEN 'US-NE'
      WHEN 1 THEN 'US-SE'
      WHEN 2 THEN 'US-MW'
      WHEN 3 THEN 'US-SW'
      WHEN 4 THEN 'US-W'
      ELSE 'CA'
    END AS region,

    CASE ((rn0 / @sku_cnt) % @channel_cnt)
      WHEN 0 THEN 'WEB'
      WHEN 1 THEN 'STORE'
      WHEN 2 THEN 'PARTNER'
      ELSE 'MARKETPLACE'
    END AS channel,

    -- Keep your existing event generation logic
    CASE rn0 % 5
      WHEN 0 THEN 'PRICE_SET'
      WHEN 1 THEN 'DISCOUNT'
      WHEN 2 THEN 'RESTOCK'
      WHEN 3 THEN 'SALE'
      ELSE 'RETURN'
    END AS event_type,

    DATEADD(minute, rn0 + 1, '2025-01-01T00:00:00') AS ts,

    -- Deterministic base price per SKU (10.00 to ~343.60 with 417 SKUs)
    CAST(10.00 + (rn0 % @sku_cnt) * 0.80 AS decimal(12,2)) AS price
  FROM n
),
events AS (
  SELECT
    rn0,
    sku, region, channel, event_type, price, ts,
    CASE event_type
      WHEN 'PRICE_SET' THEN price
      WHEN 'DISCOUNT'  THEN CAST(price * (CASE WHEN rn0 % 3 = 0 THEN 0.90 WHEN rn0 % 3 = 1 THEN 0.80 ELSE 0.70 END) AS decimal(12,2))
      WHEN 'SALE'      THEN CAST(price * (CASE WHEN rn0 % 4 = 0 THEN 1.00 WHEN rn0 % 4 = 1 THEN 0.95 WHEN rn0 % 4 = 2 THEN 0.85 ELSE 0.75 END) AS decimal(12,2))
      WHEN 'RETURN'    THEN CAST(price * -1.00 AS decimal(12,2))
      ELSE price
    END AS amount
  FROM dims
)
INSERT INTO dbo.test_sales_events (sku, region, channel, event_type, price, ts)
SELECT
  sku, region, channel, event_type, price, ts
FROM events;

GO
