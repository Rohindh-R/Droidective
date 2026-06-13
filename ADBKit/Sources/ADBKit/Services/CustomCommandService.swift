import Foundation

/// User-defined adb macros with {bundleId} / {serial} placeholders. The
/// command template is tokenized with quote support and passed as discrete
/// arguments — never through a shell.
public struct CustomCommandService: Sendable {
    public enum TemplateError: Error, LocalizedError, Equatable {
        case empty
        case unbalancedQuote
        case missingBundle

        public var errorDescription: String? {
            switch self {
            case .empty: return "The command is empty."
            case .unbalancedQuote: return "Unbalanced quote in the command."
            case .missingBundle: return "This command needs a saved bundle — pick one first."
            }
        }
    }

    let client: AdbClient

    public init(client: AdbClient) {
        self.client = client
    }

    /// Split a template into argv tokens, honoring single/double quotes.
    public static func tokenize(_ template: String) throws(TemplateError) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var hasContent = false

        for char in template {
            if let activeQuote = quote {
                if char == activeQuote {
                    quote = nil
                } else {
                    current.append(char)
                }
            } else if char == "\"" || char == "'" {
                quote = char
                hasContent = true
            } else if char == " " || char == "\t" {
                if hasContent || !current.isEmpty {
                    tokens.append(current)
                    current = ""
                    hasContent = false
                }
            } else {
                current.append(char)
            }
        }
        if quote != nil { throw .unbalancedQuote }
        if hasContent || !current.isEmpty {
            tokens.append(current)
        }
        if tokens.isEmpty { throw .empty }
        return tokens
    }

    /// Substitute placeholders and tokenize. The leading "adb" (if typed) is
    /// dropped — the client supplies the binary.
    public static func buildArgs(
        template: String, bundleId: String?, serial: String
    ) throws(TemplateError) -> [String] {
        if template.contains("{bundleId}") && (bundleId ?? "").isEmpty {
            throw .missingBundle
        }
        let substituted = template
            .replacingOccurrences(of: "{bundleId}", with: bundleId ?? "")
            .replacingOccurrences(of: "{serial}", with: serial)
        var tokens = try tokenize(substituted)
        if tokens.first == "adb" {
            tokens.removeFirst()
        }
        if tokens.isEmpty { throw .empty }
        return tokens
    }

    public func run(command: CustomCommand, bundleId: String?, serial: String) async -> FeatureResult {
        do {
            let args = try CustomCommandService.buildArgs(
                template: command.command, bundleId: bundleId, serial: serial
            )
            // Only a *leading* -s is an adb target flag; "-s" later in the
            // argv belongs to the device-side command (e.g. `pidof -s`).
            let needsSerial = !serial.isEmpty && args.first != "-s"
            let result = try await client.run(needsSerial ? ["-s", serial] + args : args)
            if result.succeeded {
                let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                return FeatureResult(
                    ok: true,
                    message: output.isEmpty ? "\(command.name) done" : String(output.prefix(200))
                )
            }
            return FeatureResult(ok: false, message: friendlyAdbError(result, fallback: "\(command.name) failed"))
        } catch let error as TemplateError {
            return FeatureResult(ok: false, message: error.localizedDescription)
        } catch {
            return FeatureResult(ok: false, message: error.localizedDescription)
        }
    }
}
