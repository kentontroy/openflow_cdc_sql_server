SET IMPLICIT_TRANSACTIONS OFF;

BEGIN TRANSACTION;

INSERT INTO dbo.test_sales_events (sku, region, channel, event_type, ts, price)
VALUES (
    'SKU-TEST-X-MARKED-FOR-DELETE',
    'US-W',
    'PARTNER',
    'PRICE_SET',
    DATEADD(DAY, 1, CAST(GETDATE() AS date)),
    0.00
);

DELETE FROM dbo.test_sales_events 
WHERE sku = 'SKU-TEST-X-MARKED-FOR-DELETE';

COMMIT TRANSACTION;
GO

SELECT @@TRANCOUNT;