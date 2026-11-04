import Foundation

/// No screen text, field values, URLs or credentials belong in these events.
public struct PermissionEvent: Codable, Sendable, Equatable {
    public var date: Date
    public var kind: PermissionKind
    public var stage: String

    public init(kind: PermissionKind, stage: String, date: Date = Date()) {
        self.date = date
        self.kind = kind
        self.stage = stage
    }
}

public struct PermissionDiagnostics: Codable, Sendable, Equatable {
    public var processID: Int32
    public var bundleID: String
    public var teamID: String?
    public var osVersion: String
    public var osBuild: String
    public var events: [PermissionEvent]

    public init(processID: Int32, bundleID: String, teamID: String?, osVersion: String, osBuild: String, events: [PermissionEvent]) {
        self.processID = processID
        self.bundleID = bundleID
        self.teamID = teamID
        self.osVersion = osVersion
        self.osBuild = osBuild
        self.events = events
    }
}
