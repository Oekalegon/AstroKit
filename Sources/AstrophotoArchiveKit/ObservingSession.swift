//
//  ObservingSession.swift
//  AstrophotoArchiveKit
//

import Foundation

/// An observing session — typically one night's imaging from a single location.
///
/// Night sessions span two calendar dates in local time (observations starting
/// before midnight and continuing past it). The session is named after the
/// calendar date of the preceding local sunset: e.g. a frame captured at
/// 01:30 on 16 June belongs to the "15 June 2026" session.
///
/// Day sessions cover solar or daytime imaging and are named after the
/// calendar date of the observation.
public struct ObservingSession: Sendable, Identifiable {
    public let id: UUID
    /// Human-readable name: "15 June 2026".
    public var name: String
    /// Local calendar date that names the session.
    /// For night sessions this is the date of the preceding sunset;
    /// for day sessions it is the date of the observation itself.
    public var date: Date
    /// `true` for night-time imaging, `false` for daytime (solar) imaging.
    public var isNight: Bool
    /// Mean geographic latitude of the frames in this session, in degrees (north positive).
    public var latitude: Double
    /// Mean geographic longitude of the frames in this session, in degrees (east positive).
    public var longitude: Double
    /// Number of raw frames in this session.
    public var frameCount: Int
    /// Timestamp of the earliest frame in this session.
    public var startTime: Date?
    /// Timestamp of the latest frame in this session.
    public var endTime: Date?
    public var addedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        date: Date,
        isNight: Bool,
        latitude: Double,
        longitude: Double,
        frameCount: Int = 0,
        startTime: Date? = nil,
        endTime: Date? = nil,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.date = date
        self.isNight = isNight
        self.latitude = latitude
        self.longitude = longitude
        self.frameCount = frameCount
        self.startTime = startTime
        self.endTime = endTime
        self.addedAt = addedAt
    }
}
