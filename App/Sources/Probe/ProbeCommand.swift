#if DEBUG
    import ChatAuth
    import ChatKeychain
    import Foundation
    import Network
    import Synchronization

    /// `gchat-mac --keychain-probe <mode>`: checks keychain and loopback behaviour inside the signed, sandboxed app.
    /// `make keychain-probe` runs the modes in order, re-signing the app between `write` and `verify`.
    enum ProbeCommand {
        static let item = SecretID(service: "io.github.drekinov.gchat-mac.probe", account: "probe")
        static let foreignItem = SecretID(service: "io.github.drekinov.gchat-mac.probe.foreign", account: "probe")
        static let expected = Data("gchat-mac keychain probe v1".utf8)

        static func run(mode: String) async -> Int32 {
            var report = Report()
            switch mode {
            case "write": write(&report)
            case "verify": verify(&report)
            case "foreign": foreign(&report)
            case "loopback": await loopback(&report)
            default:
                print("usage: gchat-mac --keychain-probe write|verify|foreign|loopback")
                return 64
            }
            return report.finish(mode: mode)
        }

        private static func write(_ report: inout Report) {
            let legacy = Keychain(backend: .legacy)
            report.check("legacy: delete leftover") { try legacy.delete(item) }
            report.check("legacy: add") { try legacy.write(Data("first".utf8), for: item) }
            report.check("legacy: update") { try legacy.write(expected, for: item) }
            report.expect("legacy: read back", try legacy.read(item), equals: expected)

            // Informational: the data-protection keychain needs a provisioning profile we don't have.
            let dataProtection = Keychain(backend: .dataProtection)
            do {
                try dataProtection.write(expected, for: item)
                report.info("data-protection: write succeeded")
                try dataProtection.delete(item)
            } catch {
                report.info("data-protection: \(error)")
            }
        }

        private static func verify(_ report: inout Report) {
            let legacy = Keychain(backend: .legacy)
            report.expect("legacy: read after re-sign without prompt", try legacy.read(item), equals: expected)
            report.check("legacy: delete") { try legacy.delete(item) }
            report.expect("legacy: read after delete is absent", try legacy.read(item), equals: nil)
            report.check("legacy: second delete is a no-op") { try legacy.delete(item) }
        }

        private static func foreign(_ report: inout Report) {
            let legacy = Keychain(backend: .legacy)
            do {
                let value = try legacy.read(foreignItem)
                if value == nil {
                    report.fail("foreign item reported absent: an unreadable key would look like a missing one")
                } else {
                    report.info("foreign item readable without prompt (its ACL trusts this app)")
                }
            } catch {
                report.pass("foreign item is an error, not absent: \(error)")
            }
        }

        private static func loopback(_ report: inout Report) async {
            let listener: LoopbackListener
            do {
                listener = try await LoopbackListener.start()
            } catch {
                return report.fail("listener start: \(error)")
            }
            report.info("redirect URI \(listener.redirectURI.absoluteString)")
            guard let port = listener.redirectURI.port.flatMap({ NWEndpoint.Port(rawValue: UInt16($0)) }) else {
                return report.fail("redirect URI has no port")
            }

            async let callback = listener.callback(timeout: .seconds(5))
            let stray = await RawHTTP.get(port: port, target: "/favicon.ico")
            report.expect("stray path gets 404", stray?.hasPrefix("HTTP/1.1 404"), equals: true)
            let reply = await RawHTTP.get(port: port, target: "\(LoopbackListener.callbackPath)?code=abc&state=xyz")
            report.expect("callback gets 200", reply?.hasPrefix("HTTP/1.1 200"), equals: true)
            do {
                let components = try await callback
                let query = Dictionary(
                    (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
                report.expect("callback query", query, equals: ["code": "abc", "state": "xyz"])
            } catch {
                report.fail("callback: \(error)")
            }
        }
    }

    private struct Report {
        private var failures = 0

        mutating func pass(_ name: String) { print("PASS \(name)") }
        mutating func info(_ text: String) { print("INFO \(text)") }

        mutating func fail(_ name: String) {
            failures += 1
            print("FAIL \(name)")
        }

        mutating func check(_ name: String, _ body: () throws -> Void) {
            do {
                try body()
                pass(name)
            } catch {
                fail("\(name): \(error)")
            }
        }

        mutating func expect<T: Equatable>(_ name: String, _ body: @autoclosure () throws -> T, equals expected: T) {
            do {
                let actual = try body()
                actual == expected ? pass(name) : fail("\(name): unexpected value")
            } catch {
                fail("\(name): \(error)")
            }
        }

        func finish(mode: String) -> Int32 {
            print(failures == 0 ? "probe \(mode): ok" : "probe \(mode): \(failures) failed")
            return failures == 0 ? 0 : 1
        }
    }

    /// NWConnection client, so the probe isn't subject to App Transport Security.
    private enum RawHTTP {
        static func get(port: NWEndpoint.Port, target: String) async -> String? {
            let connection = NWConnection(host: .ipv4(.loopback), port: port, using: .tcp)
            let request = "GET \(target) HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
            return await withCheckedContinuation { continuation in
                let once = Once()
                let finish: @Sendable (String?) -> Void = { reply in
                    guard once.claim() else { return }
                    continuation.resume(returning: reply)
                    connection.cancel()
                }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        connection.send(content: Data(request.utf8), completion: .contentProcessed { _ in })
                        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                            finish(data.flatMap { String(data: $0, encoding: .utf8) })
                        }
                    case .failed, .waiting, .cancelled:
                        finish(nil)
                    default:
                        break
                    }
                }
                connection.start(queue: .global())
            }
        }

        private final class Once: Sendable {
            private let claimed = Mutex(false)

            func claim() -> Bool {
                claimed.withLock { claimed in
                    defer { claimed = true }
                    return !claimed
                }
            }
        }
    }
#endif
