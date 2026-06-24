import Foundation

struct CodexHooksManifest {
    private var root: [String: Any]

    init(existingJSON: String?) throws {
        if let existingJSON, !existingJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let data = existingJSON.data(using: .utf8) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let object = try JSONSerialization.jsonObject(with: data, options: [])
            guard let dictionary = object as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            root = dictionary
        } else {
            root = [:]
        }
    }

    var isEmpty: Bool {
        guard let hooks = root["hooks"] as? [String: Any] else {
            return true
        }

        return hooks.isEmpty
    }

    func containsPulseHook(command: String) -> Bool {
        guard let hooks = root["hooks"] as? [String: Any] else {
            return false
        }

        return hooks.values.contains { value in
            guard let groups = value as? [[String: Any]] else {
                return false
            }

            return groups.contains { group in
                guard let commands = group["hooks"] as? [[String: Any]] else {
                    return false
                }

                return commands.contains {
                    ($0["type"] as? String) == "command" && ($0["command"] as? String) == command
                }
            }
        }
    }

    func mergingPulseHooks(command: String) -> CodexHooksManifest {
        var copy = self
        copy.removePulseHooks(command: command)
        copy.insertPulseHooks(command: command)
        return copy
    }

    func removingPulseHooks(command: String) -> CodexHooksManifest {
        var copy = self
        copy.removePulseHooks(command: command)
        return copy
    }

    func render() throws -> String {
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        guard var string = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadUnknown)
        }

        if !string.hasSuffix("\n") {
            string.append("\n")
        }

        return string
    }

    private mutating func removePulseHooks(command: String) {
        guard var hooks = root["hooks"] as? [String: Any] else {
            return
        }

        for event in Self.pulseEvents {
            guard var groups = hooks[event] as? [[String: Any]] else {
                continue
            }

            groups = groups.compactMap { group in
                guard var commands = group["hooks"] as? [[String: Any]] else {
                    return group
                }

                commands.removeAll {
                    ($0["type"] as? String) == "command" && ($0["command"] as? String) == command
                }

                if commands.isEmpty {
                    return nil
                }

                var updated = group
                updated["hooks"] = commands
                return updated
            }

            if groups.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = groups
            }
        }

        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }
    }

    private mutating func insertPulseHooks(command: String) {
        let entry: [String: Any] = [
            "matcher": "*",
            "hooks": [
                [
                    "type": "command",
                    "command": command
                ]
            ]
        ]

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in Self.pulseEvents {
            var groups = hooks[event] as? [[String: Any]] ?? []
            if groups.contains(where: { group in
                guard let commands = group["hooks"] as? [[String: Any]] else {
                    return false
                }

                return commands.contains {
                    ($0["type"] as? String) == "command" && ($0["command"] as? String) == command
                }
            }) {
                continue
            }

            groups.append(entry)
            hooks[event] = groups
        }

        root["hooks"] = hooks
    }

    private static let pulseEvents = ["SessionStart", "UserPromptSubmit", "SubagentStart", "SubagentStop", "Stop"]
}
