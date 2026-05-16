import SwiftUI

struct ContentView: View {
    @State private var status: String = "Not signed in"
    @State private var files: [GoogleDriveClient.DriveFile] = []
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("StickyDocs — Auth smoke test")
                .font(.headline)

            HStack {
                Button("Sign in with Google") { Task { await signIn() } }
                    .disabled(isWorking)
                Button("List Drive files") { Task { await list() } }
                    .disabled(isWorking)
                Button("Sign out") { signOut() }
                    .disabled(isWorking)
            }

            Text(status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            List(files) { f in
                VStack(alignment: .leading) {
                    Text(f.name).font(.body)
                    Text(f.mimeType).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 200)
        }
        .padding()
        .frame(minWidth: 500, minHeight: 400)
    }

    private func signIn() async {
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await AuthService.shared.signIn()
            status = "Signed in. Try 'List Drive files'."
        } catch {
            status = "Sign-in failed: \(error.localizedDescription)"
        }
    }

    private func list() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let result = try await GoogleDriveClient(auth: .shared).listAppFiles()
            files = result
            status = "Loaded \(result.count) file(s) visible under drive.file scope."
        } catch {
            status = "List failed: \(error.localizedDescription)"
        }
    }

    private func signOut() {
        do {
            try AuthService.shared.signOut()
            files = []
            status = "Signed out."
        } catch {
            status = "Sign-out failed: \(error.localizedDescription)"
        }
    }
}

#Preview {
    ContentView()
}
