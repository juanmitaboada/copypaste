#!/usr/bin/env python3
"""Test stub only: minimal FastCGI responder that echoes selected params.

Lets tests/nginx_test.sh verify the nginx routing (which URL reaches PHP, with
which CP_* params and SCRIPT_FILENAME) without php-fpm. Not deployed.
"""

from __future__ import annotations

import os
import socket
import socketserver
import struct
import sys

FCGI_BEGIN_REQUEST = 1
FCGI_END_REQUEST = 3
FCGI_PARAMS = 4
FCGI_STDIN = 5
FCGI_STDOUT = 6
ECHOED = ("CP_ROUTE", "CP_ZONE", "CP_CODE", "SCRIPT_FILENAME", "REMOTE_USER", "HTTPS", "SERVER_NAME")


def read_exact(sock: socket.socket, n: int) -> bytes:
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("short read")
        buf += chunk
    return buf


def parse_params(data: bytes) -> dict[str, str]:
    params: dict[str, str] = {}
    i = 0

    def length() -> int:
        nonlocal i
        if data[i] >> 7:
            (value,) = struct.unpack(">I", data[i:i + 4])
            i += 4
            return value & 0x7FFFFFFF
        value = data[i]
        i += 1
        return value

    while i < len(data):
        nlen = length()
        vlen = length()
        name = data[i:i + nlen].decode()
        i += nlen
        params[name] = data[i:i + vlen].decode()
        i += vlen
    return params


def record(rtype: int, req_id: int, content: bytes) -> bytes:
    return struct.pack(">BBHHBB", 1, rtype, req_id, len(content), 0, 0) + content


class Handler(socketserver.BaseRequestHandler):
    def handle(self) -> None:
        sock: socket.socket = self.request
        params_raw = b""
        req_id = 0
        while True:
            _, rtype, req_id, clen, plen, _ = struct.unpack(">BBHHBB", read_exact(sock, 8))
            content = read_exact(sock, clen)
            read_exact(sock, plen)
            if rtype == FCGI_PARAMS:
                params_raw += content
            elif rtype == FCGI_STDIN and clen == 0:
                break
        params = parse_params(params_raw)
        body = "".join(f"{k}={params.get(k, '')}\n" for k in ECHOED).encode()
        out = b"Status: 200 OK\r\nContent-Type: text/plain\r\n\r\n" + body
        sock.sendall(record(FCGI_STDOUT, req_id, out) + record(FCGI_STDOUT, req_id, b"")
                     + record(FCGI_END_REQUEST, req_id, struct.pack(">IB3x", 0, 0)))


def main() -> None:
    path = sys.argv[1]
    if os.path.exists(path):
        os.unlink(path)
    with socketserver.ThreadingUnixStreamServer(path, Handler) as server:
        os.chmod(path, 0o666)
        server.serve_forever()


if __name__ == "__main__":
    main()
