"""Measure the MaixCAM low-delay RTSP stream without displaying frames."""

from __future__ import annotations

import argparse
import json
import time

import av

from viewer import FORMAT_OPTIONS, configure_decoder


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default="rtsp://10.42.0.1:8554/live")
    parser.add_argument("--frames", type=int, default=120)
    args = parser.parse_args()
    if args.frames < 2:
        parser.error("--frames must be at least 2")

    arrivals: list[int] = []
    width = 0
    height = 0
    with av.open(
        args.url,
        mode="r",
        options=FORMAT_OPTIONS,
        timeout=(7.0, 3.0),
    ) as container:
        stream = container.streams.video[0]
        configure_decoder(stream)
        for frame in container.decode(stream):
            arrivals.append(time.perf_counter_ns())
            width, height = frame.width, frame.height
            if len(arrivals) == args.frames:
                break

    elapsed_s = (arrivals[-1] - arrivals[0]) / 1_000_000_000
    print(
        json.dumps(
            {
                "width": width,
                "height": height,
                "frames": len(arrivals),
                "arrival_fps": (len(arrivals) - 1) / elapsed_s,
            },
            indent=2,
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
