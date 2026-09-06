#!/usr/bin/env python3
import asyncio
import base64
import hashlib
import os
import struct
import sys

LISTEN_HOST = os.environ.get("LISTEN_HOST", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "2082"))
SSH_HOST = os.environ.get("SSH_HOST", "127.0.0.1")
SSH_PORT = int(os.environ.get("SSH_PORT", "2222"))
GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
MAX_HEADER = 16384


def ws_accept(key: str) -> str:
    digest = hashlib.sha1(key.encode("utf-8") + GUID).digest()
    return base64.b64encode(digest).decode("ascii")


def encode_frame(payload: bytes, opcode: int = 0x2) -> bytes:
    header = bytearray()
    header.append(0x80 | opcode)
    length = len(payload)
    if length < 126:
        header.append(length)
    elif length < 65536:
        header.append(126)
        header.extend(struct.pack("!H", length))
    else:
        header.append(127)
        header.extend(struct.pack("!Q", length))
    return bytes(header) + payload


async def read_frame(reader: asyncio.StreamReader):
    hdr = await reader.readexactly(2)
    opcode = hdr[0] & 0x0F
    masked = (hdr[1] & 0x80) != 0
    length = hdr[1] & 0x7F
    if length == 126:
        length = struct.unpack("!H", await reader.readexactly(2))[0]
    elif length == 127:
        length = struct.unpack("!Q", await reader.readexactly(8))[0]
    mask = await reader.readexactly(4) if masked else b""
    payload = await reader.readexactly(length) if length else b""
    if masked:
        payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    return opcode, payload


async def pipe_raw(reader, writer):
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except (asyncio.IncompleteReadError, ConnectionError, OSError):
        pass
    finally:
        try:
            writer.close()
            await writer.wait_closed()
        except Exception:
            pass


async def pipe_ws_to_tcp(ws_reader, tcp_writer):
    try:
        while True:
            opcode, payload = await read_frame(ws_reader)
            if opcode in (0x8,):
                break
            if opcode in (0x9,):
                continue
            if opcode in (0xA,):
                continue
            if payload:
                tcp_writer.write(payload)
                await tcp_writer.drain()
    except (asyncio.IncompleteReadError, ConnectionError, OSError):
        pass
    finally:
        try:
            tcp_writer.close()
            await tcp_writer.wait_closed()
        except Exception:
            pass


async def pipe_tcp_to_ws(tcp_reader, ws_writer):
    try:
        while True:
            data = await tcp_reader.read(65536)
            if not data:
                break
            ws_writer.write(encode_frame(data, 0x2))
            await ws_writer.drain()
    except (asyncio.IncompleteReadError, ConnectionError, OSError):
        pass
    finally:
        try:
            ws_writer.close()
            await ws_writer.wait_closed()
        except Exception:
            pass


def parse_headers(blob: bytes):
    text = blob.decode("iso-8859-1", errors="replace")
    lines = text.split("\r\n")
    request = lines[0] if lines else ""
    headers = {}
    for line in lines[1:]:
        if not line or ":" not in line:
            continue
        k, v = line.split(":", 1)
        headers[k.strip().lower()] = v.strip()
    return request, headers


async def open_ssh():
    return await asyncio.open_connection(SSH_HOST, SSH_PORT)


async def handle(reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
    leftover = b""
    try:
        buf = b""
        while b"\r\n\r\n" not in buf and len(buf) < MAX_HEADER:
            chunk = await asyncio.wait_for(reader.read(1024), timeout=20)
            if not chunk:
                break
            buf += chunk
        if b"\r\n\r\n" not in buf:
            writer.close()
            await writer.wait_closed()
            return
        header_blob, leftover = buf.split(b"\r\n\r\n", 1)
        request, headers = parse_headers(header_blob)
        ws_key = headers.get("sec-websocket-key")
        tcp_reader, tcp_writer = await open_ssh()
        if leftover:
            tcp_writer.write(leftover)
            await tcp_writer.drain()
        if request.upper().startswith("CONNECT"):
            writer.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            await writer.drain()
            await asyncio.gather(
                pipe_raw(reader, tcp_writer),
                pipe_raw(tcp_reader, writer),
            )
            return
        if ws_key:
            accept = ws_accept(ws_key)
            resp = (
                "HTTP/1.1 101 Switching Protocols\r\n"
                "Upgrade: websocket\r\n"
                "Connection: Upgrade\r\n"
                f"Sec-WebSocket-Accept: {accept}\r\n"
                "\r\n"
            )
            writer.write(resp.encode("ascii"))
            await writer.drain()
            await asyncio.gather(
                pipe_ws_to_tcp(reader, tcp_writer),
                pipe_tcp_to_ws(tcp_reader, writer),
            )
        else:
            resp = (
                "HTTP/1.1 101 Switching Protocols\r\n"
                "Upgrade: websocket\r\n"
                "Connection: Upgrade\r\n"
                "\r\n"
            )
            writer.write(resp.encode("ascii"))
            await writer.drain()
            await asyncio.gather(
                pipe_raw(reader, tcp_writer),
                pipe_raw(tcp_reader, writer),
            )
    except Exception:
        try:
            writer.close()
            await writer.wait_closed()
        except Exception:
            pass


async def main():
    server = await asyncio.start_server(handle, LISTEN_HOST, LISTEN_PORT)
    sockets = ", ".join(str(s.getsockname()) for s in server.sockets or [])
    print(f"raretriccks-ws listening {sockets} -> {SSH_HOST}:{SSH_PORT}", flush=True)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
