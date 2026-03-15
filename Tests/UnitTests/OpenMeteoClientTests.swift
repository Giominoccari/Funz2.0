import Foundation
import Testing
@testable import App

@Suite("OpenMeteoClient Tests")
struct OpenMeteoClientTests {

    @Test("parseResponse decodes valid JSON correctly")
    func parseValidJSON() throws {
        let json = Self.makeJSON(
            rainSum: [1.0, 2.0, 3.0, 0.5, 1.5, 2.5, 0.0, 1.0, 2.0, 3.0, 0.5, 1.5, 2.5, 0.0],
            temperature: [10.0, 11.0, 12.0, 13.0, 14.0, 15.0, 16.0, 17.0, 18.0, 19.0, 20.0, 21.0, 22.0, 23.0],
            humidity: [60.0, 62.0, 64.0, 66.0, 68.0, 70.0, 72.0, 74.0, 76.0, 78.0, 80.0, 82.0, 84.0, 86.0]
        )
        let data = Data(json.utf8)
        let result = try OpenMeteoClient.parseResponse(data, latitude: 46.0, longitude: 11.0)

        #expect(result.rain14d == 21.0)
        #expect(result.avgTemperature > 0)
        #expect(result.avgHumidity > 0)
    }

    @Test("parseResponse computes rain14d as sum of all rain values")
    func rain14dSum() throws {
        let rainValues = [5.0, 0.0, 3.0, 2.0, 1.0, 0.0, 4.0, 6.0, 0.0, 1.0, 2.0, 3.0, 0.0, 1.0]
        let json = Self.makeJSON(
            rainSum: rainValues,
            temperature: Array(repeating: 18.0, count: 14),
            humidity: Array(repeating: 70.0, count: 14)
        )
        let result = try OpenMeteoClient.parseResponse(Data(json.utf8), latitude: 46.0, longitude: 11.0)
        let expectedSum = rainValues.reduce(0, +)
        #expect(result.rain14d == expectedSum)
    }

    @Test("parseResponse computes avgTemperature from last 7 days only")
    func avgTempLast7() throws {
        var temps = Array(repeating: 0.0, count: 7)
        temps.append(contentsOf: [10.0, 12.0, 14.0, 16.0, 18.0, 20.0, 22.0])
        let json = Self.makeJSON(
            rainSum: Array(repeating: 1.0, count: 14),
            temperature: temps,
            humidity: Array(repeating: 70.0, count: 14)
        )
        let result = try OpenMeteoClient.parseResponse(Data(json.utf8), latitude: 46.0, longitude: 11.0)
        let expectedAvg = (10.0 + 12.0 + 14.0 + 16.0 + 18.0 + 20.0 + 22.0) / 7.0
        #expect(abs(result.avgTemperature - expectedAvg) < 0.001)
    }

    @Test("parseResponse computes avgHumidity from last 7 days only")
    func avgHumidityLast7() throws {
        var humidity = Array(repeating: 0.0, count: 7)
        humidity.append(contentsOf: [60.0, 65.0, 70.0, 75.0, 80.0, 85.0, 90.0])
        let json = Self.makeJSON(
            rainSum: Array(repeating: 1.0, count: 14),
            temperature: Array(repeating: 18.0, count: 14),
            humidity: humidity
        )
        let result = try OpenMeteoClient.parseResponse(Data(json.utf8), latitude: 46.0, longitude: 11.0)
        let expectedAvg = (60.0 + 65.0 + 70.0 + 75.0 + 80.0 + 85.0 + 90.0) / 7.0
        #expect(abs(result.avgHumidity - expectedAvg) < 0.001)
    }

    @Test("parseResponse handles null values in daily arrays")
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
        let result = try OpenMeteoClient.parseResponse(Data(json.utf8), latitude: 46.0, longitude: 11.0)
        #expect(result.rain14d == 4.0)
        #expect(abs(result.avgTemperature - 17.5) < 0.001)
        #expect(abs(result.avgHumidity - 75.0) < 0.001)
    }

    @Test("parseResponse throws on empty daily arrays")
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
            try OpenMeteoClient.parseResponse(Data(json.utf8), latitude: 46.0, longitude: 11.0)
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
}
