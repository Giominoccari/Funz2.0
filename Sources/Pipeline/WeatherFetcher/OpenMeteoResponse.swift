import Foundation

struct OpenMeteoResponse: Codable, Sendable {
    let daily: DailyData

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
}
