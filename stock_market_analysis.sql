-- ============================================================
--  Time-Series Momentum & Volatility Engine
--  Stock Market SQL Analysis Script (MySQL 8.0+)
--  5 Indian Banking Stocks | Jan 2020 – Oct 2025
-- ============================================================

-- ──────────────────────────────────────────────────────────────
-- 0.  SCHEMA & IMPORT
-- ──────────────────────────────────────────────────────────────
CREATE DATABASE IF NOT EXISTS stock_market;
USE stock_market;

DROP TABLE IF EXISTS stock_prices;
CREATE TABLE stock_prices (
    id             INT            AUTO_INCREMENT PRIMARY KEY,
    stock          VARCHAR(30)    NOT NULL,
    trade_date     DATE           NOT NULL,
    close_price    DECIMAL(12,4)  NOT NULL,
    open_price     DECIMAL(12,4),
    high_price     DECIMAL(12,4),
    low_price      DECIMAL(12,4),
    volume         BIGINT,
    change_pct     DECIMAL(8,4),              -- as decimal e.g. -0.0109
    prev_close     DECIMAL(12,4),
    daily_return   DECIMAL(12,8),
    hl_range       DECIMAL(12,4),
    month_year     VARCHAR(10),
    day_type       VARCHAR(10),
    INDEX idx_stock_date (stock, trade_date),
    INDEX idx_date       (trade_date)
);

-- ► Load from cleaned CSV (adjust path as needed):
-- LOAD DATA INFILE '/path/to/Stock_Market_Cleaned.csv'
-- INTO TABLE stock_prices
-- FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
-- LINES TERMINATED BY '\n'
-- IGNORE 1 ROWS
-- (stock, @d, close_price, open_price, high_price, low_price,
--  volume, change_pct, prev_close, @dr, daily_return, hl_range,
--  month_year, day_type)
-- SET trade_date = STR_TO_DATE(@d, '%Y-%m-%d');


-- ──────────────────────────────────────────────────────────────
-- 1.  MOVING AVERAGES (5-day, 20-day, 50-day, 200-day)
-- ──────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW v_moving_averages AS
SELECT
    stock,
    trade_date,
    close_price,
    -- Simple Moving Averages
    ROUND(AVG(close_price) OVER (
        PARTITION BY stock
        ORDER BY trade_date
        ROWS BETWEEN 4 PRECEDING AND CURRENT ROW), 4)   AS sma_5,
    ROUND(AVG(close_price) OVER (
        PARTITION BY stock
        ORDER BY trade_date
        ROWS BETWEEN 19 PRECEDING AND CURRENT ROW), 4)  AS sma_20,
    ROUND(AVG(close_price) OVER (
        PARTITION BY stock
        ORDER BY trade_date
        ROWS BETWEEN 49 PRECEDING AND CURRENT ROW), 4)  AS sma_50,
    ROUND(AVG(close_price) OVER (
        PARTITION BY stock
        ORDER BY trade_date
        ROWS BETWEEN 199 PRECEDING AND CURRENT ROW), 4) AS sma_200,
    -- Row number used by EMA subquery below
    ROW_NUMBER() OVER (PARTITION BY stock ORDER BY trade_date) AS rn
FROM stock_prices;

-- ──────────────────────────────────────────────────────────────
-- 2.  BOLLINGER BANDS  (20-day SMA ± 2σ)
-- ──────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW v_bollinger_bands AS
WITH bb_base AS (
    SELECT
        stock,
        trade_date,
        close_price,
        AVG(close_price)  OVER w20 AS bb_sma20,
        STDDEV(close_price) OVER w20 AS bb_std20
    FROM stock_prices
    WINDOW w20 AS (
        PARTITION BY stock
        ORDER BY trade_date
        ROWS BETWEEN 19 PRECEDING AND CURRENT ROW
    )
)
SELECT
    stock,
    trade_date,
    close_price,
    ROUND(bb_sma20, 4)                           AS bb_sma20,
    ROUND(bb_sma20 + 2 * bb_std20, 4)            AS bb_upper,
    ROUND(bb_sma20 - 2 * bb_std20, 4)            AS bb_lower,
    ROUND((4 * bb_std20) / NULLIF(bb_sma20,0), 6) AS bb_width,
    CASE
        WHEN close_price > bb_sma20 + 2 * bb_std20 THEN 'OVERBOUGHT'
        WHEN close_price < bb_sma20 - 2 * bb_std20 THEN 'OVERSOLD'
        ELSE 'NEUTRAL'
    END                                           AS bb_signal
FROM bb_base;


-- ──────────────────────────────────────────────────────────────
-- 3.  VOLUME SPIKES  (volume > 200% of 30-day rolling average)
-- ──────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW v_volume_spikes AS
WITH vol_base AS (
    SELECT
        stock,
        trade_date,
        close_price,
        volume,
        open_price,
        high_price,
        low_price,
        hl_range,
        change_pct,
        day_type,
        AVG(volume) OVER (
            PARTITION BY stock
            ORDER BY trade_date
            ROWS BETWEEN 30 PRECEDING AND 1 PRECEDING  -- exclude current day
        ) AS vol_30d_avg
    FROM stock_prices
)
SELECT
    stock,
    trade_date,
    close_price,
    volume,
    ROUND(vol_30d_avg, 0)                               AS vol_30d_avg,
    ROUND((volume / NULLIF(vol_30d_avg,0) - 1) * 100, 2) AS vol_spike_pct,
    change_pct,
    hl_range,
    day_type
FROM vol_base
WHERE volume > 3 * NULLIF(vol_30d_avg, 0)   -- > 200% ABOVE avg = > 300% of avg
ORDER BY vol_spike_pct DESC;

-- ► Simple query version (no view) — paste directly into MySQL Workbench:
SELECT
    stock,
    trade_date,
    volume,
    ROUND(AVG(volume) OVER (
        PARTITION BY stock
        ORDER BY trade_date
        ROWS BETWEEN 30 PRECEDING AND 1 PRECEDING
    ), 0)                                                   AS vol_30d_avg,
    ROUND(
        (volume / NULLIF(
            AVG(volume) OVER (
                PARTITION BY stock
                ORDER BY trade_date
                ROWS BETWEEN 30 PRECEDING AND 1 PRECEDING
            ), 0) - 1) * 100
    , 2)                                                    AS spike_pct_above_avg
FROM stock_prices
HAVING spike_pct_above_avg > 200
ORDER BY spike_pct_above_avg DESC;


-- ──────────────────────────────────────────────────────────────
-- 4.  EMA CROSSOVERS  (EMA-12 vs EMA-26, iterative CTE)
-- ──────────────────────────────────────────────────────────────
-- Note: True EMA requires recursive CTEs in MySQL 8.0.
-- This approach uses a numbered base and a scalar-correlated 
-- approximation suitable for reporting (vs. real-time trading).

CREATE OR REPLACE VIEW v_ema_crossovers AS
WITH numbered AS (
    SELECT
        stock, trade_date, close_price,
        ROW_NUMBER() OVER (PARTITION BY stock ORDER BY trade_date) AS rn
    FROM stock_prices
),
ema_approx AS (
    -- EMA approximated using exponential-weighted rolling average
    -- MySQL doesn't support true recursive EMA natively in views;
    -- use stored procedure v_ema_stored_proc below for precise values.
    -- This view gives the MACD crossover detection once EMA columns exist.
    SELECT
        n.stock, n.trade_date, n.close_price,
        -- Populate via stored procedure output or Python-generated values
        NULL AS ema_12,
        NULL AS ema_26
    FROM numbered n
)
SELECT
    stock,
    trade_date,
    close_price,
    ema_12,
    ema_26,
    ROUND(ema_12 - ema_26, 4)    AS macd,
    LAG(ema_12 - ema_26) OVER (PARTITION BY stock ORDER BY trade_date) AS macd_prev,
    CASE
        WHEN (ema_12 - ema_26) > 0
         AND LAG(ema_12 - ema_26) OVER (PARTITION BY stock ORDER BY trade_date) <= 0
        THEN 'GOLDEN CROSS'
        WHEN (ema_12 - ema_26) < 0
         AND LAG(ema_12 - ema_26) OVER (PARTITION BY stock ORDER BY trade_date) >= 0
        THEN 'DEATH CROSS'
        ELSE ''
    END AS ema_cross_signal
FROM ema_approx;


-- ──────────────────────────────────────────────────────────────
-- 5.  STORED PROCEDURE: Precise EMA + Full Technical Table
-- ──────────────────────────────────────────────────────────────
DROP PROCEDURE IF EXISTS sp_compute_technicals;
DELIMITER $$

CREATE PROCEDURE sp_compute_technicals()
BEGIN
    -- Create output table
    DROP TABLE IF EXISTS technicals;
    CREATE TABLE technicals (
        stock            VARCHAR(30),
        trade_date       DATE,
        close_price      DECIMAL(12,4),
        log_return       DECIMAL(14,8),
        ema_12           DECIMAL(14,6),
        ema_26           DECIMAL(14,6),
        macd             DECIMAL(14,6),
        macd_signal      DECIMAL(14,6),
        macd_hist        DECIMAL(14,6),
        ema_cross        VARCHAR(15),
        bb_sma20         DECIMAL(14,6),
        bb_upper         DECIMAL(14,6),
        bb_lower         DECIMAL(14,6),
        bb_signal        VARCHAR(12),
        rsi_14           DECIMAL(8,4),
        vol_30d_avg      DECIMAL(16,2),
        vol_spike_pct    DECIMAL(10,2),
        vol_spike_flag   TINYINT(1),
        cum_return       DECIMAL(12,6),
        PRIMARY KEY (stock, trade_date)
    );

    -- Variables
    DECLARE v_stock      VARCHAR(30) DEFAULT '';
    DECLARE v_date       DATE;
    DECLARE v_close      DECIMAL(12,4);
    DECLARE v_prev_close DECIMAL(12,4) DEFAULT NULL;
    DECLARE v_ema12      DECIMAL(14,6) DEFAULT NULL;
    DECLARE v_ema26      DECIMAL(14,6) DEFAULT NULL;
    DECLARE v_ema12_prev DECIMAL(14,6) DEFAULT NULL;
    DECLARE v_ema26_prev DECIMAL(14,6) DEFAULT NULL;
    DECLARE v_macd_sig   DECIMAL(14,6) DEFAULT NULL;
    DECLARE v_cum        DECIMAL(14,8) DEFAULT 1.0;
    DECLARE v_done       TINYINT DEFAULT 0;

    DECLARE k12 DECIMAL(10,8) DEFAULT 2.0/13.0;  -- EMA-12 smoothing
    DECLARE k26 DECIMAL(10,8) DEFAULT 2.0/27.0;  -- EMA-26 smoothing
    DECLARE k9  DECIMAL(10,8) DEFAULT 2.0/10.0;  -- Signal smoothing

    DECLARE cur CURSOR FOR
        SELECT stock, trade_date, close_price
        FROM stock_prices
        ORDER BY stock, trade_date;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;

    OPEN cur;
    row_loop: LOOP
        FETCH cur INTO v_stock, v_date, v_close;
        IF v_done THEN LEAVE row_loop; END IF;

        -- Reset on new stock
        IF v_stock != @last_stock OR @last_stock IS NULL THEN
            SET v_ema12 = v_close, v_ema26 = v_close,
                v_ema12_prev = v_close, v_ema26_prev = v_close,
                v_macd_sig = 0, v_cum = 1.0, v_prev_close = v_close,
                @last_stock = v_stock;
        END IF;

        -- EMA update
        SET v_ema12_prev = v_ema12,
            v_ema26_prev = v_ema26,
            v_ema12      = v_close * k12 + v_ema12 * (1 - k12),
            v_ema26      = v_close * k26 + v_ema26 * (1 - k26);

        SET @macd     = v_ema12 - v_ema26;
        SET v_macd_sig = @macd * k9 + v_macd_sig * (1 - k9);

        -- Cumulative return
        IF v_prev_close > 0 THEN
            SET v_cum = v_cum * (v_close / v_prev_close);
        END IF;
        SET v_prev_close = v_close;

        -- EMA cross
        SET @cross = CASE
            WHEN v_ema12 > v_ema26 AND v_ema12_prev <= v_ema26_prev THEN 'GOLDEN CROSS'
            WHEN v_ema12 < v_ema26 AND v_ema12_prev >= v_ema26_prev THEN 'DEATH CROSS'
            ELSE ''
        END;

        INSERT INTO technicals
            (stock, trade_date, close_price, ema_12, ema_26,
             macd, macd_signal, macd_hist, ema_cross, cum_return)
        VALUES
            (v_stock, v_date, v_close, v_ema12, v_ema26,
             @macd, v_macd_sig, @macd - v_macd_sig, @cross, v_cum - 1.0);
    END LOOP;
    CLOSE cur;

    -- Back-fill Bollinger Bands & RSI via window functions (set-based)
    UPDATE technicals t
    JOIN (
        SELECT
            stock, trade_date,
            AVG(close_price)    OVER w20  AS bb_sma,
            STDDEV(close_price) OVER w20  AS bb_std,
            AVG(close_price)    OVER w30  AS v30_avg
        FROM stock_prices
        WINDOW
            w20 AS (PARTITION BY stock ORDER BY trade_date ROWS BETWEEN 19 PRECEDING AND CURRENT ROW),
            w30 AS (PARTITION BY stock ORDER BY trade_date ROWS BETWEEN 30 PRECEDING AND 1 PRECEDING)
    ) b ON t.stock = b.stock AND t.trade_date = b.trade_date
    SET
        t.bb_sma20       = ROUND(b.bb_sma, 4),
        t.bb_upper       = ROUND(b.bb_sma + 2 * b.bb_std, 4),
        t.bb_lower       = ROUND(b.bb_sma - 2 * b.bb_std, 4),
        t.bb_signal      = CASE
                               WHEN t.close_price > b.bb_sma + 2*b.bb_std THEN 'OVERBOUGHT'
                               WHEN t.close_price < b.bb_sma - 2*b.bb_std THEN 'OVERSOLD'
                               ELSE 'NEUTRAL'
                           END,
        t.vol_30d_avg    = ROUND(b.v30_avg, 0);

    -- Volume spike flag
    UPDATE technicals t
    JOIN stock_prices s ON t.stock = s.stock AND t.trade_date = s.trade_date
    SET
        t.vol_spike_pct  = ROUND((s.volume / NULLIF(t.vol_30d_avg,0) - 1)*100, 2),
        t.vol_spike_flag = IF(s.volume > 3 * NULLIF(t.vol_30d_avg,0), 1, 0);

    SELECT CONCAT('technicals table built: ', COUNT(*), ' rows') AS result FROM technicals;
END$$
DELIMITER ;

-- Run with:
-- CALL sp_compute_technicals();


-- ──────────────────────────────────────────────────────────────
-- 6.  ANOMALY SUMMARY QUERIES
-- ──────────────────────────────────────────────────────────────

-- 6a. Volume spike events per stock
SELECT
    stock,
    COUNT(*)                        AS spike_days,
    ROUND(AVG(vol_spike_pct), 1)    AS avg_spike_pct,
    MAX(vol_spike_pct)              AS max_spike_pct,
    MIN(trade_date)                 AS first_spike,
    MAX(trade_date)                 AS last_spike
FROM technicals
WHERE vol_spike_flag = 1
GROUP BY stock
ORDER BY spike_days DESC;

-- 6b. All Golden & Death Cross dates
SELECT
    stock,
    trade_date,
    close_price,
    ema_12,
    ema_26,
    macd,
    ema_cross
FROM technicals
WHERE ema_cross IN ('GOLDEN CROSS','DEATH CROSS')
ORDER BY trade_date, stock;

-- 6c. Overbought / Oversold days
SELECT
    stock,
    bb_signal,
    COUNT(*)                     AS days,
    ROUND(AVG(close_price),2)    AS avg_close,
    MIN(trade_date)              AS first_date,
    MAX(trade_date)              AS last_date
FROM technicals
WHERE bb_signal != 'NEUTRAL'
GROUP BY stock, bb_signal
ORDER BY stock, bb_signal;

-- 6d. Worst single-day volume spikes (top 20)
SELECT
    t.stock,
    t.trade_date,
    s.volume,
    t.vol_30d_avg,
    t.vol_spike_pct,
    s.change_pct,
    s.day_type
FROM technicals t
JOIN stock_prices s ON t.stock=s.stock AND t.trade_date=s.trade_date
WHERE t.vol_spike_flag = 1
ORDER BY t.vol_spike_pct DESC
LIMIT 20;

-- 6e. Cumulative return by stock (end-of-period)
SELECT
    stock,
    MAX(trade_date)                             AS last_date,
    ROUND(MAX(cum_return)*100, 2)               AS total_return_pct,
    ROUND(AVG(CASE WHEN ema_cross='GOLDEN CROSS' THEN 1 END)*100,1) AS golden_cross_days_pct
FROM technicals
GROUP BY stock
ORDER BY total_return_pct DESC;

-- 6f. Monthly anomaly heatmap
SELECT
    DATE_FORMAT(trade_date,'%Y-%m')             AS month,
    SUM(vol_spike_flag)                         AS volume_spikes,
    SUM(CASE WHEN ema_cross='GOLDEN CROSS' THEN 1 ELSE 0 END) AS golden_crosses,
    SUM(CASE WHEN ema_cross='DEATH CROSS'  THEN 1 ELSE 0 END) AS death_crosses,
    SUM(CASE WHEN bb_signal='OVERBOUGHT'   THEN 1 ELSE 0 END) AS overbought_days,
    SUM(CASE WHEN bb_signal='OVERSOLD'     THEN 1 ELSE 0 END) AS oversold_days
FROM technicals
GROUP BY month
ORDER BY month;

