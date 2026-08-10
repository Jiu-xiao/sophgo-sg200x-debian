"""Measure the MaixCAM Y8 stream without displaying or queueing frames."""

from __future__ import annotations

import argparse
import json
import statistics
import time

from y8_protocol import connect, read_frame, sequence_gap


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    index = min(round((len(ordered) - 1) * fraction), len(ordered) - 1)
    return ordered[index]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="10.42.0.1")
    parser.add_argument("--port", type=int, default=8555)
    parser.add_argument("--frames", type=int, default=120)
    parser.add_argument("--timeout", type=float, default=5.0)
    args = parser.parse_args()
    if args.frames < 2:
        parser.error("--frames must be at least 2")

    arrivals: list[int] = []
    capture_times: list[int] = []
    total_bytes = 0
    total_gaps = 0
    previous_sequence: int | None = None
    dimensions: tuple[int, int, int] | None = None

    with connect(args.host, args.port, args.timeout) as connection:
        for _ in range(args.frames):
            header, payload = read_frame(connection)
            arrivals.append(time.perf_counter_ns())
            capture_times.append(header.timestamp_ns)
            total_bytes += len(payload)
            total_gaps += sequence_gap(previous_sequence, header.sequence)
            previous_sequence = header.sequence
            current_dimensions = (header.width, header.height, header.stride)
            if dimensions is None:
                dimensions = current_dimensions
            elif dimensions != current_dimensions:
                raise ValueError(
                    f"dimensions changed from {dimensions} to {current_dimensions}"
                )

    arrival_intervals = [
        (later - earlier) / 1_000_000
        for earlier, later in zip(arrivals, arrivals[1:])
    ]
    capture_intervals = [
        (later - earlier) / 1_000_000
        for earlier, later in zip(capture_times, capture_times[1:])
    ]
    elapsed_s = (arrivals[-1] - arrivals[0]) / 1_000_000_000
    result = {
        "width": dimensions[0] if dimensions else 0,
        "height": dimensions[1] if dimensions else 0,
        "stride": dimensions[2] if dimensions else 0,
        "frames": args.frames,
        "payload_bytes_per_frame": total_bytes // args.frames,
        "arrival_fps": (args.frames - 1) / elapsed_s,
        "payload_mbytes_per_s": (
            total_bytes * (args.frames - 1) / args.frames / elapsed_s / 1_000_000
        ),
        "sequence_gaps": total_gaps,
        "arrival_interval_ms_mean": statistics.mean(arrival_intervals),
        "arrival_interval_ms_p50": percentile(arrival_intervals, 0.50),
        "arrival_interval_ms_p95": percentile(arrival_intervals, 0.95),
        "capture_interval_ms_mean": statistics.mean(capture_intervals),
        "capture_interval_ms_p50": percentile(capture_intervals, 0.50),
        "capture_interval_ms_p95": percentile(capture_intervals, 0.95),
    }
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
