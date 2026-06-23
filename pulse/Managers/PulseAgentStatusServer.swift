import Foundation

enum PulseAgentStatusServerError: Error {
    case invalidPayload
}

@MainActor
final class PulseAgentStatusServer {
    private struct Payload: Decodable {
        let agent: AgentStatusAgent
        let sessionID: String
        let projectPath: String
        let title: String
        let timestamp: Date
        let kind: PulseAgentStatusEventKind
        let message: String?

        var event: PulseAgentStatusEvent {
            PulseAgentStatusEvent(
                agent: agent,
                sessionID: sessionID,
                projectPath: projectPath,
                sessionTitle: title,
                timestamp: timestamp,
                kind: kind,
                message: message
            )
        }
    }

    private let store: AgentStatusStore
    private let decoder: JSONDecoder

    init(store: AgentStatusStore) {
        self.store = store

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func start() {
    }

    func handlePayload(_ payload: Data) throws {
        let event = try decoder.decode(Payload.self, from: payload).event
        guard event.sessionID.isEmpty == false, event.projectPath.isEmpty == false else {
            throw PulseAgentStatusServerError.invalidPayload
        }

        store.apply(event)
    }
}
