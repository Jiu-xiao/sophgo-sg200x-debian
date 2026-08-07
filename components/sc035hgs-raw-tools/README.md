# SC035HGS RAW tools

This component builds an isolated development workflow for the
`maixcam-sc035hgs` board:

- `sc035hgs-test_mmf-raw` is a development-only `test_mmf` variant that owns
  the complete camera pipeline and accepts one guarded in-process RAW dump.
- `sc035hgs-raw-replay` runs the vendor RAW replay test from a script file.
- `sc035hgs-raw-unpack` decodes one vendor-compressed frame to a headerless,
  row-major 16-bit little-endian Bayer frame using the pinned SDK's
  `decoderRaw()` implementation.

`sc035hgs-raw-session` temporarily replaces the normal network-camera process
with the development variant for capture, or takes exclusive media ownership
for replay. It then restores automatic exposure, sensor register `0x4501=0xc4`,
TNR ISO0 `24`, remoteproc, and C906L communication. Nothing in this component
is selected by a production board configuration or installed in production
images.

## Build

The component uses the repository's middleware pin and the vendor SDK pin from
`components/sg2002-ipc/versions.env`. It requires the patched middleware,
kernel, and OSdrv trees prepared by the board build:

```sh
make raw-tools BOARD=maixcam-sc035hgs
```

For a standalone invocation, provide their common board build root:

```sh
make -C components/sc035hgs-raw-tools \
  BOARD=maixcam-sc035hgs \
  BOARD_BUILD_ROOT=/build-cache/boards/maixcam-sc035hgs-sd \
  SDK_CACHE=/sdk-cache \
  CROSS_COMPILE=/build-cache/toolchains/musl/bin/riscv64-unknown-linux-musl-
```

## Capture

Run from a task-owned directory on the board. Capture is intentionally fixed to
one frame at `10000 us`, ISO 100, and unity analog/digital/ISP gains (`1024`):

```sh
./sc035hgs-raw-session capture /mnt/data/raw/session-001
```

The output directory must be empty and resolve below `/mnt/data/raw`. Capture
is rejected unless the effective exposure and gains match exactly, and unless
one non-empty RAW file plus its TXT and JSON metadata are present. The normal
camera service is restored even when capture fails.

For repeated same-condition frames, keep the development pipeline alive and
capture into numbered child directories:

```sh
./sc035hgs-raw-session capture-series /mnt/data/raw/dark-series-001 8
```

`COUNT` must be from 2 to 10 and the output root must not already exist. Use
multiple output roots for a larger sample set. The bound stays below the
observed vendor VI failure on the twelfth continuous dump. The
wrapper applies fixed exposure and gains once, waits one second between dumps,
and restores the product camera only after the series finishes or fails. This
avoids mixing camera-process restarts into temporal statistics.

## Decode

The captured `640x480` payload is vendor-compressed data, not generic packed
RAW12. Decode it before calculating sensor statistics:

```sh
sc035hgs-raw-unpack INPUT.raw 640 480 OUTPUT.raw16le
```

The input size must be a nonzero multiple of the height. Its compressed stride
is derived as `input_size / height` and passed to `RAW_INFO`; dimensions and all
size calculations are checked for overflow. The output is exactly
`width * height * 2` bytes. The unpacker rejects an output path that identifies
the input file and returns nonzero when the vendor decoder fails.
The vendor object references two logging globals normally owned by the SYS
runtime. The standalone binary provides only those required ABI symbols with
`log_levels` unset; it does not initialize media devices, SYS, VB, or ION.
The pinned decoder object uses T-Head C906 instructions, so generic
`qemu-riscv64` is not a valid runtime check; decoding must be verified on the
target core.

## Deterministic replay

Example replay script:

```text
test_start
test_dir = /mnt/data/raw/session-001
test_pq_bin = /mnt/cfg/param/cvi_sdr_bin
test_md5 = 1
test_end
```

Replay uses a component-owned offline VI/ISP platform. It reads the active
SC035HGS board configuration for dimensions, Bayer order, and WDR mode, but it
does not start, probe, or register the physical sensor and does not start MIPI.
The platform selects `SOURCE_USER_FE` without an early readback, configures
disabled replay timing, then submits a zero-address frame descriptor. The pinned
OSdrv writes `usr_fmt` and `usr_crop` before rejecting that address; middleware
maps the ioctl failure to `CVI_ERR_VI_FAILED_NOT_ENABLED`, and the component
accepts only that exact result. It later selects and reads back `SOURCE_USER_FE`
after applying VI device attributes but before enabling the device, and again
after pipe creation but before pipe start. This configures the offline FE without
treating the pre-device `GetPipeFrameSource` result as meaningful.
It starts AE/AWB plus ISP without sensor callbacks and
routes VPSS through the ISP input of dual mode. Every RAW header must match the
sensor-derived platform contract.
Live VENC warm-up is deferred until RAW injection starts, and the replay thread
is stopped before the platform is torn down. A `USER_FE` pipe with no 3DNR
RGB-map DMA skips that optional write; a real nonzero-buffer mapping failure
still stops replay before any buffer copy. The parser also restores the green
white-balance gain recorded as `reg_wbg_grgain`. Do not point
`test_sensor_cfg` at the active `/mnt/data/sensor_cfg.ini`: the vendor test
moves that file before copying and therefore requires a distinct source path
when an alternate sensor config is actually needed.

Replay diagnostics are unbuffered and report RAW start/ready, the first bounded
BE wait, and the first VPSS output frame. VI/ISP and VENC waits are bounded, so
metadata, source, BE, VPSS, or dump failures return a nonzero process status and
the component can tear down the replay, VENC, VPSS, and offline platform in
order instead of relying on the outer 90-second guard.

Run it with:

```sh
./sc035hgs-raw-session replay /mnt/data/raw/replay-official-pq.txt
```

Vendor MD5 mode disables TNR and DRC tone-curve smoothing. It is suitable for
deterministic RAW parsing and ISP regression, but its results are not evidence
for TNR tuning.
