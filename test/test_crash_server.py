import importlib.util
import http.client
from pathlib import Path
import tempfile
import threading
import unittest
from unittest import mock


spec = importlib.util.spec_from_file_location(
    "crash_server", Path(__file__).resolve().parents[1] / "tools/crash_server.py"
)
crash_server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(crash_server)


class CrashServerTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.reports = self.directory / "reports"
        patcher = mock.patch.object(crash_server, "REPORTS_DIR", str(self.reports))
        patcher.start()
        self.addCleanup(patcher.stop)
        self.server = crash_server.HTTPServer(("127.0.0.1", 0), crash_server.CrashReportHandler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.stop_server)

    def stop_server(self):
        self.server.shutdown()
        self.thread.join()
        self.server.server_close()

    def upload(self, filename):
        filename = filename.replace("\\", "\\\\").replace('"', '\\"')
        body = (
            '--boundary\r\n'
            f'Content-Disposition: form-data; name="upload_file_minidump"; filename="{filename}"\r\n'
            'Content-Type: application/octet-stream\r\n\r\n'
            'report contents\r\n--boundary--\r\n'
        ).encode()
        connection = http.client.HTTPConnection(*self.server.server_address)
        try:
            connection.request("POST", "/submit", body=body, headers={
                "Content-Type": "multipart/form-data; boundary=boundary"
            })
            response = connection.getresponse()
            response.read()
            return response.status
        finally:
            connection.close()

    def test_attachment_stays_inside_report(self):
        self.assertEqual(self.upload("crash.dmp"), 200)
        saved = list(self.reports.glob("*/crash.dmp"))
        self.assertEqual(len(saved), 1)
        self.assertEqual(saved[0].read_text(), "report contents")

    def test_rejects_traversal_and_absolute_attachment_names(self):
        victim = self.directory / "existing.txt"
        victim.write_text("preserved")
        for filename in [str(victim), "../../existing.txt", r"..\existing.txt", ".."]:
            with self.subTest(filename=filename):
                self.assertEqual(self.upload(filename), 400)
                self.assertEqual(victim.read_text(), "preserved")

    def test_default_listener_is_loopback(self):
        with mock.patch("sys.argv", ["crash_server.py"]), \
                mock.patch.object(crash_server, "HTTPServer") as constructor:
            crash_server.main()
            self.assertEqual(constructor.call_args.args[0], ("127.0.0.1", 8080))


if __name__ == "__main__":
    unittest.main()
