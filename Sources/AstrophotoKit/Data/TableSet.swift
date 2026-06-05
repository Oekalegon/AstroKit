import Foundation

/// A collection of tables — analogous to FrameSet for frames.
public struct TableSet: ProcessData {

    public let identifier: UUID = UUID()

    public var instantiatedAt: Date? {
        guard !tables.isEmpty, tables.allSatisfy({ $0.isInstantiated }) else { return nil }
        return tables.compactMap { $0.instantiatedAt }.max()
    }

    public var isInstantiated: Bool {
        !tables.isEmpty && tables.allSatisfy { $0.isInstantiated }
    }

    public var isCollection: Bool { true }
    public var collectionCount: Int { tables.count }

    public var inputLinks: [ProcessDataLink]
    public var outputLink: ProcessDataLink?

    public let tables: [TableData]

    public init(
        tables: [TableData],
        outputProcess: (id: UUID, name: String, stepLinkID: String)?,
        inputProcesses: [(id: UUID, name: String, stepLinkID: String)]
    ) {
        self.tables = tables
        self.outputLink = outputProcess.map {
            .output(process: $0.id, link: $0.name, type: .tableSet, stepLinkID: $0.stepLinkID)
        }
        self.inputLinks = inputProcesses.map {
            .input(process: $0.id, link: $0.name, type: .tableSet, collectionMode: .individually, stepLinkID: $0.stepLinkID)
        }
    }

    public mutating func addInputLink(process: UUID, link: String, collectionMode: CollectionMode) {
        guard let outputLink,
              case .output(_, _, _, let stepLinkID) = outputLink else {
            fatalError("Output link is not set for TableSet")
        }
        inputLinks.append(.input(process: process, link: link, type: .tableSet, collectionMode: collectionMode, stepLinkID: stepLinkID))
    }

    public func metadata(for key: any MetadataKey) -> Any? { nil }
}
