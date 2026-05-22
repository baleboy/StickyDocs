import Foundation

struct GoogleDriveClient {
    let accessToken: () async throws -> String

    struct DriveFile: Decodable, Identifiable {
        let id: String
        let name: String
        let mimeType: String
    }

    // Cross-machine restore: returns every Doc this OAuth client previously
    // created and tagged with appProperties.stickydocs=v1, regardless of which
    // device created it. drive.file scope is per OAuth client, not per device,
    // so signing in on a second Mac surfaces the stickies created on the first.
    func listTaggedStickies() async throws -> [DriveFile] {
        let token = try await accessToken()
        let query = "appProperties has { key='stickydocs' and value='v1' } and mimeType='application/vnd.google-apps.document' and trashed=false"
        var comps = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        comps.queryItems = [
            .init(name: "q", value: query),
            .init(name: "fields", value: "files(id,name,mimeType)"),
            .init(name: "pageSize", value: "100")
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: req)
        try Self.assertOK(response: response, data: data)
        struct ListResponse: Decodable { let files: [DriveFile] }
        return try JSONDecoder().decode(ListResponse.self, from: data).files
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

    func createDoc(title: String, parentFolderId: String? = nil) async throws -> String {
        let token = try await accessToken()
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "name": title,
            "mimeType": "application/vnd.google-apps.document",
            "appProperties": ["stickydocs": "v1"]
        ]
        if let parentFolderId { body["parents"] = [parentFolderId] }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        try Self.assertOK(response: response, data: data)
        struct CreateResponse: Decodable { let id: String }
        return try JSONDecoder().decode(CreateResponse.self, from: data).id
    }

    func findOrCreateFolder(named name: String) async throws -> String {
        let token = try await accessToken()
        let escaped = name.replacingOccurrences(of: "'", with: "\\'")
        let query = "mimeType='application/vnd.google-apps.folder' and name='\(escaped)' and trashed=false"
        var comps = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        comps.queryItems = [
            .init(name: "q", value: query),
            .init(name: "fields", value: "files(id,name)"),
            .init(name: "pageSize", value: "1")
        ]
        var listReq = URLRequest(url: comps.url!)
        listReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (listData, listResp) = try await URLSession.shared.data(for: listReq)
        try Self.assertOK(response: listResp, data: listData)
        struct FolderRef: Decodable { let id: String; let name: String }
        struct ListResponse: Decodable { let files: [FolderRef] }
        if let existing = (try JSONDecoder().decode(ListResponse.self, from: listData)).files.first {
            return existing.id
        }

        var createReq = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files")!)
        createReq.httpMethod = "POST"
        createReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        createReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "name": name,
            "mimeType": "application/vnd.google-apps.folder"
        ]
        createReq.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (createData, createResp) = try await URLSession.shared.data(for: createReq)
        try Self.assertOK(response: createResp, data: createData)
        struct CreateResponse: Decodable { let id: String }
        return try JSONDecoder().decode(CreateResponse.self, from: createData).id
    }

    func isTrashed(docId: String) async throws -> Bool {
        let token = try await accessToken()
        var comps = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(docId)")!
        comps.queryItems = [.init(name: "fields", value: "trashed")]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        try Self.assertOK(response: response, data: data)
        struct Resp: Decodable { let trashed: Bool }
        return try JSONDecoder().decode(Resp.self, from: data).trashed
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
