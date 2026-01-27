/*
ALTER TABLE dbo.cdc_multiset_state
ADD state_rv rowversion;

Existing rows get a row version value automatically
Future inserts/updates will bump it automatically

ALTER TABLE dbo.cdc_multiset_state
ADD is_deleted bit NOT NULL
    CONSTRAINT DF_cdc_multiset_state_is_deleted DEFAULT (0);
*/

CREATE TABLE dbo.cdc_multiset_state (
  capture_instance sysname        NOT NULL,
  row_sig          varbinary(32)  NOT NULL,   -- SHA2_256
  row_json         nvarchar(max)  NOT NULL,   -- canonical JSON payload
  row_count        bigint         NOT NULL,
  last_lsn         binary(10)     NULL,
  last_seq         binary(10)     NULL,
  CONSTRAINT PK_cdc_multiset_state PRIMARY KEY (capture_instance, row_sig)
);

CREATE TABLE dbo.cdc_multiset_watermark (
  capture_instance sysname    NOT NULL CONSTRAINT PK_cdc_multiset_watermark PRIMARY KEY,
  last_lsn         binary(10) NULL,
  last_seq         binary(10) NOT NULL CONSTRAINT DF_cdc_multiset_watermark_last_seq DEFAULT (0x00000000000000000000),
  last_op          int        NOT NULL CONSTRAINT DF_cdc_multiset_watermark_last_op  DEFAULT (0)
);

-- Initialize once per capture
INSERT INTO dbo.cdc_multiset_watermark (capture_instance, last_lsn, last_seq, last_op)
VALUES (N'dbo_cdc_multiset_state', sys.fn_cdc_get_min_lsn(N'dbo_cdc_multiset_state'), 0x00000000000000000000, 0);

SELECT * FROM dbo.cdc_multiset_watermark;
GO
