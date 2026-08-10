from __future__ import annotations

from pathlib import Path
import sys
import unittest


REPO_ROOT = Path(__file__).resolve().parents[3]
PROTOCOL_PATH = REPO_ROOT / "tools/maixcam-camera/y8_protocol.py"
sys.path.insert(0, str(PROTOCOL_PATH.parent))
import y8_protocol  # noqa: E402


class FragmentedReceiver:
    def __init__(self, data: bytes, chunk_size: int = 7) -> None:
        self.data = data
        self.chunk_size = chunk_size

    def recv(self, size: int) -> bytes:
        count = min(size, self.chunk_size, len(self.data))
        result = self.data[:count]
        self.data = self.data[count:]
        return result


def make_frame(
    payload: bytes = bytes(range(8)),
    *,
    magic: bytes = y8_protocol.MAGIC,
    version: int = y8_protocol.VERSION,
    header_size: int = y8_protocol.HEADER.size,
    width: int = 4,
    height: int = 2,
    stride: int = 4,
    pixel_format: int = y8_protocol.FORMAT_Y8,
    payload_length: int | None = None,
    reserved: int = 0,
) -> bytes:
    if payload_length is None:
        payload_length = len(payload)
    header = y8_protocol.HEADER.pack(
        magic,
        version,
        header_size,
        width,
        height,
        stride,
        pixel_format,
        42,
        123456789,
        payload_length,
        reserved,
    )
    return header + payload


class Y8ProtocolTests(unittest.TestCase):
    def test_header_is_fixed_40_bytes(self) -> None:
        self.assertEqual(y8_protocol.HEADER.size, 40)

    def test_fragmented_frame_read(self) -> None:
        payload = bytes(range(8))
        header, received = y8_protocol.read_frame(
            FragmentedReceiver(make_frame(payload), chunk_size=3)
        )
        self.assertEqual(received, payload)
        self.assertEqual((header.width, header.height, header.stride), (4, 2, 4))
        self.assertEqual((header.sequence, header.timestamp_ns), (42, 123456789))

    def test_truncated_payload_is_rejected(self) -> None:
        with self.assertRaises(EOFError):
            y8_protocol.read_frame(FragmentedReceiver(make_frame()[:-1]))

    def test_invalid_headers_are_rejected(self) -> None:
        invalid_frames = (
            make_frame(magic=b"BAD!"),
            make_frame(version=2),
            make_frame(header_size=36),
            make_frame(stride=5),
            make_frame(pixel_format=2),
            make_frame(payload_length=7),
            make_frame(reserved=1),
        )
        for frame in invalid_frames:
            with self.subTest(frame=frame[:40]), self.assertRaises(ValueError):
                y8_protocol.read_frame(FragmentedReceiver(frame))

    def test_sequence_gaps_do_not_accumulate_frames(self) -> None:
        self.assertEqual(y8_protocol.sequence_gap(None, 100), 0)
        self.assertEqual(y8_protocol.sequence_gap(100, 101), 0)
        self.assertEqual(y8_protocol.sequence_gap(101, 108), 6)
        self.assertEqual(y8_protocol.sequence_gap(108, 108), 0)


if __name__ == "__main__":
    unittest.main()
