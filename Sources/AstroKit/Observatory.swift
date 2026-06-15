/// Geographic location and atmospheric conditions of an observatory on Earth.
public struct Observatory: Sendable, Equatable {

    /// Geographic longitude in radians, east positive.
    public var longitude: Double

    /// Geographic latitude in radians, north positive.
    public var latitude: Double

    /// Height above the reference ellipsoid in metres.
    public var height: Double

    /// Atmospheric pressure in hPa.
    /// Pass `nil` to skip atmospheric refraction correction entirely.
    /// When `nil` and refraction is requested, a standard-atmosphere estimate
    /// derived from `height` is used.
    public var pressure: Double?

    /// Air temperature in °C. Used for refraction calculation. Default 15 °C.
    public var temperature: Double

    /// Relative humidity 0–1. Used for refraction calculation. Default 0.5.
    public var humidity: Double

    public init(
        longitude: Double,
        latitude: Double,
        height: Double = 0.0,
        pressure: Double? = nil,
        temperature: Double = 15.0,
        humidity: Double = 0.5
    ) {
        self.longitude = longitude
        self.latitude = latitude
        self.height = height
        self.pressure = pressure
        self.temperature = temperature
        self.humidity = humidity
    }
}
