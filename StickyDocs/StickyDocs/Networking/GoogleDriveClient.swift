import Foundation

struct GoogleDriveClient {
    let auth: AuthService

    struct DriveFile: Decodable, Identifiable {
        let id: String
        let name: String
        let mimeType: String
    }

    func listAppFiles() async throws -> [DriveFile] {
        let token = try await auth.accessToken()

        var comps = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        comps.queryItems = [
            .init(name: "spaces", value: "drive"),
            .init(name: "fields", value: "files(id,name,mimeType)"),
            .init(name: "pageSize", value: "50")
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "GoogleDrive", code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                          userInfo: [NSLocalizedDescriptionKey: body])
        }
        struct ListResponse: Decodable { let files: [DriveFile] }
        return try JSONDecoder().decode(ListResponse.self, from: data).files
    }
}
