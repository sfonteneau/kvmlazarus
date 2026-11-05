#!/usr/bin/env python3
"""Small bounded RFC6455 client for MeshKVM test/measurement tools, not the GUI."""
from __future__ import annotations
import base64
import hashlib
import os
import socket
import ssl
import struct
import time

PROTOCOL = 'meshkvm7'
MAX_MESSAGE = 4 * 1024 * 1024

class Closed(ConnectionError):
    pass

def frame(opcode: int, payload: bytes) -> bytes:
    if len(payload) > MAX_MESSAGE or opcode not in (1, 2, 8, 9, 10):
        raise ValueError('Invalid outgoing WebSocket message')
    mask = os.urandom(4)
    size = len(payload)
    head = bytes((0x80 | opcode, 0x80 | min(size, 126)))
    if size >= 65536:
        head = bytes((0x80 | opcode, 0xff)) + struct.pack('!Q', size)
    elif size >= 126:
        head += struct.pack('!H', size)
    return head + mask + bytes(c ^ mask[i & 3] for i, c in enumerate(payload))

class WS:
    def __init__(self, host='127.0.0.1', port=7900, *, tls=False, ca=None,
                 server_name=None, allow_insecure=False, timeout=4.0):
        if not 1 <= port <= 65535 or not host or any(c in host for c in '\r\n /'):
            raise ValueError('Invalid endpoint')
        if not tls and host not in ('127.0.0.1', '::1') and not allow_insecure:
            raise ValueError('TLS required remotely; --allow-insecure only for a trusted tunnel/VPN')
        self.sock = socket.create_connection((host, port), timeout)
        self.buffer = bytearray()
        self.wire_bytes = 0
        try:
            if tls:
                ctx = ssl.create_default_context(cafile=ca)
                ctx.minimum_version = ssl.TLSVersion.TLSv1_2
                self.sock = ctx.wrap_socket(self.sock, server_hostname=server_name or host)
            key = base64.b64encode(os.urandom(16)).decode('ascii')
            host_header = f'[{host}]' if ':' in host else host
            request = (f'GET /kvm HTTP/1.1\r\nHost: {host_header}:{port}\r\n'
                       'Upgrade: websocket\r\nConnection: Upgrade\r\n'
                       f'Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n'
                       f'Sec-WebSocket-Protocol: {PROTOCOL}\r\n\r\n')
            self.sock.sendall(request.encode('ascii'))
            while b'\r\n\r\n' not in self.buffer:
                chunk = self.sock.recv(4096)
                if not chunk: raise Closed('Connection closed during upgrade')
                self.buffer.extend(chunk)
                if len(self.buffer) > 16384: raise ValueError('HTTP upgrade headers too large')
            header, remainder = self.buffer.split(b'\r\n\r\n', 1)
            self.buffer = bytearray(remainder)
            lines = header.decode('iso-8859-1').split('\r\n')
            if len(lines[0].split()) < 2 or lines[0].split()[1] != '101':
                raise ConnectionError('Upgrade rejected: ' + lines[0])
            fields = {}
            for line in lines[1:]:
                name, value = line.split(':', 1)
                name = name.strip().lower()
                if name in fields: raise ValueError('Duplicate handshake header')
                fields[name] = value.strip()
            accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
            if fields.get('sec-websocket-accept') != accept or fields.get('sec-websocket-protocol') != PROTOCOL:
                raise ValueError('Incorrect WebSocket accept or subprotocol')
            if fields.get('upgrade', '').lower() != 'websocket' or 'upgrade' not in fields.get('connection', '').lower():
                raise ValueError('Missing upgrade headers')
            if fields.get('sec-websocket-extensions'): raise ValueError('Unrequested compression')
        except BaseException:
            self.close()
            raise

    def close(self):
        if getattr(self, 'sock', None) is not None:
            self.sock.close()
            self.sock = None

    def __enter__(self): return self
    def __exit__(self, *args): self.close()

    def send(self, payload: bytes, *, text=False):
        self.sock.sendall(frame(1 if text else 2, payload))

    def _exact(self, n, deadline):
        while len(self.buffer) < n:
            remaining = deadline - time.monotonic()
            if remaining <= 0: raise TimeoutError('Receive deadline reached')
            self.sock.settimeout(remaining)
            chunk = self.sock.recv(min(65536, n - len(self.buffer)))
            if not chunk: raise Closed('Peer closed connection')
            self.wire_bytes += len(chunk)
            self.buffer.extend(chunk)
        result = bytes(self.buffer[:n]); del self.buffer[:n]
        self._consumed.extend(result)
        if len(self._consumed)>MAX_MESSAGE+65536: raise ValueError('Too many frame headers/control messages')
        return result

    def receive(self, timeout=4.0):
        # Retry after a slow/partial frame without discarding consumed headers.
        self._consumed=bytearray()
        try: return self._receive(timeout)
        except TimeoutError:
            self.buffer=self._consumed+self.buffer
            raise
        finally: self._consumed=bytearray()

    def _receive(self, timeout=4.0):
        deadline = time.monotonic() + timeout
        joined = bytearray(); kind = None
        while True:
            a, b = self._exact(2, deadline)
            if a & 0x70 or b & 0x80: raise ValueError('Unexpected extension or masked server frame')
            final, op = bool(a & 0x80), a & 15
            n = b & 127
            if n == 126: n = struct.unpack('!H', self._exact(2, deadline))[0]
            elif n == 127: n = struct.unpack('!Q', self._exact(8, deadline))[0]
            if n > MAX_MESSAGE or len(joined) + n > MAX_MESSAGE: raise ValueError('Oversized message')
            if op >= 8 and (not final or n > 125): raise ValueError('Malformed control frame')
            payload = self._exact(n, deadline)
            if op == 8: raise Closed('WebSocket close')
            if op == 9:
                self.sock.sendall(frame(10, payload)); continue
            if op == 10: continue
            if op not in (0, 1, 2): raise ValueError('Invalid opcode')
            if op == 0 and kind is None: raise ValueError('Unexpected continuation')
            if op != 0:
                if kind is not None: raise ValueError('Interleaved data message')
                kind = op
            joined.extend(payload)
            if final: return kind, bytes(joined)

    def auth(self, token: str, capability='jpeg'):
        if not 16 <= len(token) <= 256 or any(not 33 <= ord(c) <= 126 for c in token):
            raise ValueError('Invalid token format')
        if capability not in ('jpeg', 'h264'): raise ValueError('Unknown capability')
        self.send(f'AUTH {token} {capability}'.encode('ascii'), text=True)
        op, payload = self.receive()
        if op != 1 or payload not in (b'OK CTRL', b'OK VIEW'):
            raise PermissionError('Authentication did not return an OK role')
        return payload

    def next_matching(self, predicate, timeout=5.0):
        """Drain video with receipt-only ACKs; this is NOT a GUI decode test."""
        deadline = time.monotonic() + timeout
        while True:
            op, payload = self.receive(max(.001, deadline - time.monotonic()))
            if predicate(op, payload): return op, payload
            if op == 2 and len(payload) == 5 and payload[:1] == b'B':
                self.send(b'A' + payload[1:])
            if time.monotonic() >= deadline: raise TimeoutError('Expected message not received')

def endpoint_args(parser):
    parser.add_argument('--host', default='127.0.0.1')
    parser.add_argument('--port', type=int, default=7900)
    parser.add_argument('--tls', action='store_true')
    parser.add_argument('--ca')
    parser.add_argument('--server-name')
    parser.add_argument('--allow-insecure', action='store_true')

def connection_args(args):
    return dict(host=args.host, port=args.port, tls=args.tls, ca=args.ca,
                server_name=args.server_name, allow_insecure=args.allow_insecure)
