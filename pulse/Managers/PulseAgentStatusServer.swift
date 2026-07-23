import Foundation
import Network

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
        let parentSessionID: String?
        let isSubagent: Bool?
        let transcriptPath: String?
        let turnID: String?

        var event: PulseAgentStatusEvent {
            PulseAgentStatusEvent(
                agent: agent,
                sessionID: sessionID,
                projectPath: projectPath,
                sessionTitle: title,
                timestamp: timestamp,
                kind: kind,
                message: message,
                parentSessionID: parentSessionID,
                isSubagent: isSubagent ?? false,
                transcriptPath: transcriptPath,
                turnID: turnID
            )
        }
    }

    private let store: AgentStatusStore
    private let decoder: JSONDecoder
    private var isRunning = false
    private var listener: NWListener?

    init(store: AgentStatusStore) {
        self.store = store

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    deinit {
        listener?.cancel()
    }

    func start() {
        guard isRunning == false else {
            return
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        let loopback = NWEndpoint.Host.ipv4(IPv4Address("127.0.0.1")!)
        guard let port = NWEndpoint.Port(rawValue: 45821),
              let listener = try? NWListener(
                using: parametersWithLoopbackEndpoint(parameters, host: loopback, port: port)
              ) else {
            return
        }

        listener.newConnectionHandler = { [weak self] connection in
            guard Self.isLoopbackEndpoint(connection.endpoint) else {
                connection.cancel()
                return
            }

            connection.start(queue: .global(qos: .userInitiated))
            self?.receiveNextMessage(on: connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard case .failed = state else { return }
            Task { @MainActor in
                self?.listener?.cancel()
                self?.listener = nil
                self?.isRunning = false
            }
        }
        listener.start(queue: .global(qos: .userInitiated))

        self.listener = listener
        isRunning = true
    }

    func handlePayload(_ payload: Data) throws {
        let event = try decoder.decode(Payload.self, from: payload).event
        guard event.sessionID.isEmpty == false, event.projectPath.isEmpty == false else {
            throw PulseAgentStatusServerError.invalidPayload
        }

        store.apply(event)
    }

    func handleFramedPayloads(_ data: Data, buffer: inout Data, flushRemainder: Bool = false) {
        buffer.append(data)

        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let frame = buffer[..<newlineIndex]
            buffer.removeSubrange(...newlineIndex)
            handleFrame(frame)
        }

        if flushRemainder, buffer.isEmpty == false {
            handleFrame(buffer[...])
            buffer.removeAll()
        }
    }

    private func handleFrame(_ frame: Data.SubSequence) {
        let payload = Data(frame).trimmingASCIIWhitespace()
        guard payload.isEmpty == false else {
            return
        }

        try? handlePayload(payload)
    }

    nonisolated private func receiveNextMessage(on connection: NWConnection, buffer: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                var nextBuffer = buffer
                if let data, data.isEmpty == false {
                    self?.handleFramedPayloads(data, buffer: &nextBuffer, flushRemainder: isComplete)
                } else if isComplete {
                    self?.handleFramedPayloads(Data(), buffer: &nextBuffer, flushRemainder: true)
                }

                if error == nil, isComplete == false {
                    self?.receiveNextMessage(on: connection, buffer: nextBuffer)
                } else {
                    connection.cancel()
                }
            }
        }
    }

    private func parametersWithLoopbackEndpoint(
        _ parameters: NWParameters,
        host: NWEndpoint.Host,
        port: NWEndpoint.Port
    ) -> NWParameters {
        parameters.requiredLocalEndpoint = .hostPort(host: host, port: port)
        return parameters
    }

    nonisolated private static func isLoopbackEndpoint(_ endpoint: NWEndpoint) -> Bool {
        switch endpoint {
        case let .hostPort(host, _):
            switch host {
            case let .ipv4(address):
                return "\(address)" == "127.0.0.1"
            case let .ipv6(address):
                return "\(address)" == "::1"
            case let .name(name, _):
                return name == "localhost"
            @unknown default:
                return false
            }
        default:
            return false
        }
    }
}

private extension Data {
    func trimmingASCIIWhitespace() -> Data {
        let whitespace = Set<UInt8>([0x09, 0x0A, 0x0D, 0x20])
        let bytes = Array(self)
        guard let start = bytes.firstIndex(where: { whitespace.contains($0) == false }) else {
            return Data()
        }
        let end = bytes.lastIndex(where: { whitespace.contains($0) == false }) ?? start
        return Data(bytes[start...end])
    }
}
