# MaixCAM low-latency viewer

This host tool displays the MaixCAM HEVC stream without the large frame queue
observed in generic OpenCV and VLC defaults. It uses TCP RTSP with demuxer
buffering disabled and a single slice-threaded low-delay decoder.

On Windows, the launcher creates a virtual environment under
`%LOCALAPPDATA%\MaixCAM\camera-viewer`, installs the pinned dependencies only
when `requirements.txt` changes, and opens the viewer:

```powershell
tools\maixcam-camera\run-viewer.ps1
```

Use `-SetupOnly` to prepare or verify the environment without opening a second
RTSP client.

The process inherits `HTTP_PROXY` and `HTTPS_PROXY` when package downloads need
a proxy. Pass another stream URL with `-Url`. Close the window, press Escape,
or press `q` to exit.

The tool does not configure the board or ISP. The camera service must already
be serving `rtsp://10.42.0.1:8554/live`.

## Uncompressed Y8 preview

When the optional board-side preview is enabled, this launcher displays its
latest `640x480` ISP-processed grayscale frame:

```powershell
tools\maixcam-camera\run-y8-viewer.ps1
```

The server listens on TCP port `8555` by default. Each frame has a fixed
40-byte network-order header followed by exactly 307,200 tightly packed Y8
bytes. The header carries magic, protocol version, dimensions, stride,
format, sequence, monotonic capture timestamp, payload length, and a reserved
field. The server keeps only the newest frame, so a slow client observes
sequence gaps instead of creating a growing queue.

This stream is uncompressed ISP output, not sensor RAW. It is disabled by
default on the board and does not replace the H.265 RTSP stream.

The SC035HGS camera process enables it only when explicitly started with
`MAIXCAM_Y8_PREVIEW=1`; `MAIXCAM_Y8_PORT` optionally overrides port `8555`.
This keeps existing images and services unchanged until the preview is
deliberately enabled.

For a headless measurement that does not display or retain frames:

```powershell
python tools\maixcam-camera\y8_benchmark.py --frames 120
```

The JSON result reports arrival and board-capture intervals, effective payload
throughput, and sequence gaps. Host-to-board latency is intentionally omitted
because their monotonic clocks are not synchronized.

The matching headless RTSP check uses the same low-delay decoder configuration
as the interactive viewer:

```powershell
& "$env:LOCALAPPDATA\MaixCAM\camera-viewer\venv\Scripts\python.exe" `
  tools\maixcam-camera\rtsp_benchmark.py --frames 120
```
