-- seed-mock-weather.sql
-- Pre-populates weather_observations with 14 days of synthetic daily data covering
-- all coarse grid points that the pipeline will query. This lets Phase 3 resolve
-- entirely from the L2 (PostgreSQL) cache with zero Open-Meteo API calls.
--
-- Usage:
--   psql "$DATABASE_URL" -f infra/scripts/seed-mock-weather.sql
--   -- or with a specific date:
--   psql "$DATABASE_URL" -v target_date="'2026-03-25'" -f infra/scripts/seed-mock-weather.sql
--
-- The coarse grid matches PipelineRunner.fetchWeather():
--   step = 0.09deg (~10km), bbox = Italy (lat 36.6-47.1, lon 6.6-18.5)
--   coordinates rounded to 3 decimals (same as CachedWeatherClient)

-- Default date = today if not passed via -v
\set ON_ERROR_STOP on

DO $$
DECLARE
    v_target DATE := COALESCE(:'target_date'::date, CURRENT_DATE);
    v_start  DATE := v_target - INTERVAL '13 days';
    v_cur    DATE;
    v_partition TEXT;
    v_range_start TEXT;
    v_range_end TEXT;
    v_year INT;
    v_month INT;
    v_next_year INT;
    v_next_month INT;
    v_count INT;
    v_total INT := 0;
BEGIN
    -- Ensure monthly partitions exist for the full 14-day range (may span 2 months)
    FOR v_cur IN SELECT generate_series(v_start, v_target, '1 month'::interval)::date LOOP
        v_year  := EXTRACT(YEAR FROM v_cur);
        v_month := EXTRACT(MONTH FROM v_cur);
        v_partition := format('weather_observations_%s_%s', v_year, lpad(v_month::text, 2, '0'));

        IF v_month = 12 THEN
            v_next_year := v_year + 1; v_next_month := 1;
        ELSE
            v_next_year := v_year; v_next_month := v_month + 1;
        END IF;
        v_range_start := format('%s-%s-01', v_year, lpad(v_month::text, 2, '0'));
        v_range_end   := format('%s-%s-01', v_next_year, lpad(v_next_month::text, 2, '0'));

        IF NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = v_partition) THEN
            EXECUTE format(
                'CREATE TABLE %I PARTITION OF weather_observations FOR VALUES FROM (%L) TO (%L)',
                v_partition, v_range_start, v_range_end
            );
            RAISE NOTICE 'Created partition: %', v_partition;
        END IF;
    END LOOP;

    -- Also ensure the target month partition (in case start and target are same month)
    v_year  := EXTRACT(YEAR FROM v_target);
    v_month := EXTRACT(MONTH FROM v_target);
    v_partition := format('weather_observations_%s_%s', v_year, lpad(v_month::text, 2, '0'));
    IF v_month = 12 THEN
        v_next_year := v_year + 1; v_next_month := 1;
    ELSE
        v_next_year := v_year; v_next_month := v_month + 1;
    END IF;
    v_range_start := format('%s-%s-01', v_year, lpad(v_month::text, 2, '0'));
    v_range_end   := format('%s-%s-01', v_next_year, lpad(v_next_month::text, 2, '0'));
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = v_partition) THEN
        EXECUTE format(
            'CREATE TABLE %I PARTITION OF weather_observations FOR VALUES FROM (%L) TO (%L)',
            v_partition, v_range_start, v_range_end
        );
        RAISE NOTICE 'Created partition: %', v_partition;
    END IF;

    -- Generate 14 days of daily observations for each coarse grid point.
    -- Values are realistic Italian spring conditions:
    --   rain_mm:      0-8 mm/day (varies day-to-day, sums to 20-80 mm over 14 days)
    --   temp_mean_c:  6-20 C (daily mean, varies slightly day-to-day)
    --   humidity_pct: 50-90 % (daily mean)
    --
    -- Uses seeded pseudo-random based on lat/lon/day_offset for reproducibility.
    FOR v_cur IN SELECT generate_series(v_start, v_target, '1 day'::interval)::date LOOP
        INSERT INTO weather_observations (latitude, longitude, observed_date, rain_mm, temp_mean_c, humidity_pct)
        SELECT
            round(lat::numeric, 3)::double precision,
            round(lon::numeric, 3)::double precision,
            v_cur,
            -- daily rain: 0-8mm, varies by position and day
            round(greatest(0, (4 + 4 * sin(lat * 17 + lon * 13 + day_off * 7)))::numeric, 1),
            -- daily temp: 8-18C, warmer in south, slight day-to-day variation
            round((18 - 10 * ((lat - 36.6) / 10.5) + 2 * sin(lon * 7 + lat * 11 + day_off * 3))::numeric, 1),
            -- daily humidity: 55-85%, varies by position and day
            round((70 + 15 * sin(lon * 5 + lat * 3 + day_off * 5))::numeric, 1)
        FROM
            generate_series(36.6, 47.19, 0.09) AS lat,
            generate_series(6.6, 18.59, 0.09) AS lon,
            (SELECT EXTRACT(EPOCH FROM v_cur - v_start) / 86400) AS day_off
        ON CONFLICT (latitude, longitude, observed_date) DO UPDATE SET
            rain_mm      = EXCLUDED.rain_mm,
            temp_mean_c  = EXCLUDED.temp_mean_c,
            humidity_pct = EXCLUDED.humidity_pct;

        GET DIAGNOSTICS v_count = ROW_COUNT;
        v_total := v_total + v_count;
    END LOOP;

    RAISE NOTICE 'Seeded % daily weather observations for % to %', v_total, v_start, v_target;
END $$;
