import Foundation
import Testing
@testable import App

@Suite("OpenMeteoClient Tests")
struct OpenMeteoClientTests {

    @Test("parseDailyResponse decodes valid JSON into daily observations")
    func parseValidJSON() throws {
        let json = Self.makeJSON(
            rainSum: [1.0, 2.0, 3.0, 0.5, 1.5, 2.5, 0.0, 1.0, 2.0, 3.0, 0.5, 1.5, 2.5, 0.0],
            temperature: [10.0, 11.0, 12.0, 13.0, 14.0, 15.0, 16.0, 17.0, 18.0, 19.0, 20.0, 21.0, 22.0, 23.0],
            humidity: [60.0, 62.0, 64.0, 66.0, 68.0, 70.0, 72.0, 74.0, 76.0, 78.0, 80.0, 82.0, 84.0, 86.0]
        )
        let observations = try OpenMeteoClient.parseDailyResponse(Data(json.utf8), latitude: 46.0, longitude: 11.0)

        #expect(observations.count == 14)
        #expect(observations[0].date == "2026-03-01")
        #expect(observations[0].rainMm == 1.0)
        #expect(observations[0].tempMeanC == 10.0)
        #expect(observations[0].humidityPct == 60.0)
    }

    @Test("parseDailyResponse with hourly soil temp computes daily means")
    func parseWithHourlySoilTemp() throws {
        let json = Self.makeJSONWithHourly(
            rainSum: [5.0, 10.0],
            temperature: [15.0, 16.0],
            humidity: [70.0, 75.0],
            hourlySoilTemp: Array(repeating: 12.0, count: 48) // 2 days × 24 hours = constant 12°C
        )
        let observations = try OpenMeteoClient.parseDailyResponse(Data(json.utf8), latitude: 46.0, longitude: 11.0)

        #expect(observations.count == 2)
        #expect(abs(observations[0].soilTempC - 12.0) < 0.01)
        #expect(abs(observations[1].soilTempC - 12.0) < 0.01)
    }

    @Test("parseDailyResponse without hourly data falls back to damped air temp")
    func parseWithoutHourlyFallback() throws {
        let json = Self.makeJSON(
            rainSum: [5.0],
            temperature: [20.0],
            humidity: [70.0]
        )
        let observations = try OpenMeteoClient.parseDailyResponse(Data(json.utf8), latitude: 46.0, longitude: 11.0)

        #expect(observations.count == 1)
        // Fallback: soilTempC = airTemp * 0.85 = 17.0
        #expect(abs(observations[0].soilTempC - 17.0) < 0.01)
    }

    @Test("aggregate computes rain14d as sum of all rain values")
    func rain14dSum() throws {
        let rainValues = [5.0, 0.0, 3.0, 2.0, 1.0, 0.0, 4.0, 6.0, 0.0, 1.0, 2.0, 3.0, 0.0, 1.0]
        let json = Self.makeJSON(
            rainSum: rainValues,
            temperature: Array(repeating: 18.0, count: 14),
            humidity: Array(repeating: 70.0, count: 14)
        )
        let observations = try OpenMeteoClient.parseDailyResponse(Data(json.utf8), latitude: 46.0, longitude: 11.0)
        let result = WeatherData.aggregate(from: observations)
        let expectedSum = rainValues.reduce(0, +)
        #expect(result.rain14d == expectedSum)
    }

    @Test("aggregate computes avgTemperature from last 7 days only")
    func avgTempLast7() throws {
        var temps = Array(repeating: 0.0, count: 7)
        temps.append(contentsOf: [10.0, 12.0, 14.0, 16.0, 18.0, 20.0, 22.0])
        let json = Self.makeJSON(
            rainSum: Array(repeating: 1.0, count: 14),
            temperature: temps,
            humidity: Array(repeating: 70.0, count: 14)
        )
        let observations = try OpenMeteoClient.parseDailyResponse(Data(json.utf8), latitude: 46.0, longitude: 11.0)
        let result = WeatherData.aggregate(from: observations)
        let expectedAvg = (10.0 + 12.0 + 14.0 + 16.0 + 18.0 + 20.0 + 22.0) / 7.0
        #expect(abs(result.avgTemperature - expectedAvg) < 0.001)
    }

    @Test("aggregate computes avgHumidity from last 7 days only")
    func avgHumidityLast7() throws {
        var humidity = Array(repeating: 0.0, count: 7)
        humidity.append(contentsOf: [60.0, 65.0, 70.0, 75.0, 80.0, 85.0, 90.0])
        let json = Self.makeJSON(
            rainSum: Array(repeating: 1.0, count: 14),
            temperature: Array(repeating: 18.0, count: 14),
            humidity: humidity
        )
        let observations = try OpenMeteoClient.parseDailyResponse(Data(json.utf8), latitude: 46.0, longitude: 11.0)
        let result = WeatherData.aggregate(from: observations)
        let expectedAvg = (60.0 + 65.0 + 70.0 + 75.0 + 80.0 + 85.0 + 90.0) / 7.0
        #expect(abs(result.avgHumidity - expectedAvg) < 0.001)
    }

    @Test("parseDailyResponse handles null values as zero")
    func handleNulls() throws {
        let json = """
        {
          "daily": {
            "time": ["2026-03-01","2026-03-02","2026-03-03"],
            "rain_sum": [1.0, null, 3.0],
            "temperature_2m_mean": [null, 15.0, 20.0],
            "relative_humidity_2m_mean": [70.0, null, 80.0]
          }
        }
        """
        let observations = try OpenMeteoClient.parseDailyResponse(Data(json.utf8), latitude: 46.0, longitude: 11.0)
        #expect(observations.count == 3)
        // null values become 0
        #expect(observations[1].rainMm == 0)
        #expect(observations[0].tempMeanC == 0)
        #expect(observations[1].humidityPct == 0)
    }

    @Test("parseDailyResponse throws on empty daily arrays")
    func emptyArrays() {
        let json = """
        {
          "daily": {
            "time": [],
            "rain_sum": [],
            "temperature_2m_mean": [],
            "relative_humidity_2m_mean": []
          }
        }
        """
        #expect(throws: WeatherFetchError.self) {
            try OpenMeteoClient.parseDailyResponse(Data(json.utf8), latitude: 46.0, longitude: 11.0)
        }
    }

    // MARK: - Helpers

    private static func makeJSON(
        rainSum: [Double],
        temperature: [Double],
        humidity: [Double]
    ) -> String {
        let days = rainSum.count
        let times = (0..<days).map { "\"2026-03-\(String(format: "%02d", $0 + 1))\"" }
            .joined(separator: ",")
        let rain = rainSum.map { String($0) }.joined(separator: ",")
        let temp = temperature.map { String($0) }.joined(separator: ",")
        let hum = humidity.map { String($0) }.joined(separator: ",")

        return """
        {
          "daily": {
            "time": [\(times)],
            "rain_sum": [\(rain)],
            "temperature_2m_mean": [\(temp)],
            "relative_humidity_2m_mean": [\(hum)]
          }
        }
        """
    }

    private static func makeJSONWithHourly(
        rainSum: [Double],
        temperature: [Double],
        humidity: [Double],
        hourlySoilTemp: [Double]
    ) -> String {
        let days = rainSum.count
        let times = (0..<days).map { "\"2026-03-\(String(format: "%02d", $0 + 1))\"" }
            .joined(separator: ",")
        let rain = rainSum.map { String($0) }.joined(separator: ",")
        let temp = temperature.map { String($0) }.joined(separator: ",")
        let hum = humidity.map { String($0) }.joined(separator: ",")

        // Generate hourly timestamps for each day
        var hourlyTimes: [String] = []
        for d in 0..<days {
            for h in 0..<24 {
                hourlyTimes.append("\"2026-03-\(String(format: "%02d", d + 1))T\(String(format: "%02d", h)):00\"")
            }
        }
        let hourlyTimesStr = hourlyTimes.joined(separator: ",")
        let soilTemp = hourlySoilTemp.map { String($0) }.joined(separator: ",")

        return """
        {
          "daily": {
            "time": [\(times)],
            "rain_sum": [\(rain)],
            "temperature_2m_mean": [\(temp)],
            "relative_humidity_2m_mean": [\(hum)]
          },
          "hourly": {
            "time": [\(hourlyTimesStr)],
            "soil_temperature_0_to_7cm": [\(soilTemp)]
          }
        }
        """
    }
}
