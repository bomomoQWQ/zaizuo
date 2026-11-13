"""Loopback-only TLS smart-Git test oracle, never a production service.

Runs system Git only on the test-server side. The native client must not spawn
Git. Credentials are disposable fixture values read from environment, not argv.
"""
import argparse
import base64
import hmac
import json
import os
import ssl
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--root', required=True)
parser.add_argument('--cert', required=True)
parser.add_argument('--key', required=True)
parser.add_argument('--git', required=True)
args = parser.parse_args()
root = Path(args.root).resolve(strict=True)
expected = 'Basic ' + base64.b64encode(
    (os.environ['ZAIZUO_FIXTURE_USER'] + ':' + os.environ['ZAIZUO_FIXTURE_TOKEN']).encode()
).decode('ascii')

class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass

    def do_GET(self):
        self.handle_git()

    def do_POST(self):
        self.handle_git()

    def handle_git(self):
        # Deliberately no URL, body, header, or credential logging.
        if self.path == '/redirect.git/info/refs?service=git-upload-pack':
            self.send_response(302)
            self.send_header('Location', 'https://127.0.0.1:1/forbidden.git/info/refs')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        if self.path.split('?', 1)[0] not in (
            '/remote.git/info/refs', '/remote.git/git-upload-pack',
            '/remote.git/git-receive-pack',
        ):
            self.send_error(404)
            return
        if not hmac.compare_digest(self.headers.get('Authorization', ''), expected):
            self.send_response(401)
            self.send_header('WWW-Authenticate', 'Basic realm="zaizuo-fixture"')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        try:
            size = int(self.headers.get('Content-Length', '0'))
            if size < 0 or size > 32 * 1024 * 1024:
                self.send_error(413)
                return
            transfer = self.headers.get('Transfer-Encoding')
            if transfer:
                if transfer.lower() != 'chunked' or self.headers.get('Content-Length'):
                    self.send_error(400)
                    return
                chunks = []
                size = 0
                while True:
                    line = self.rfile.readline(128)
                    if not line.endswith(b'\r\n') or b';' in line:
                        raise ValueError('invalid chunk frame')
                    amount = int(line.strip(), 16)
                    if amount < 0 or size + amount > 32 * 1024 * 1024:
                        self.send_error(413)
                        return
                    if amount == 0:
                        if self.rfile.read(2) != b'\r\n':
                            raise ValueError('trailers not supported')
                        break
                    chunk = self.rfile.read(amount)
                    if len(chunk) != amount or self.rfile.read(2) != b'\r\n':
                        raise ValueError('truncated chunk')
                    chunks.append(chunk)
                    size += amount
                body = b''.join(chunks)
            else:
                body = self.rfile.read(size)
                if len(body) != size:
                    self.send_error(400)
                    return
            path, _, query = self.path.partition('?')
            env = {k: v for k, v in os.environ.items()
                   if not k.upper().startswith(('GIT_', 'GCM_', 'ZAIZUO_FIXTURE_'))}
            env.update({
                'GIT_PROJECT_ROOT': str(root), 'GIT_HTTP_EXPORT_ALL': '1',
                'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': os.devnull,
                'GIT_CONFIG_SYSTEM': os.devnull, 'REQUEST_METHOD': self.command,
                'PATH_INFO': path, 'QUERY_STRING': query,
                'CONTENT_TYPE': self.headers.get('Content-Type', ''),
                'CONTENT_LENGTH': str(size), 'REMOTE_USER': 'fixture-user',
                'REMOTE_ADDR': '127.0.0.1', 'SERVER_PROTOCOL': 'HTTP/1.1',
            })
            result = subprocess.run(
                [args.git, '-c', 'http.receivepack=true', 'http-backend'],
                input=body, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                env=env, timeout=60, check=False,
            )
            if result.returncode:
                self.send_error(502, 'Fixture Git backend failure')
                return
            header, separator, payload = result.stdout.partition(b'\r\n\r\n')
            if not separator:
                header, separator, payload = result.stdout.partition(b'\n\n')
            if not separator:
                self.send_error(502, 'Fixture Git response invalid')
                return
            fields = []
            status = 200
            for raw in header.decode('ascii').splitlines():
                name, value = raw.split(':', 1)
                if name.lower() == 'status':
                    status = int(value.strip().split()[0])
                elif name.lower() not in ('connection', 'transfer-encoding', 'content-length'):
                    fields.append((name, value.strip()))
            self.send_response(status)
            for name, value in fields:
                self.send_header(name, value)
            self.send_header('Content-Length', str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
        except (ValueError, OSError, subprocess.TimeoutExpired):
            self.send_error(502, 'Fixture request failed')

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.minimum_version = ssl.TLSVersion.TLSv1_2
context.load_cert_chain(args.cert, args.key)
server.socket = context.wrap_socket(server.socket, server_side=True)
print(json.dumps({'ready': True, 'port': server.server_port}), flush=True)
server.serve_forever()
