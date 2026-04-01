import Foundation

struct OpenMeteoResponse: Codable, Sendable {
    let daily: DailyData
    let hourly: HourlyData?

    struct DailyData: Codable, Sendable {
        let time: [String]
        let rainSum: [Double?]
        let temperature2mMean: [Double?]
        let relativeHumidity2mMean: [Double?]

        enum CodingKeys: String, CodingKey {
            case time
            case rainSum = "rain_sum"
            case temperature2mMean = "temperature_2m_mean"
            case relativeHumidity2mMean = "relative_humidity_2m_mean"
        }
    }

    struct HourlyData: Codable, Sendable {
        let time: [String]
        let soilTemperature0To7cm: [Double?]

        enum CodingKeys: String, CodingKey {
            case time
            case soilTemperature0To7cm = "soil_temperature_0_to_7cm"
        }
    }
}
