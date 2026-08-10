"""Interactive viewer for the MaixCAM uncompressed latest-frame Y8 stream."""

from __future__ import annotations

import argparse
import time

import cv2
import numpy as np

from y8_protocol import connect, read_frame, sequence_gap


WINDOW_TITLE = "MaixCAM Y8"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="10.42.0.1")
    parser.add_argument("--port", type=int, default=8555)
    parser.add_argument("--timeout", type=float, default=5.0)
    parser.add_argument("--hide-stats", action="store_true")
    args = parser.parse_args()

    cv2.namedWindow(WINDOW_TITLE, cv2.WINDOW_NORMAL)
    cv2.resizeWindow(WINDOW_TITLE, 640, 480)
    previous_arrival: float | None = None
    previous_sequence: int | None = None
    total_gaps = 0

    try:
        with connect(args.host, args.port, args.timeout) as connection:
            while True:
                header, payload = read_frame(connection)
                now = time.perf_counter()
                image = np.frombuffer(payload, dtype=np.uint8).reshape(
                    header.height, header.width
                ).copy()
                total_gaps += sequence_gap(previous_sequence, header.sequence)

                if not args.hide_stats:
                    fps = 0.0
                    if previous_arrival is not None:
                        fps = 1.0 / max(now - previous_arrival, 1e-6)
                    cv2.putText(
                        image,
                        f"{fps:4.1f} FPS  gaps {total_gaps}",
                        (16, 32),
                        cv2.FONT_HERSHEY_SIMPLEX,
                        0.7,
                        255,
                        2,
                        cv2.LINE_AA,
                    )

                cv2.imshow(WINDOW_TITLE, image)
                previous_arrival = now
                previous_sequence = header.sequence
                key = cv2.waitKey(1) & 0xFF
                if key in (27, ord("q")):
                    break
                if cv2.getWindowProperty(WINDOW_TITLE, cv2.WND_PROP_VISIBLE) < 1:
                    break
    finally:
        cv2.destroyAllWindows()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
