import Foundation
import os

/// The data stack for a pipeline.
/// 
/// The data stack is used to track the data that is available for the pipeline.
public actor DataStack {

    private var data: [ProcessData] = []

    // Create
    public func add(data: ProcessData) {
        self.data.append(data)
        Logger.pipeline.debug("Added data \(data.identifier) to the data stack")
    }

    // Read
    public func getAll() -> [ProcessData] {
        return data
    }

    public func get(by identifier: UUID) -> ProcessData? {
        return data.first(where: { $0.identifier == identifier })
    }

    public func contains(identifier: UUID) -> Bool {
        return data.contains(where: { $0.identifier == identifier })
    }

    // Update
    public func update(data newData: ProcessData) -> Bool {
        guard let index = data.firstIndex(where: { $0.identifier == newData.identifier }) else {
            return false
        }
        data[index] = newData
        Logger.pipeline.debug("Updated data \(newData.identifier) in the data stack")
        return true
    }

    // Delete
    public func remove(identifier: UUID) -> Bool {
        guard let index = data.firstIndex(where: { $0.identifier == identifier }) else {
            return false
        }
        data.remove(at: index)
        Logger.pipeline.debug("Removed data \(identifier) from the data stack")
        return true
    }

    public func removeAll() {
        data.removeAll()
        Logger.pipeline.debug("Removed all data from the data stack")
    }

    public func count() -> Int {
        return data.count
    }

    /// Find ProcessData by its output link or input link
    /// 
    /// - If an output link is provided, matches against the ProcessData's outputLink
    /// - If an input link is provided, matches against:
    ///   1. The ProcessData's inputLinks (for data that already has input links)
    ///   2. The ProcessData's outputLink (for data that hasn't been connected yet - both initial inputs and step outputs)
    ///   When matching against outputLink, only stepLinkID and type are used (linkName differs between input parameter and output name)
    ///   (collectionMode is ignored when matching input links)
    /// - Parameter link: The output or input link to search for
    /// - Returns: The ProcessData with the matching link, or nil if not found
    public func get(by link: ProcessDataLink) -> ProcessData? {
        return data.first { dataItem in
            switch link {
            case .output(let processId, let linkName, let linkType, let stepLinkID):
                // Match against outputLink (type and stepLinkID matter for matching)
                if case .output(let dataProcessId, let dataLinkName, let dataLinkType, let dataStepLinkID) = dataItem.outputLink {
                    return processId == dataProcessId && linkName == dataLinkName && linkType == dataLinkType && stepLinkID == dataStepLinkID
                }
                return false
            case .input(let processId, let linkName, let linkType, _, let stepLinkID):
                // First, try to match against existing inputLinks
                if dataItem.inputLinks.contains(where: { inputLink in
                    if case .input(let linkProcessId, let linkLinkName, let linkLinkType, _, let linkStepLinkID) = inputLink {
                        return processId == linkProcessId && linkName == linkLinkName && linkType == linkLinkType && stepLinkID == linkStepLinkID
                    }
                    return false
                }) {
                    return true
                }
                // If no inputLinks match, try to match against outputLink
                // This handles both initial input data and step output data that haven't been connected yet
                // Match by stepLinkID and type only (linkName differs between input parameter name and output name)
                if case .output(_, _, let dataLinkType, let dataStepLinkID) = dataItem.outputLink {
                    let matches = linkType == dataLinkType && stepLinkID == dataStepLinkID
                    if !matches {
                        Logger.pipeline.debug("DataStack.get: No match for input link '\(linkName)' (stepLinkID: '\(stepLinkID)', type: \(linkType.rawValue)) against outputLink (stepLinkID: '\(dataStepLinkID)', type: \(dataLinkType.rawValue))")
                    }
                    return matches
                } else {
                    Logger.pipeline.debug("DataStack.get: Data item \(dataItem.identifier) has no outputLink")
                }
                return false
            }
        }
    }
}

