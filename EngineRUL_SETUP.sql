/* =============================================================================
   EngineRUL  |  NASA C-MAPSS turbofan - Remaining Useful Life (RUL) project
   Complete SQL Server setup script, in the order it should be run.
   -----------------------------------------------------------------------------
   STEP 0  Find your server name           (needed by Python and Power BI)
   STEP 1  Create the database             EngineRUL
   STEP 2  Create the predictions table    dbo.rul_predictions   <- Python loads this
   STEP 3  Create the dataset dimension    dbo.dim_dataset       (FD001..FD004 info)
   STEP 4  Create the dashboard view       dbo.vw_rul_dashboard  <- Power BI reads this
   STEP 5  Verification queries            (run AFTER the Python loading step)
   STEP 6  Optional / maintenance          (commented out on purpose)

   How to use:
     1) Run STEPS 0-4 once (the whole file is safe to re-run: every object is
        only created if it does not already exist, and the view is replaced).
     2) Run the Python loading cell in each of the 4 notebooks (FD001..FD004).
     3) Run STEP 5 to confirm the data landed correctly.
     4) In Power BI: Get data -> SQL Server -> select dbo.vw_rul_dashboard.
   ============================================================================= */


/* -----------------------------------------------------------------------------
   STEP 0 - Server name
   Returns the exact server name to use in the Python connection string
   (SERVER=...) and in Power BI's SQL Server connection dialog.
   ----------------------------------------------------------------------------- */
SELECT @@SERVERNAME AS server_name;
GO


/* -----------------------------------------------------------------------------
   STEP 1 - Database
   Creates EngineRUL only if it is missing, then switches to it so every
   statement below runs inside this database.
   ----------------------------------------------------------------------------- */
IF DB_ID('EngineRUL') IS NULL
    CREATE DATABASE EngineRUL;
GO

USE EngineRUL;
GO


/* -----------------------------------------------------------------------------
   STEP 2 - Predictions table (fact table)
   One row per engine per dataset. The Python notebooks append the model output
   here (columns: dataset, engine_id, actual_rul, predicted_rul).
   The primary key (dataset, engine_id) blocks duplicate rows, so loading the
   same dataset twice cannot silently double-count engines.
   ----------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.rul_predictions', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.rul_predictions (
        dataset        VARCHAR(10) NOT NULL,   -- FD001, FD002, FD003 or FD004
        engine_id      INT         NOT NULL,   -- engine number inside its dataset
        actual_rul     FLOAT       NOT NULL,   -- true RUL (from NASA's RUL_FD00X.txt)
        predicted_rul  FLOAT       NOT NULL,   -- RUL predicted by the BiLSTM model
        CONSTRAINT PK_rul_predictions PRIMARY KEY (dataset, engine_id)
    );
END
GO

-- Safety net: if the table was created earlier WITHOUT the key, add it now.
IF NOT EXISTS (
    SELECT 1
    FROM sys.key_constraints
    WHERE name = 'PK_rul_predictions'
      AND parent_object_id = OBJECT_ID('dbo.rul_predictions')
)
    ALTER TABLE dbo.rul_predictions
        ADD CONSTRAINT PK_rul_predictions PRIMARY KEY (dataset, engine_id);
GO


/* -----------------------------------------------------------------------------
   STEP 3 - Dataset dimension table
   Describes each C-MAPSS dataset (number of operating conditions and fault
   modes). The view joins to it so Power BI can show the dataset description.
   ----------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.dim_dataset', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.dim_dataset (
        dataset              VARCHAR(10)  NOT NULL PRIMARY KEY,
        operating_conditions INT          NOT NULL,   -- 1 or 6
        fault_modes          INT          NOT NULL,   -- 1 or 2
        description          VARCHAR(100) NOT NULL
    );
END
GO

-- Fill the 4 datasets; rows that already exist are skipped (safe to re-run).
INSERT INTO dbo.dim_dataset (dataset, operating_conditions, fault_modes, description)
SELECT v.dataset, v.operating_conditions, v.fault_modes, v.description
FROM (VALUES
    ('FD001', 1, 1, '1 condition, 1 fault mode'),
    ('FD002', 6, 1, '6 conditions, 1 fault mode'),
    ('FD003', 1, 2, '1 condition, 2 fault modes'),
    ('FD004', 6, 2, '6 conditions, 2 fault modes')
) AS v(dataset, operating_conditions, fault_modes, description)
WHERE NOT EXISTS (
    SELECT 1 FROM dbo.dim_dataset d WHERE d.dataset = v.dataset
);
GO


/* -----------------------------------------------------------------------------
   STEP 4 - Dashboard view (the only object Power BI needs)
   Final version of the view. It replaces the earlier drafts: it caps the actual
   RUL at 125 and calculates the error against the capped value, so the error,
   MAE and RMSE all use the same scale as the model's training target.

   Columns added on top of rul_predictions:
     actual_rul_capped    actual RUL limited to 125 (standard C-MAPSS cap)
     actual_health_pct    actual RUL as % of 125, limited to 0..100
     pred_health_pct      predicted RUL as % of 125, limited to 0..100
     error                predicted - actual (capped); positive = model is too
                          optimistic about the remaining life (riskier)
     abs_error            absolute error (used for MAE)
     pred_status          Red (<20%) / Orange (20-<50%) / Green (50%+)
     actual_status        same rule applied to the actual RUL
     pred_color           hex color for Power BI conditional formatting
     operating_conditions, fault_modes, dataset_description   from dim_dataset
   ----------------------------------------------------------------------------- */
CREATE OR ALTER VIEW dbo.vw_rul_dashboard AS
WITH base AS (
    -- Layer 1: cap the RUL at 125 and convert it to a 0-100 health percentage
    SELECT dataset, engine_id, actual_rul, predicted_rul,
           CASE WHEN actual_rul > 125 THEN 125.0
                ELSE actual_rul END                      AS actual_rul_capped,
           CASE WHEN actual_rul > 125 THEN 100.0
                WHEN actual_rul < 0   THEN 0.0
                ELSE actual_rul / 125.0 * 100 END        AS actual_health_pct,
           CASE WHEN predicted_rul > 125 THEN 100.0
                WHEN predicted_rul < 0   THEN 0.0
                ELSE predicted_rul / 125.0 * 100 END     AS pred_health_pct
    FROM dbo.rul_predictions
)
-- Layer 2: errors, status labels, colors, and dataset details
SELECT b.*,
    b.predicted_rul - b.actual_rul_capped       AS error,
    ABS(b.predicted_rul - b.actual_rul_capped)  AS abs_error,
    -- Health status from the PREDICTED health: 0-20 Red, 20-50 Orange, 50+ Green
    CASE WHEN b.pred_health_pct < 20 THEN 'Red'
         WHEN b.pred_health_pct < 50 THEN 'Orange'
         ELSE 'Green' END                AS pred_status,
    -- Same rule applied to the ACTUAL health (for comparing true vs predicted)
    CASE WHEN b.actual_health_pct < 20 THEN 'Red'
         WHEN b.actual_health_pct < 50 THEN 'Orange'
         ELSE 'Green' END                AS actual_status,
    -- Hex color Power BI reads in Conditional formatting -> Field value
    CASE WHEN b.pred_health_pct < 20 THEN '#E53935'
         WHEN b.pred_health_pct < 50 THEN '#FB8C00'
         ELSE '#43A047' END              AS pred_color,
    d.operating_conditions,
    d.fault_modes,
    d.description                        AS dataset_description
FROM base b
LEFT JOIN dbo.dim_dataset d ON d.dataset = b.dataset;
GO


/* =============================================================================
   STEP 5 - Verification (run after the 4 notebooks have loaded their data)
   ============================================================================= */

-- 5.1  Dataset dimension: should return 4 rows (FD001..FD004).
SELECT * FROM dbo.dim_dataset;

-- 5.2  Engines loaded per dataset: expected 100 / 259 / 100 / 248.
SELECT dataset, COUNT(*) AS n
FROM dbo.rul_predictions
GROUP BY dataset
ORDER BY dataset;

-- 5.3  Raw predictions table: expected 707 rows in total.
SELECT * FROM dbo.rul_predictions;

-- 5.4  Engines per health status: should match the Power BI cards
--      (Green = Healthy 437, Orange = Warning 146, Red = Critical 124).
SELECT pred_status, COUNT(*) AS engines
FROM dbo.vw_rul_dashboard
GROUP BY pred_status;

-- 5.5  Engines and mean absolute error (MAE) per dataset.
SELECT dataset, COUNT(*) AS engines, AVG(abs_error) AS mae
FROM dbo.vw_rul_dashboard
GROUP BY dataset
ORDER BY dataset;
GO
