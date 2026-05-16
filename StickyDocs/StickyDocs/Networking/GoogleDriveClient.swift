import Foundation

struct GoogleDriveClient {
    let accessToken: () async throws -> String

    struct DriveFile: Decodable, Identifiable {
        let id: String
        let name: String
        let mimeType: String
    }

    func listAppFiles() async throws -> [DriveFile] {
        let token = try await accessToken()

        var comps = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        comps.queryItems = [
            .init(name: "spaces", value: "drive"),
            .init(name: "fields", value: "files(id,name,mimeType)"),
            .init(name: "pageSize", value: "50")
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: req)
        try Self.assertOK(response: response, data: data)
        struct ListResponse: Decodable { let files: [DriveFile] }
        return try JSONDecoder().decode(ListResponse.self, from: data).files
    }

    func createDoc(title: String) async throws -> String {
        let token = try await accessToken()
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "name": title,
            "mimeType": "application/vnd.google-apps.document",
            "appProperties": ["stickydocs": "v1"]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        try Self.assertOK(response: response, data: data)
        struct CreateResponse: Decodable { let id: String }
        return try JSONDecoder().decode(CreateResponse.self, from: data).id
    }

    func exportAsHTML(docId: String) async throws -> String {
        let token = try await accessToken()
        var comps = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(docId)/export")!
        comps.queryItems = [.init(name: "mimeType", value: "text/html")]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: req)
        try Self.assertOK(response: response, data: data)
        return String(data: data, encoding: .utf8) ?? ""
    }

    func deleteFile(id: String) async throws {
        let token = try await accessToken()
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/\(id)")!)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: req)
        try Self.assertOK(response: response, data: data)
    }

    private static func assertOK(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "GoogleDrive",
                          code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                          userInfo: [NSLocalizedDescriptionKey: body])
        }
    }
}
