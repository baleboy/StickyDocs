import SwiftUI
import AppKit

struct ContentView: View {
    @State private var status: String = "Not signed in"
    @State private var files: [GoogleDriveClient.DriveFile] = []
    @State private var isWorking = false
    @State private var roundTripResults: [RoundTripHarness.CaseResult] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("StickyDocs — Auth & Round-Trip Harness")
                .font(.headline)

            HStack {
                Button("Sign in with Google") { Task { await signIn() } }
                    .disabled(isWorking)
                Button("List Drive files") { Task { await list() } }
                    .disabled(isWorking)
                Button("Sign out") { signOut() }
                    .disabled(isWorking)
            }
            HStack {
                Button("Run Doc Round-Trip Test") { Task { await runRoundTrip() } }
                    .disabled(isWorking)
                Button("Copy results") { copyResults() }
                    .disabled(roundTripResults.isEmpty)
                Button("Save creds for tests") { saveCredsForTests() }
                    .disabled(isWorking)
                if isWorking { ProgressView().controlSize(.small) }
            }

            Text(status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            if !roundTripResults.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(roundTripResults, id: \.name) { result in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(result.passed ? "✅" : "❌")
                                    Text(result.name).bold()
                                }
                                if !result.passed {
                                    Text("expected: \(result.expected)")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                    Text("actual:   \(result.actual)")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.red)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
            } else {
                List(files) { f in
                    VStack(alignment: .leading) {
                        Text(f.name).font(.body)
                        Text(f.mimeType).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 200)
            }
        }
        .padding()
        .frame(minWidth: 600, minHeight: 500)
    }

    private func signIn() async {
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await AuthService.shared.signIn()
            status = "Signed in. Try 'List Drive files' or 'Run Doc Round-Trip Test'."
        } catch {
            status = "Sign-in failed: \(error.localizedDescription)"
        }
    }

    private func list() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let result = try await GoogleDriveClient(accessToken: { try await AuthService.shared.accessToken() }).listAppFiles()
            files = result
            roundTripResults = []
            status = "Loaded \(result.count) file(s) visible under drive.file scope."
        } catch {
            status = "List failed: \(error.localizedDescription)"
        }
    }

    private func signOut() {
        do {
            try AuthService.shared.signOut()
            files = []
            roundTripResults = []
            status = "Signed out."
        } catch {
            status = "Sign-out failed: \(error.localizedDescription)"
        }
    }

    private func copyResults() {
        var lines: [String] = []
        for r in roundTripResults {
            lines.append("\(r.passed ? "PASS" : "FAIL") \(r.name)")
            if !r.passed {
                let exp = Array(r.expected.unicodeScalars)
                let act = Array(r.actual.unicodeScalars)
                lines.append("  expected (\(exp.count) scalars): \(r.expected)")
                lines.append("  actual   (\(act.count) scalars): \(r.actual)")
                let common = min(exp.count, act.count)
                for i in 0..<common where exp[i] != act[i] {
                    lines.append("  first diff at scalar \(i): expected U+\(String(exp[i].value, radix: 16, uppercase: true)) ('\(exp[i])'), actual U+\(String(act[i].value, radix: 16, uppercase: true)) ('\(act[i])')")
                    break
                }
                if exp.count != act.count {
                    lines.append("  length mismatch: expected \(exp.count), actual \(act.count)")
                }
            }
        }
        let text = lines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func saveCredsForTests() {
        do {
            guard let tokens = try AuthService.shared.currentTokens() else {
                status = "Not signed in - sign in first."
                return
            }
            let dir = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support/StickyDocs", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("test_creds.json")
            let payload = ["refresh_token": tokens.refreshToken]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
            try data.write(to: file)
            status = "Saved refresh token to \(file.path) - tests can now run via xcodebuild test."
        } catch {
            status = "Save failed: \(error.localizedDescription)"
        }
    }

    private func runRoundTrip() async {
        isWorking = true
        defer { isWorking = false }
        roundTripResults = []
        status = "Running round-trip test against a real Google Doc…"
        do {
            let harness = RoundTripHarness(accessToken: { try await AuthService.shared.accessToken() })
            let results = try await harness.run(cases: RoundTripHarness.defaultCases)
            roundTripResults = results
            let passed = results.filter(\.passed).count
            status = "Round-trip: \(passed)/\(results.count) passed."
        } catch {
            status = "Round-trip failed: \(error.localizedDescription)"
        }
    }
}

#Preview {
    ContentView()
}
