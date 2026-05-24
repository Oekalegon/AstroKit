public enum ProcessingLevel: String, Sendable, Codable, CaseIterable {
    case raw
    case calibrated
    case stacked
    case stretched
}
