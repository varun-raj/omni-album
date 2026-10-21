//
//  NextcloudService.swift
//  OmniAlbum
//
//  Handles WebDAV communication with Nextcloud Photos public albums.
//  Uses PROPFIND on /remote.php/dav/photospublic/{TOKEN} for listing,
//  and /apps/photos/api/v1/publicPreview/{fileId} for thumbnails.
//

import Foundation

// MARK: - Error Types

enum NextcloudServiceError: LocalizedError {
    case invalidBaseURL(String)
    case invalidResponse
    case httpError(status: Int, message: String?)
    case xmlParsingError
    case passwordRequired
    case emptyAlbum

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let url): return "Invalid server URL: \(url)"
        case .invalidResponse: return "Invalid response from server."
        case .httpError(let status, let message):
            if let message, !message.isEmpty { return "Server error (\(status)): \(message)" }
            return "Server error: \(status)"
        case .xmlParsingError: return "Failed to parse server response."
        case .passwordRequired: return "This album requires a password."
        case .emptyAlbum: return "This album contains no photos."
        }
    }
}

// MARK: - Nextcloud File Model

struct NextcloudFile {
    let href: String
    let displayName: String?
    let contentType: String?
    let contentLength: Int64?
    let lastModified: String?
    let fileId: String?
    let permissions: String?
    let isCollection: Bool
    let hasPreview: Bool
    let width: Int?
    let height: Int?
    let originalDateTime: String?
    let originalName: String?
    let nbItems: Int?
    let dateRange: String?
    let location: String?

    /// Extract the filename from the href path (format: {fileId}-{fileName})
    var fileName: String? {
        let path = href.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let lastComponent = path.split(separator: "/").last else { return nil }
        let name = String(lastComponent).removingPercentEncoding ?? String(lastComponent)
        // Files in photospublic are named "{fileId}-{fileName}"
        if let dashIndex = name.firstIndex(of: "-") {
            return String(name[name.index(after: dashIndex)...])
        }
        return name
    }

    /// Whether this file is an image or video (media file)
    var isMedia: Bool {
        guard let ct = contentType?.lowercased() else { return false }
        return ct.hasPrefix("image/") || ct.hasPrefix("video/")
    }

    var isVideo: Bool {
        contentType?.lowercased().hasPrefix("video/") == true
    }
}

// MARK: - Service

final class NextcloudService {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }

    /// Normalize a base URL to scheme://host[:port]
    func normalizeBaseURL(_ raw: String) -> String? {
        ServerBaseURL.normalize(raw)
    }

    /// Fetch album info (PROPFIND Depth: 0) - returns the album collection metadata
    func fetchAlbumInfo(baseURL: String, token: String, password: String? = nil) async throws -> NextcloudFile {
        let files = try await propfind(baseURL: baseURL, token: token, password: password, depth: "0")
        guard let album = files.first else {
            throw NextcloudServiceError.invalidResponse
        }
        return album
    }

    /// List all files in the album (PROPFIND Depth: 1) - returns media files only
    func listFiles(baseURL: String, token: String, password: String? = nil) async throws -> [NextcloudFile] {
        let files = try await propfind(baseURL: baseURL, token: token, password: password, depth: "1")
        // First result is the collection itself, skip it. Filter to media files only.
        return files.dropFirst().filter { $0.isMedia }
    }

    /// Upload a file to the public album via WebDAV PUT
    func uploadFile(
        baseURL: String,
        token: String,
        password: String?,
        fileName: String,
        file: URL,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let base = normalizeBaseURL(baseURL) else {
            throw NextcloudServiceError.invalidBaseURL(baseURL)
        }

        let urlString = "\(base)/public.php/dav/files/\(token)/\(fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName)"
        guard let url = URL(string: urlString) else {
            throw NextcloudServiceError.invalidBaseURL(urlString)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")

        // Auth: token as username, password (or empty) as password
        let authString = "\(token):\(password ?? "")"
        if let authData = authString.data(using: .utf8) {
            request.setValue("Basic \(authData.base64EncodedString())", forHTTPHeaderField: "Authorization")
        }

        let delegate = NextcloudUploadDelegate(progressHandler: progressHandler)
        let delegateSession = URLSession(
            configuration: session.configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { delegateSession.finishTasksAndInvalidate() }

        let (_, response) = try await delegateSession.upload(for: request, fromFile: file)
        progressHandler(1.0)

        guard let http = response as? HTTPURLResponse else {
            throw NextcloudServiceError.invalidResponse
        }

        guard (200...299).contains(http.statusCode) else {
            throw NextcloudServiceError.httpError(status: http.statusCode, message: "Upload failed")
        }
    }

    // MARK: - Private

    private func propfind(
        baseURL: String,
        token: String,
        password: String?,
        depth: String
    ) async throws -> [NextcloudFile] {
        guard let base = normalizeBaseURL(baseURL) else {
            throw NextcloudServiceError.invalidBaseURL(baseURL)
        }

        let urlString = "\(base)/remote.php/dav/photospublic/\(token)"
        guard let url = URL(string: urlString) else {
            throw NextcloudServiceError.invalidBaseURL(urlString)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.setValue(depth, forHTTPHeaderField: "Depth")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")

        // Basic auth: token as username, empty password (or share password)
        let authString = "\(token):\(password ?? "")"
        if let authData = authString.data(using: .utf8) {
            request.setValue("Basic \(authData.base64EncodedString())", forHTTPHeaderField: "Authorization")
        }

        let xmlBody = buildPropfindBody()
        request.httpBody = xmlBody.data(using: .utf8)

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw NextcloudServiceError.invalidResponse
        }

        if http.statusCode == 401 {
            throw NextcloudServiceError.passwordRequired
        }

        guard (200...299).contains(http.statusCode) || http.statusCode == 207 else {
            let message = String(data: data, encoding: .utf8)
            throw NextcloudServiceError.httpError(status: http.statusCode, message: message)
        }

        return try await Task.detached {
            try WebDAVXMLParser.parse(data: data)
        }.value
    }

    private func buildPropfindBody() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <d:propfind xmlns:d="DAV:"
                    xmlns:oc="http://owncloud.org/ns"
                    xmlns:nc="http://nextcloud.org/ns"
                    xmlns:ocs="http://open-collaboration-services.org/ns">
            <d:prop>
                <d:getcontentlength />
                <d:getcontenttype />
                <d:getetag />
                <d:getlastmodified />
                <d:resourcetype />
                <oc:fileid />
                <oc:permissions />
                <nc:has-preview />
                <nc:metadata-photos-size />
                <nc:metadata-photos-original_date_time />
                <nc:original-name />
                <nc:nbItems />
                <nc:dateRange />
                <nc:location />
            </d:prop>
        </d:propfind>
        """
    }
}

// MARK: - WebDAV XML Parser

private enum WebDAVXMLParser {
    static func parse(data: Data) throws -> [NextcloudFile] {
        let delegate = WebDAVParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true

        guard parser.parse() else {
            throw NextcloudServiceError.xmlParsingError
        }

        return delegate.files
    }
}

// MARK: - SAX Parser Delegate

private final class WebDAVParserDelegate: NSObject, XMLParserDelegate {
    var files: [NextcloudFile] = []

    private var currentElement = ""
    private var currentText = ""
    private var inResponse = false
    private var inPropStat = false
    private var inResourceType = false

    // Current file being built
    private var href: String?
    private var displayName: String?
    private var contentType: String?
    private var contentLength: Int64?
    private var lastModified: String?
    private var fileId: String?
    private var permissions: String?
    private var isCollection = false
    private var hasPreview = false
    private var photosSize: String?
    private var originalDateTime: String?
    private var originalName: String?
    private var nbItems: String?
    private var dateRange: String?
    private var location: String?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        currentText = ""

        if elementName == "response" {
            inResponse = true
            resetCurrentFile()
        } else if elementName == "propstat" {
            inPropStat = true
        } else if elementName == "resourcetype" {
            inResourceType = true
        } else if elementName == "collection" && inResourceType {
            isCollection = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        if elementName == "resourcetype" {
            inResourceType = false
        } else if elementName == "response" && inResponse {
            let width: Int?
            let height: Int?
            if let sizeJSON = photosSize,
               let data = sizeJSON.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                width = dict["width"] as? Int
                height = dict["height"] as? Int
            } else {
                width = nil
                height = nil
            }

            let file = NextcloudFile(
                href: href ?? "",
                displayName: displayName,
                contentType: contentType,
                contentLength: contentLength,
                lastModified: lastModified,
                fileId: fileId,
                permissions: permissions,
                isCollection: isCollection,
                hasPreview: hasPreview,
                width: width,
                height: height,
                originalDateTime: originalDateTime,
                originalName: originalName,
                nbItems: nbItems.flatMap { Int($0) },
                dateRange: dateRange,
                location: location
            )
            files.append(file)
            inResponse = false
        } else if elementName == "propstat" {
            inPropStat = false
        }

        guard inResponse else { return }

        switch elementName {
        case "href":
            href = text
        case "displayname":
            if !text.isEmpty { displayName = text }
        case "getcontenttype":
            if !text.isEmpty { contentType = text }
        case "getcontentlength":
            contentLength = Int64(text)
        case "getlastmodified":
            if !text.isEmpty { lastModified = text }
        case "fileid":
            if !text.isEmpty { fileId = text }
        case "permissions":
            if !text.isEmpty { permissions = text }
        case "has-preview":
            hasPreview = text.lowercased() == "true" || text == "1"
        case "metadata-photos-size":
            if !text.isEmpty { photosSize = text }
        case "metadata-photos-original_date_time":
            if !text.isEmpty { originalDateTime = text }
        case "original-name":
            if !text.isEmpty { originalName = text }
        case "nbItems":
            if !text.isEmpty { nbItems = text }
        case "dateRange":
            if !text.isEmpty { dateRange = text }
        case "location":
            if !text.isEmpty { location = text }
        default:
            break
        }
    }

    private func resetCurrentFile() {
        href = nil
        displayName = nil
        contentType = nil
        contentLength = nil
        lastModified = nil
        fileId = nil
        permissions = nil
        isCollection = false
        hasPreview = false
        photosSize = nil
        originalDateTime = nil
        originalName = nil
        nbItems = nil
        dateRange = nil
        location = nil
    }
}

// MARK: - Upload Progress Delegate

private final class NextcloudUploadDelegate: NSObject, URLSessionTaskDelegate {
    private let progressHandler: @Sendable (Double) -> Void

    init(progressHandler: @escaping @Sendable (Double) -> Void) {
        self.progressHandler = progressHandler
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        let progress = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        progressHandler(min(progress, 0.99))
    }
}
