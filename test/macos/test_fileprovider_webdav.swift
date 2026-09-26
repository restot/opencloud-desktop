import Foundation
import FileProvider

private final class MockDAVProtocol: URLProtocol {
    static var requests: [URLRequest] = []
    static var handler: ((URLRequest) -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let (status, data) = Self.handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct WebDAVRegressionTests {
    static func response(_ href: String, etag: String = "&quot;version-1&quot;", extra: String = "") -> String {
        """
        <d:response><d:href>\(href)</d:href><d:propstat><d:prop>
        <d:getetag>\(etag)</d:getetag><d:getcontentlength>0</d:getcontentlength>
        </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>\(extra)</d:response>
        """
    }
    static func document(_ responses: String) -> Data {
        Data("<d:multistatus xmlns:d=\"DAV:\" xmlns:oc=\"http://owncloud.org/ns\">\(responses)</d:multistatus>".utf8)
    }
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }
    static func main() async throws {
        let base = URL(string: "https://example.test/remote.php/webdav/")!
        let parser = WebDAVXMLParser(baseURL: base)
        let failedProperties = """
        <d:propstat><d:prop><d:getetag>incorrect</d:getetag><d:resourcetype><d:collection/></d:resourcetype></d:prop>
        <d:status>HTTP/1.1 404 Not Found</d:status></d:propstat>
        """
        let items = parser.parse(data: document(response("/remote.php/webdav/literal%2520name.txt", extra: failedProperties)))!
        check(items.count == 1, "parse one resource")
        check(items[0].filename == "literal%20name.txt", "decode literal percent filenames only once")
        check(items[0].etag == "\"version-1\"", "preserve HTTP entity-tag quotes")
        check(!items[0].isDirectory, "ignore properties from failed propstat")
        let absolute = parser.parse(data: document(response("https://example.test/remote.php/webdav/literal%252Fname.txt")))!
        check(absolute[0].filename == "literal%2Fname.txt", "absolute href percent decoding")
        check(parser.parse(data: Data("<html/>".utf8)) == nil, "reject non-WebDAV responses")
        let failedItem = "<d:response><d:href>/remote.php/webdav/missing</d:href><d:status>HTTP/1.1 404 Not Found</d:status></d:response>"
        check(parser.parse(data: document(response("/remote.php/webdav/") + failedItem)) == nil,
              "partial listing must not be treated as server deletions")

        let fileMetadata = ItemMetadata(from: items[0], parentOcId: "parent")
        let fileItem = FileProviderItem(metadata: fileMetadata, parentItemIdentifier: NSFileProviderItemIdentifier("parent"))
        check(fileItem.documentSize?.int64Value == 0, "zero-byte files have a known document size")
        let movedItem = FileProviderItem(metadata: fileMetadata, parentItemIdentifier: NSFileProviderItemIdentifier("other-parent"))
        check(fileItem.itemVersion.contentVersion == movedItem.itemVersion.contentVersion, "moving preserves content version")
        check(fileItem.itemVersion.metadataVersion != movedItem.itemVersion.metadataVersion, "moving changes metadata version")
        check(fileItem.itemVersion.metadataVersion.count <= 128, "metadata versions fit the FileProvider size limit")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockDAVProtocol.self]
        let client = WebDAVClient(serverURL: URL(string: "https://example.test")!, username: "user", password: "test", sessionConfiguration: config)
        let rootMatches = await client.isRootPath("/remote.php/webdav/")
        let nestedMatches = await client.isRootPath("/remote.php/webdav/nested")
        check(rootMatches && !nestedMatches, "only DAV root may be assigned root-container identity")
        MockDAVProtocol.handler = { _ in
            (207, document(response("/remote.php/webdav/child.txt") + response("/remote.php/webdav/")))
        }
        let listing = try await client.listDirectory(path: "/")
        check(listing.first?.remotePath == "/remote.php/webdav/", "resource itself need not be first on the wire")
        MockDAVProtocol.handler = { _ in (207, document(response("/remote.php/webdav/child.txt"))) }
        do {
            _ = try await client.listDirectory(path: "/")
            preconditionFailure("missing directory response must fail")
        } catch WebDAVError.parseError { }

        let upload = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("local edit".utf8).write(to: upload)
        defer { try? FileManager.default.removeItem(at: upload) }
        MockDAVProtocol.requests = []
        MockDAVProtocol.handler = { _ in (412, Data()) }
        do {
            _ = try await client.uploadFile(from: upload, to: "/file.txt", ifMatchEtag: "old-version")
            preconditionFailure("conflicting edit must fail")
        } catch WebDAVError.conflict { }
        check(MockDAVProtocol.requests.count == 1, "never retry a conflicting upload unconditionally")
        check(MockDAVProtocol.requests[0].value(forHTTPHeaderField: "If-Match") == "\"old-version\"", "quote legacy cached ETags")
        do {
            _ = try await client.uploadFile(from: upload, to: "/file.txt", ifNoneMatch: true)
            preconditionFailure("creation collision must fail")
        } catch WebDAVError.conflict { }
        check(MockDAVProtocol.requests.last?.value(forHTTPHeaderField: "If-None-Match") == "*", "new files cannot overwrite a remote collision")
        MockDAVProtocol.requests = []
        do {
            try await client.deleteItem(at: "/file.txt", ifMatchEtag: "old-version")
            preconditionFailure("conflicting delete must fail")
        } catch WebDAVError.conflict { }
        check(MockDAVProtocol.requests.count == 1, "a rejected deletion must not retry")
        check(MockDAVProtocol.requests[0].value(forHTTPHeaderField: "If-Match") == "\"old-version\"", "deletion checks the version on disk")
        let movedResponse = document(response("/remote.php/webdav/renamed.txt", extra:
            "<d:propstat><d:prop><oc:id>stable-server-id</oc:id></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>"))
        MockDAVProtocol.requests = []
        MockDAVProtocol.handler = { request in
            if request.httpMethod == "MOVE" { return (201, Data()) }
            let reads = MockDAVProtocol.requests.filter { $0.httpMethod == "PROPFIND" }.count
            return reads == 1 ? (503, Data()) : (207, movedResponse)
        }
        let moved = try await client.moveItem(from: "/source.txt", to: "/renamed.txt", expectedIdentifier: "stable-server-id")
        check(moved?.ocId == "stable-server-id", "recover metadata after a successful MOVE")
        check(MockDAVProtocol.requests.filter { $0.httpMethod == "MOVE" }.count == 1,
              "metadata retry must not issue another MOVE")
        check(MockDAVProtocol.requests.filter { $0.httpMethod == "PROPFIND" }.count == 2,
              "retry the failed metadata read")

        MockDAVProtocol.handler = { request in
            request.httpMethod == "MOVE" ? (404, Data()) : (207, movedResponse)
        }
        let recovered = try await client.moveItem(from: "/source.txt", to: "/renamed.txt", expectedIdentifier: "stable-server-id")
        check(recovered?.ocId == "stable-server-id", "retry after lost MOVE response identifies destination safely")
        do {
            _ = try await client.moveItem(from: "/source.txt", to: "/renamed.txt", expectedIdentifier: "different-server-id")
            preconditionFailure("unrelated destination must not count as a completed MOVE")
        } catch WebDAVError.conflict { }
        do {
            let fallback = WebDAVItem.generateIdentifier(from: "/remote.php/webdav/source.txt")
            _ = try await client.moveItem(from: "/source.txt", to: "/renamed.txt", expectedIdentifier: fallback)
            preconditionFailure("path-derived identity cannot prove prior MOVE success")
        } catch WebDAVError.fileNotFound { }
        print("FileProvider WebDAV regression tests passed")
    }
}
