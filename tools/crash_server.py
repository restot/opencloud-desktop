#!/usr/bin/env python3
"""
Simple crash report receiver for OpenCloud Desktop development.
Receives multipart/form-data crash reports and stores them locally.

Usage:
    python3 crash_server.py [port]

Default port: 8080
Reports saved to: ./crash_reports/
"""

import os
import sys
import json
from datetime import datetime
from http.server import HTTPServer, BaseHTTPRequestHandler
from email.parser import BytesParser
from email.policy import default
import uuid

REPORTS_DIR = os.path.join(os.path.dirname(__file__), "crash_reports")


class CrashReportHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        try:
            content_type = self.headers.get("Content-Type", "")
            content_length = int(self.headers.get("Content-Length", 0))

            if "multipart/form-data" in content_type:
                # Parse multipart form data using email parser
                body = self.rfile.read(content_length)
                
                # Construct headers for email parser
                headers_bytes = f"Content-Type: {content_type}\r\n\r\n".encode()
                message = BytesParser(policy=default).parsebytes(headers_bytes + body)

                # Create report directory
                os.makedirs(REPORTS_DIR, exist_ok=True)
                report_id = f"{datetime.now().strftime('%Y%m%d_%H%M%S')}_{uuid.uuid4().hex[:8]}"
                report_dir = os.path.join(REPORTS_DIR, report_id)
                os.makedirs(report_dir, exist_ok=True)

                metadata = {}

                for part in message.walk():
                    if part.is_multipart():
                        continue
                    
                    content_disposition = part.get("Content-Disposition", "")
                    if not content_disposition:
                        continue
                    
                    # Parse field name and filename
                    name = None
                    filename = None
                    for param in content_disposition.split(";"):
                        param = param.strip()
                        if param.startswith("name="):
                            name = param[5:].strip('"')
                        elif param.startswith("filename="):
                            filename = param[9:].strip('"')
                    
                    if not name:
                        continue
                    
                    if filename:
                        # It's a file (like the .dmp minidump)
                        filepath = os.path.join(report_dir, filename)
                        with open(filepath, "wb") as f:
                            f.write(part.get_payload(decode=True))
                        metadata[name] = {"type": "file", "filename": filename}
                        print(f"  Saved file: {filename}")
                    else:
                        # It's a form field
                        value = part.get_payload(decode=True).decode('utf-8')
                        metadata[name] = value
                        print(f"  {name}: {value}")

                # Save metadata
                with open(os.path.join(report_dir, "metadata.json"), "w") as f:
                    json.dump(metadata, f, indent=2)

                print(f"\n✓ Crash report saved: {report_id}\n")

                # Send success response
                self.send_response(200)
                self.send_header("Content-Type", "text/plain")
                self.end_headers()
                self.wfile.write(f"CrashID={report_id}\n".encode())

            else:
                # Handle non-multipart POST (raw body)
                body = self.rfile.read(content_length)
                os.makedirs(REPORTS_DIR, exist_ok=True)
                report_id = f"{datetime.now().strftime('%Y%m%d_%H%M%S')}_{uuid.uuid4().hex[:8]}"
                filepath = os.path.join(REPORTS_DIR, f"{report_id}.bin")
                with open(filepath, "wb") as f:
                    f.write(body)

                print(f"\n✓ Raw crash data saved: {report_id}\n")

                self.send_response(200)
                self.send_header("Content-Type", "text/plain")
                self.end_headers()
                self.wfile.write(f"CrashID={report_id}\n".encode())

        except Exception as e:
            print(f"\n✗ Error processing crash report: {e}\n")
            self.send_response(500)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(f"Error: {e}\n".encode())

    def do_GET(self):
        """Health check endpoint"""
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"OpenCloud Crash Report Server\n")

    def log_message(self, format, *args):
        print(f"[{datetime.now().strftime('%H:%M:%S')}] {format % args}")


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080

    os.makedirs(REPORTS_DIR, exist_ok=True)

    server = HTTPServer(("0.0.0.0", port), CrashReportHandler)
    print(f"🚀 Crash report server running on http://localhost:{port}")
    print(f"📁 Reports will be saved to: {REPORTS_DIR}")
    print(f"\nUse this URL for CRASHREPORTER_SUBMIT_URL: http://localhost:{port}/submit\n")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n\nShutting down...")
        server.shutdown()


if __name__ == "__main__":
    main()
