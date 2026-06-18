//
//  ObservingSession.swift
//  AstrophotoArchiveKit
//

import Foundation

/// An observing session — typically one night's imaging from a single location,
/// or a calibration run (sequence of dark, flat, or bias frames taken close together in time).
///
/// **Light sessions** (`frameType == "light"`) span two calendar dates in local time.
/// The session is named after the calendar date of the preceding local sunset: e.g. a frame
/// captured at 01:30 on 16 June belongs to the "15 June 2026" session.
///
/// **Day sessions** also have `frameType == "light"` but `isNight == false`.
///
/// **Calibration sessions** (`frameType == "dark"/"flat"/"bias"`) cover a consecutive sequence
/// of the same calibration frame type. They are named after the frame type and a distinguishing
/// characteristic: e.g. "Darks -10°C on 16 June 2026" or "Flats OIII on 16 June 2026".
/// `latitude` and `longitude` are not meaningful for calibration sessions.
public struct ObservingSession: Sendable, Identifiable {
    public let id: UUID
    /// Human-readable name: "15 June 2026" for light sessions,
    /// or "Darks -10°C on 16 June 2026" for calibration sessions.
    public var name: String
    /// Calendar date that names the session (local time).
    /// For night sessions this is the date of the preceding sunset;
    /// for day and calibration sessions it is the date of the observation itself.
    public var date: Date
    /// `true` for night-time light imaging, `false` for daytime or calibration sessions.
    public var isNight: Bool
    /// Frame type for all sessions: "light", "dark", "flat", or "bias".
    public var frameType: String
    /// Mean geographic latitude of the frames in this session, in degrees (north positive).
    /// Not meaningful for calibration sessions.
    public var latitude: Double
    /// Mean geographic longitude of the frames in this session, in degrees (east positive).
    /// Not meaningful for calibration sessions.
    public var longitude: Double
    /// Number of raw frames in this session.
    public var frameCount: Int
    /// Timestamp of the earliest frame in this session.
    public var startTime: Date?
    /// Timestamp of the latest frame in this session.
    public var endTime: Date?
    public var addedAt: Date

    /// `true` if this session groups calibration frames (dark/flat/bias).
    public var isCalibration: Bool { frameType != "light" }

    /// Short label for display: "night" or "day" for light sessions, frame type for calibration.
    public var kindLabel: String { isCalibration ? frameType : (isNight ? "night" : "day") }

    public init(
        id: UUID = UUID(),
        name: String,
        date: Date,
        isNight: Bool,
        frameType: String = "light",
        latitude: Double = 0,
        longitude: Double = 0,
        frameCount: Int = 0,
        startTime: Date? = nil,
        endTime: Date? = nil,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.date = date
        self.isNight = isNight
        self.frameType = frameType
        self.latitude = latitude
        self.longitude = longitude
        self.frameCount = frameCount
        self.startTime = startTime
        self.endTime = endTime
        self.addedAt = addedAt
    }
}
