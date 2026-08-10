"""Wire protocol for the MaixCAM latest-frame Y8 preview."""

from __future__ import annotations

from dataclasses import dataclass
import socket
import struct
from typing import Protocol


MAGIC = b"Y8P0"
VERSION = 1
FORMAT_Y8 = 1
HEADER = struct.Struct("!4sHHHHHHQQII")


class Receiver(Protocol):
    def recv(self, size: int) -> bytes: ...


@dataclass(frozen=True)
class FrameHeader:
    width: int
    height: int
    stride: int
    sequence: int
    timestamp_ns: int
    payload_length: int


def recv_exact(receiver: Receiver, size: int) -> bytes:
    chunks: list[bytes] = []
    remaining = size
    while remaining:
        chunk = receiver.recv(remaining)
        if not chunk:
            raise EOFError(f"stream ended with {remaining} bytes missing")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def read_frame(receiver: Receiver) -> tuple[FrameHeader, bytes]:
    raw_header = recv_exact(receiver, HEADER.size)
    (
        magic,
        version,
        header_size,
        width,
        height,
        stride,
        pixel_format,
        sequence,
        timestamp_ns,
        payload_length,
        reserved,
    ) = HEADER.unpack(raw_header)

    if magic != MAGIC:
        raise ValueError(f"invalid Y8 magic: {magic!r}")
    if version != VERSION or header_size != HEADER.size:
        raise ValueError(
            f"unsupported Y8 protocol version/header: {version}/{header_size}"
        )
    if pixel_format != FORMAT_Y8 or reserved != 0:
        raise ValueError(f"unsupported Y8 format/reserved: {pixel_format}/{reserved}")
    if width < 1 or height < 1 or stride != width:
        raise ValueError(f"invalid Y8 dimensions: {width}x{height} stride={stride}")
    if payload_length != width * height:
        raise ValueError(
            f"invalid Y8 payload length: {payload_length} for {width}x{height}"
        )

    payload = recv_exact(receiver, payload_length)
    return (
        FrameHeader(
            width=width,
            height=height,
            stride=stride,
            sequence=sequence,
            timestamp_ns=timestamp_ns,
            payload_length=payload_length,
        ),
        payload,
    )


def sequence_gap(previous: int | None, current: int) -> int:
    if previous is None or current <= previous:
        return 0
    return max(current - previous - 1, 0)


def connect(host: str, port: int, timeout: float = 5.0) -> socket.socket:
    connection = socket.create_connection((host, port), timeout=timeout)
    connection.settimeout(timeout)
    return connection
