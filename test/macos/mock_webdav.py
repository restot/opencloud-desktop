"""Loopback-only WebDAV fixture for disposable signed FileProvider tests."""
import base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Lock
from urllib.parse import unquote, urlsplit
from xml.sax.saxutils import escape
import hashlib
import json


class Fixture(ThreadingHTTPServer):
    def __init__(self):
        super().__init__(('127.0.0.1', 0), Handler)
        self.files = {}
        self.lock = Lock()
        self.unauthorized = 0
        self.requests = []
        self.identifiers = {}
        self.offline = set()

    def add_domain(self, identifier):
        self.files['/' + identifier + '/'] = None
        self.files['/' + identifier + '/hello.txt'] = ('hello ' + identifier).encode()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        if self.command in ("GET", "PUT", "DELETE", "PROPFIND", "MOVE", "MKCOL") and format.startswith('"%s"'):
            self.server.requests.append(f"{self.command} {self.path} {args[1]}")

    def path_and_auth(self):
        path = unquote(urlsplit(self.path).path)
        domain = path.strip('/').split('/')[0]
        expected = 'Basic ' + base64.b64encode(('review:test-' + domain).encode()).decode()
        if self.headers.get('Authorization') != expected:
            self.server.unauthorized += 1
            self.send_error(401)
            return None
        if domain in self.server.offline and self.command != 'POST':
            self.send_error(503)
            return None
        return path

    def etag(self, path):
        return '"' + hashlib.sha256(self.server.files[path] or b'directory').hexdigest() + '"'

    def send_data(self, status, data=b'', content_type='application/octet-stream'):
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        path = self.path_and_auth()
        if path is None:
            return
        domain = path.strip('/').split('/')[0]
        payload = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))))
        if payload['offline']:
            self.server.offline.add(domain)
        else:
            self.server.offline.discard(domain)
        self.send_data(200)

    def do_PROPFIND(self):
        path = self.path_and_auth()
        if path is None:
            return
        with self.server.lock:
            if path not in self.server.files and path + '/' in self.server.files:
                path += '/'
            if path not in self.server.files:
                self.send_error(404)
                return
            paths = [path]
            if self.headers.get('Depth') != '0' and path.endswith('/'):
                paths += [key for key in self.server.files if key != path and key.startswith(path)
                          and '/' not in key[len(path):].rstrip('/')]
            responses = []
            for key in paths:
                data = self.server.files[key]
                collection = '<d:collection/>' if data is None else ''
                identifier = self.server.identifiers.setdefault(key, hashlib.sha256(key.encode()).hexdigest())
                responses.append(f'<d:response><d:href>{escape(key)}</d:href><d:propstat><d:prop>'
                    f'<oc:id>{identifier}</oc:id><d:resourcetype>{collection}</d:resourcetype>'
                    f'<d:getetag>{escape(self.etag(key))}</d:getetag>'
                    f'<d:getcontentlength>{len(data or b"")}</d:getcontentlength>'
                    '<d:getlastmodified>Sat, 26 Sep 2026 12:00:00 GMT</d:getlastmodified>'
                    '<oc:permissions>RDNVW</oc:permissions></d:prop>'
                    '<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>')
            xml = '<d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">' + ''.join(responses) + '</d:multistatus>'
        self.send_data(207, xml.encode(), 'application/xml')

    def do_GET(self):
        path = self.path_and_auth()
        if path is None:
            return
        with self.server.lock:
            if path not in self.server.files:
                self.send_error(404)
                return
            if self.headers.get('If-Match') not in (None, self.etag(path)):
                self.send_error(412)
                return
            data = self.server.files[path]
        self.send_data(200, data or b'')

    def do_PUT(self):
        path = self.path_and_auth()
        if path is None:
            return
        data = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        with self.server.lock:
            exists = path in self.server.files
            if exists and self.headers.get('If-None-Match') == '*':
                self.send_error(412)
                return
            if self.headers.get('If-Match') and (not exists or self.headers['If-Match'] != self.etag(path)):
                self.send_error(412)
                return
            self.server.files[path] = data
        self.send_data(201)

    def do_DELETE(self):
        path = self.path_and_auth()
        if path is None:
            return
        with self.server.lock:
            if path not in self.server.files:
                self.send_error(404)
                return
            if self.headers.get('If-Match') not in (None, self.etag(path)):
                self.send_error(412)
                return
            del self.server.files[path]
        self.send_data(204)

    def do_MKCOL(self):
        path = self.path_and_auth()
        if path is None:
            return
        with self.server.lock:
            if path.rstrip('/') + '/' in self.server.files:
                self.send_error(405)
                return
            self.server.files[path.rstrip('/') + '/'] = None
        self.send_data(201)

    def do_MOVE(self):
        path = self.path_and_auth()
        if path is None:
            return
        destination = unquote(urlsplit(self.headers.get('Destination', '')).path)
        with self.server.lock:
            if path not in self.server.files:
                self.send_error(404)
                return
            if destination in self.server.files and self.headers.get('Overwrite') == 'F':
                self.send_error(412)
                return
            self.server.files[destination] = self.server.files.pop(path)
            if path in self.server.identifiers:
                self.server.identifiers[destination] = self.server.identifiers.pop(path)
        self.send_data(201)
