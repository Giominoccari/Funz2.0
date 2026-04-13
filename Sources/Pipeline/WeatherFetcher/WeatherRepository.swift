import Foundation
import Logging
import SQLKit

/// Durable PostgreSQL-backed weather cache. Stores individual daily observations
/// so pipeline runs can reuse overlapping days (e.g. 13 of 14 days shared between
/// consecutive runs).
actor WeatherRepository {
    private let db: any SQLDatabase
    private let logger = Logger(label: "funghi.pipeline.weather.db")

    init(db: any SQLDatabase) {
        self.db = db
    }

    // MARK: - Partition management

    /// Ensures the monthly partition exists for the given date (YYYY-MM-DD).
    func ensurePartition(for date: String) async throws {
        let parts = date.prefix(7).split(separator: "-")
        guard parts.count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]) else {
            logger.warning("Invalid date for partition", metadata: ["date": "\(date)"])
            return
        }

        let partitionName = "weather_observations_\(year)_\(String(format: "%02d", month))"

        let nextMonth: Int
        let nextYear: Int
        if month == 12 {
            nextMonth = 1
            nextYear = year + 1
        } else {
            nextMonth = month + 1
            nextYear = year
        }

        let rangeStart = "\(year)-\(String(format: "%02d", month))-01"
        let rangeEnd = "\(nextYear)-\(String(format: "%02d", nextMonth))-01"

        let exists = try await db.raw("""
            SELECT 1 FROM pg_class WHERE relname = \(bind: partitionName)
            """).all()

        if !exists.isEmpty {
            logger.trace("Partition already exists", metadata: ["partition": "\(partitionName)"])
            return
        }

        try await db.raw("""
            CREATE TABLE \(unsafeRaw: partitionName) PARTITION OF weather_observations
            FOR VALUES FROM ('\(unsafeRaw: rangeStart)') TO ('\(unsafeRaw: rangeEnd)')
            """).run()
        logger.info("Created weather partition", metadata: ["partition": "\(partitionName)"])
    }

    /// Ensure partitions exist for all months spanned by a date range.
    func ensurePartitions(from startDate: String, to endDate: String) async throws {
        var months: Set<String> = []
        months.insert(String(startDate.prefix(7)))
        months.insert(String(endDate.prefix(7)))

        for month in months {
            try await ensurePartition(for: "\(month)-01")
        }
    }

    // MARK: - Pipeline cache: fetch existing daily observations

    /// For each coordinate, returns the daily observations that already exist in the DB
    /// for the given date range. The returned dictionary maps input array index to observations.
    /// Only indices with at least one cached day are included.
    func fetchExistingDaily(
        coordinates: [(latitude: Double, longitude: Double)],
        from startDate: String,
        to endDate: String
    ) async throws -> [Int: [DailyObservation]] {
        guard !coordinates.isEmpty else { return [:] }

        // Build lookup map: "lat,lon" -> [indices]
        var coordToIndices: [String: [Int]] = [:]
        for (i, coord) in coordinates.enumerated() {
            let key = "\(coord.latitude),\(coord.longitude)"
            coordToIndices[key, default: []].append(i)
        }

        let valuePairs = coordinates.map { "(\($0.latitude), \($0.longitude))" }.joined(separator: ", ")

        let rows = try await db.raw("""
            SELECT w.latitude, w.longitude, w.observed_date, w.rain_mm, w.temp_mean_c, w.humidity_pct, COALESCE(w.soil_temp_c, w.temp_mean_c * 0.85) AS soil_temp_c
            FROM weather_observations w
            INNER JOIN (VALUES \(unsafeRaw: valuePairs)) AS q(lat, lon)
                ON w.latitude = q.lat AND w.longitude = q.lon
            WHERE w.observed_date BETWEEN CAST(\(bind: startDate) AS date) AND CAST(\(bind: endDate) AS date)
            ORDER BY w.latitude, w.longitude, w.observed_date
            """).all()

        var result: [Int: [DailyObservation]] = [:]
        for row in rows {
            let lat = try row.decode(column: "latitude", as: Double.self)
            let lon = try row.decode(column: "longitude", as: Double.self)
            let date = try row.decode(column: "observed_date", as: String.self)
            let rain = try row.decode(column: "rain_mm", as: Double.self)
            let temp = try row.decode(column: "temp_mean_c", as: Double.self)
            let hum = try row.decode(column: "humidity_pct", as: Double.self)
            let soilTemp = try row.decode(column: "soil_temp_c", as: Double.self)

            let key = "\(lat),\(lon)"
            let obs = DailyObservation(date: date, rainMm: rain, tempMeanC: temp, humidityPct: hum, soilTempC: soilTemp)

            if let indices = coordToIndices[key] {
                for idx in indices {
                    result[idx, default: []].append(obs)
                }
            }
        }

        return result
    }

    // MARK: - Store new daily observations

    /// Batch-inserts daily observations. Uses ON CONFLICT DO NOTHING to skip duplicates.
    func storeDailyObservations(
        entries: [(lat: Double, lon: Double, observations: [DailyObservation])]
    ) async throws {
        // Flatten into individual rows
        var allRows: [(lat: Double, lon: Double, date: String, rain: Double, temp: Double, hum: Double, soilTemp: Double)] = []
        for entry in entries {
            for obs in entry.observations {
                allRows.append((entry.lat, entry.lon, obs.date, obs.rainMm, obs.tempMeanC, obs.humidityPct, obs.soilTempC))
            }
        }

        guard !allRows.isEmpty else { return }

        let batchSize = 1000
        for batchStart in stride(from: 0, to: allRows.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, allRows.count)
            let batch = allRows[batchStart..<batchEnd]

            let values = batch.map { row in
                "(\(row.lat), \(row.lon), '\(row.date)', \(row.rain), \(row.temp), \(row.hum), \(row.soilTemp))"
            }.joined(separator: ", ")

            try await db.raw("""
                INSERT INTO weather_observations (latitude, longitude, observed_date, rain_mm, temp_mean_c, humidity_pct, soil_temp_c)
                VALUES \(unsafeRaw: values)
                ON CONFLICT (latitude, longitude, observed_date) DO NOTHING
                """).run()
        }

        logger.info("Stored daily weather observations", metadata: [
            "coordinates": "\(entries.count)",
            "totalRows": "\(allRows.count)"
        ])
    }

    // MARK: - API: fetch for client

    struct DailyWeather: Sendable, Codable {
        let date: String
        let rainMm: Double
        let tempMeanC: Double
        let humidityPct: Double
    }

    struct NearestPointResult: Sendable, Codable {
        let latitude: Double
        let longitude: Double
        let daily: [DailyWeather]
    }

    func fetchForAPI(
        latitude: Double,
        longitude: Double,
        from: String,
        to: String
    ) async throws -> NearestPointResult? {
        // Find nearest grid point from all stored observations (no date filter),
        // so that requests for future dates (forecast range) still resolve a point.
        let nearestRows = try await db.raw("""
            SELECT latitude, longitude
            FROM (
                SELECT DISTINCT latitude, longitude
                FROM weather_observations
            ) AS pts
            ORDER BY (latitude - \(bind: latitude)) * (latitude - \(bind: latitude))
                   + (longitude - \(bind: longitude)) * (longitude - \(bind: longitude))
            LIMIT 1
            """).all()

        guard let nearest = nearestRows.first else { return nil }

        let nearLat = try nearest.decode(column: "latitude", as: Double.self)
        let nearLon = try nearest.decode(column: "longitude", as: Double.self)

        // Check distance (~15km max, roughly 0.135° at Italy's latitude)
        let dLat = nearLat - latitude
        let dLon = nearLon - longitude
        let distDegSq = dLat * dLat + dLon * dLon
        guard distDegSq <= 0.135 * 0.135 else { return nil }

        let rows = try await db.raw("""
            SELECT observed_date, rain_mm, temp_mean_c, humidity_pct
            FROM weather_observations
            WHERE latitude = \(bind: nearLat)
              AND longitude = \(bind: nearLon)
              AND observed_date BETWEEN CAST(\(bind: from) AS date) AND CAST(\(bind: to) AS date)
            ORDER BY observed_date
            """).all()

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0) // importante per evitare shift

        let daily = try rows.map { row in
            let dateObj = try row.decode(column: "observed_date", as: Date.self)

            return DailyWeather(
                date: formatter.string(from: dateObj),
                rainMm: try row.decode(column: "rain_mm", as: Double.self),
                tempMeanC: try row.decode(column: "temp_mean_c", as: Double.self),
                humidityPct: try row.decode(column: "humidity_pct", as: Double.self)
            )
        }

        return NearestPointResult(latitude: nearLat, longitude: nearLon, daily: daily)
    }
}
