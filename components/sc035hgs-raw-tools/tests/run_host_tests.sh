#!/usr/bin/env bash
# Check component structure and shell contracts without the vendor SDK.
set -euo pipefail

component_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
build_script=$component_root/ports/duo-sdk/build.sh
session_tool=$component_root/tools/sc035hgs-raw-session
tolerance_tool=$component_root/tools/sc035hgs-replay-tolerance
replay_patch=$component_root/ports/duo-sdk/patches/0003-enforce-raw-replay-input-contract.patch
platform_patch=$component_root/ports/duo-sdk/patches/0004-use-offline-replay-platform.patch
observation_patch=$component_root/ports/duo-sdk/patches/0005-bound-replay-observation-and-exit.patch
platform_source=$component_root/src/replay_platform.c
unpack_source=$component_root/src/raw_unpack.c
log_compat_source=$component_root/src/vendor_log_compat.c
tmp_dir=$(mktemp -d)
tmp_replay_script=$tmp_dir/replay.txt
unpack_test=$tmp_dir/sc035hgs-raw-unpack-test
trap 'rm -rf "$tmp_dir"' EXIT

bash -n "$build_script"
sh -n "$session_tool"
test -x "$session_tool"
"$session_tool" --help >/dev/null
python3 - "$tolerance_tool" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
compile(source, sys.argv[1], "exec")
PY

${CC:-cc} -std=c11 -Wall -Wextra -Werror \
	-I"$component_root/tests/include" "$unpack_source" \
	"$log_compat_source" "$component_root/tests/raw_unpack_decoder_stub.c" \
	-o "$unpack_test"
printf '\001\002\003\004\005\006\007\010\011\012\013\014' \
	>"$tmp_dir/input.raw"
printf '\000\001\001\001\002\001\003\001\004\001\005\001\006\001\007\001' \
	>"$tmp_dir/expected.raw16le"
"$unpack_test" "$tmp_dir/input.raw" 4 2 "$tmp_dir/output.raw16le" \
	>"$tmp_dir/unpack.txt"
cmp "$tmp_dir/expected.raw16le" "$tmp_dir/output.raw16le"
grep -Fq 'width=4 height=2 stride=6 output_bytes=16' "$tmp_dir/unpack.txt"
if "$unpack_test" "$tmp_dir/input.raw" 0 2 "$tmp_dir/rejected.raw16le" \
	>/dev/null 2>&1; then
	echo "RAW unpacker accepted zero width" >&2
	exit 1
fi
if "$unpack_test" "$tmp_dir/input.raw" 4 5 "$tmp_dir/rejected.raw16le" \
	>/dev/null 2>&1; then
	echo "RAW unpacker accepted a non-integral compressed stride" >&2
	exit 1
fi
if "$unpack_test" "$tmp_dir/input.raw" 4294967295 4294967295 \
	"$tmp_dir/rejected.raw16le" >/dev/null 2>&1; then
	echo "RAW unpacker accepted an overflowing decoded size" >&2
	exit 1
fi
printf '\377\002\003\004\005\006\007\010\011\012\013\014' \
	>"$tmp_dir/decoder-failure.raw"
if "$unpack_test" "$tmp_dir/decoder-failure.raw" 4 2 \
	"$tmp_dir/rejected.raw16le" >/dev/null 2>&1; then
	echo "RAW unpacker ignored decoderRaw failure" >&2
	exit 1
fi
if "$unpack_test" "$tmp_dir/input.raw" 4 2 "$tmp_dir/input.raw" \
	>/dev/null 2>&1; then
	echo "RAW unpacker accepted the input file as its output" >&2
	exit 1
fi

if "$session_tool" capture relative/path >/dev/null 2>&1; then
	echo "session wrapper accepted a relative capture path" >&2
	exit 1
fi
if "$session_tool" capture /tmp/raw >/dev/null 2>&1; then
	echo "session wrapper accepted a capture path outside /mnt/data/raw" >&2
	exit 1
fi
if "$session_tool" capture-series relative/path 16 >/dev/null 2>&1; then
	echo "session wrapper accepted a relative series path" >&2
	exit 1
fi
if "$session_tool" capture-series /mnt/data/raw/series 1 >/dev/null 2>&1; then
	echo "session wrapper accepted a series count below two" >&2
	exit 1
fi
if "$session_tool" capture-series /mnt/data/raw/series 11 >/dev/null 2>&1; then
	echo "session wrapper accepted a series count above the hardware bound" >&2
	exit 1
fi
if "$session_tool" capture-series /mnt/data/raw/series invalid >/dev/null 2>&1; then
	echo "session wrapper accepted a non-numeric series count" >&2
	exit 1
fi
if "$session_tool" capture-iso /mnt/data/raw/frame 0 100 \
	>/dev/null 2>&1; then
	echo "session wrapper accepted zero exposure" >&2
	exit 1
fi
if "$session_tool" capture-iso /mnt/data/raw/frame 10000 99 \
	>/dev/null 2>&1; then
	echo "session wrapper accepted ISO below 100" >&2
	exit 1
fi
if "$session_tool" capture-series-iso /mnt/data/raw/series 2 10000 \
	invalid >/dev/null 2>&1; then
	echo "session wrapper accepted a non-numeric ISO" >&2
	exit 1
fi
if "$session_tool" capture-series-iso /mnt/data/raw/series 11 10000 \
	100 >/dev/null 2>&1; then
	echo "configured series accepted a count above the hardware bound" >&2
	exit 1
fi
if "$session_tool" replay relative/script >/dev/null 2>&1; then
	echo "session wrapper accepted a relative replay path" >&2
	exit 1
fi
printf 'test_sensor_cfg = /mnt/data/sensor_cfg.ini\n' >"$tmp_replay_script"
if unsafe_output=$("$session_tool" replay "$tmp_replay_script" 2>&1); then
	echo "session wrapper accepted the active sensor config as its own copy source" >&2
	exit 1
fi
grep -Fq 'test_sensor_cfg must differ from active /mnt/data/sensor_cfg.ini' \
	<<<"$unsafe_output"
grep -Fq 'cvi_raw_dump(isp_pipe, &dump_info)' \
	"$component_root/src/test_mmf/raw_capture.c"
grep -Fq 'require_empty_directory(resolved)' \
	"$component_root/src/test_mmf/raw_capture.c"
grep -Fq '0002-add-in-process-raw-capture.patch' "$build_script"
grep -Fq '0003-enforce-raw-replay-input-contract.patch' "$build_script"
grep -Fq '0004-use-offline-replay-platform.patch' "$build_script"
grep -Fq '0005-bound-replay-observation-and-exit.patch' "$build_script"
grep -Fq 'make -C "$raw_replay_lib_dir"' "$build_script"
grep -Fq '"$middleware_work/lib/libraw_replay.a"' "$build_script"
grep -Fq 'sc035hgs-raw-replay.contract.txt' "$build_script"
grep -Fq 'sc035hgs_replay_platform_init(&stInputSize,' "$platform_patch"
grep -Fq 'stVpssGrpAttr.u8VpssDev = 1' "$platform_patch"
grep -Fq 'INCS += -I$(ISP_COMMON_PATH)/raw_replay' "$platform_patch"
grep -Fq 'INCS += -I$(SDIR)' "$platform_patch"
grep -Fq 'CVI_VI_SetDevTimingAttr(REPLAY_VI_DEV, &timing_attr)' \
	"$platform_source"
grep -Fq 'select_user_fe_source("for USER_FE geometry priming")' \
	"$platform_source"
grep -Fq 'CVI_VI_SendPipeRaw(1, pipes, frames, 0)' "$platform_source"
grep -Fq 'ret != CVI_ERR_VI_FAILED_NOT_ENABLED' "$platform_source"
grep -Fq 'USER_FE geometry primed %ux%u bayer=%d wdr=%d, expected ret=%#x' \
	"$platform_source"
if grep -Fq 'if (ret == CVI_SUCCESS)' "$platform_source"; then
	echo "geometry prime accepts an unverified zero-address return" >&2
	exit 1
fi
grep -Fq 'configure_user_fe_source("before VI device enable")' \
	"$platform_source"
grep -Fq 'configure_user_fe_source("after VI pipe creation")' \
	"$platform_source"
prime_source_line=$(grep -n 'select_user_fe_source("for USER_FE geometry priming")' \
	"$platform_source" | cut -d: -f1)
timing_line=$(grep -n 'ret = configure_replay_timing()' \
	"$platform_source" | cut -d: -f1)
prime_send_line=$(grep -n 'ret = prime_user_fe_geometry()' "$platform_source" | cut -d: -f1)
set_attr_line=$(grep -n 'CVI_VI_SetDevAttr(REPLAY_VI_DEV' "$platform_source" | cut -d: -f1)
pre_enable_line=$(grep -n 'configure_user_fe_source("before VI device enable")' \
	"$platform_source" | cut -d: -f1)
enable_dev_line=$(grep -n 'CVI_VI_EnableDev(REPLAY_VI_DEV)' "$platform_source" | cut -d: -f1)
create_pipe_line=$(grep -n 'CVI_VI_CreatePipe(REPLAY_VI_PIPE' "$platform_source" | cut -d: -f1)
post_create_line=$(grep -n 'configure_user_fe_source("after VI pipe creation")' \
	"$platform_source" | cut -d: -f1)
start_pipe_line=$(grep -n 'CVI_VI_StartPipe(REPLAY_VI_PIPE)' "$platform_source" | cut -d: -f1)
test "$prime_source_line" -lt "$timing_line"
test "$timing_line" -lt "$prime_send_line"
test "$prime_send_line" -lt "$set_attr_line"
test "$set_attr_line" -lt "$pre_enable_line"
test "$pre_enable_line" -lt "$enable_dev_line"
test "$create_pipe_line" -lt "$post_create_line"
test "$post_create_line" -lt "$start_pipe_line"
grep -Fq 'VPSS_MODE_DUAL' "$platform_source"
grep -Fq 'VPSS_INPUT_MEM' "$platform_source"
grep -Fq 'VPSS_INPUT_ISP' "$platform_source"
grep -Fq 'SAMPLE_COMM_ISP_Aelib_Callback' "$platform_source"
grep -Fq 'SAMPLE_COMM_ISP_Awblib_Callback' "$platform_source"
grep -Fq 'SAMPLE_COMM_ISP_Run' "$platform_source"
grep -Fq 'sc035hgs_replay_platform_deinit' "$platform_source"
if grep -Eq 'SAMPLE_COMM_VI_(StartSensor|StartMIPI|SensorProbe|CreateIsp)' \
	"$platform_source"; then
	echo "offline replay platform still starts the physical sensor path" >&2
	exit 1
fi
if grep -Fq 'sample/common/sample_common_vi.c' "$replay_patch"; then
	echo "rejected source-before-enable patch is still present" >&2
	exit 1
fi
grep -Fq 'VI pipe source contract failed' "$replay_patch"
grep -Fq 'RAW metadata does not match offline replay platform' "$replay_patch"
grep -Fq 'raw replay stopped before offline platform teardown' "$replay_patch"
grep -Fq 'get_rgbmap_buf failed with %#x, stopping replay' "$replay_patch"
grep -Fq 'RGB-map DMA unavailable for USER_FE; continuing without RGB map' \
	"$replay_patch"
grep -Fq 'RGB-map DMA descriptor is empty' "$replay_patch"
grep -Fq 'CVI_ISP_GetVDTimeOut(0, ISP_VD_FE_END, 100)' "$replay_patch"
grep -Fq 'single-frame raw send begin' "$replay_patch"
grep -Fq 'single-frame raw send end, ret=%#x' "$replay_patch"
grep -Fq 'single-frame FE wait end, ret=%#x' "$replay_patch"
grep -Fq 'RETURN_FAILURE_IF(pCtx->drvInfo[0].vir_addr == NULL)' \
	"$replay_patch"
grep -Fq 'pCtx->drvInfo[0].vir_addr == NULL ||' "$replay_patch"
if grep -Fq 'ERROR_IF(frame_source != VI_PIPE_FRAME_SOURCE_USER_FE)' \
	"$replay_patch"; then
	echo "RAW replay source readback is still advisory" >&2
	exit 1
fi
if grep -Eq '^\+[[:space:]]*ERROR_IF\(s32Ret != CVI_SUCCESS\);' \
	"$replay_patch"; then
	echo "RAW replay RGB-map failure still falls through to memcpy" >&2
	exit 1
fi
grep -Fq 'VENC warmup deferred until USER_FE replay' "$replay_patch"
if grep -Eq '^[+ ].*wait venc thread ready' "$replay_patch"; then
	echo "RAW replay still waits for live-sensor VENC warmup" >&2
	exit 1
fi
grep -Fq 'setvbuf(stdout, NULL, _IONBF, 0)' "$observation_patch"
grep -Fq 'start_raw_replay returned %#x' "$observation_patch"
grep -Fq 'raw replay ready' "$observation_patch"
grep -Fq 'CVI_ISP_GetVDTimeOut(0, ISP_VD_BE_END, 100)' \
	"$observation_patch"
grep -Fq 'BE wait frame=%u returned %#x' "$observation_patch"
grep -Fq 'first VPSS output frame %ux%u lengths=%u/%u/%u' \
	"$observation_patch"
grep -Fq 'CVI_VPSS_GetChnFrame(0, 0, &stVencFrame, s32SetFrameMilliSec)' \
	"$observation_patch"
grep -Fq 'CVI_VENC_GetStream(VencChn, &stStream, s32SetFrameMilliSec)' \
	"$observation_patch"
grep -Fq 'if (!bEnableVencThread)' "$observation_patch"
grep -Fq 'remember_failure(s32TestStatus, &s32Ret)' "$observation_patch"
grep -Fq 'error: VPSS output wait timed out, last ret=%#x' \
	"$observation_patch"
grep -Fq 'sc035hgs-test_mmf-raw' "$build_script"
grep -Fq 'sc035hgs-raw-unpack' "$build_script"
grep -Fq "'decoderRaw'" "$build_script"
grep -Fq 'raw_info.stride = stride' "$unpack_source"
grep -Fq 'decode_status = decoderRaw(raw_info, decoded)' "$unpack_source"
grep -Fq 'encode_little_endian(decoded, pixel_count)' "$unpack_source"
grep -Fq 'CVI_S32 *log_levels = NULL' "$log_compat_source"
grep -Fq '"$component_root/src/vendor_log_compat.c"' "$build_script"
grep -Fq 'isp_algo_archive=$middleware_work/modules/isp/cv181x/musl_riscv64/libisp_algo.a' \
	"$build_script"
grep -Fq '"$isp_algo_archive" -Wl,--gc-sections -lm' "$build_script"
grep -Fq "printf 'isp_algo_archive_sha256=%s\\n'" "$build_script"
grep -Fq 'mv "$middleware_work/include/linux" "$vendor_linux_flat"' \
	"$build_script"
grep -Fq 'ln -s ../vendor-linux-include "$vendor_linux_root/linux"' \
	"$build_script"
grep -Fq 'test ! -e "$middleware_work/include/linux"' "$build_script"
grep -Fq "'RGB-map DMA descriptor is empty'" "$build_script"
grep -Fq "'offline replay platform: sensor and MIPI startup disabled'" \
	"$build_script"
grep -Fq "'offline replay platform: VPSS dual MEM/ISP route configured'" \
	"$build_script"
grep -Fq "'offline replay platform: USER_FE selected %s'" "$build_script"
grep -Fq "'for USER_FE geometry priming'" "$build_script"
grep -Fq "'offline replay platform: USER_FE geometry primed %ux%u bayer=%d wdr=%d, expected ret=%#x'" \
	"$build_script"
grep -Fq "'offline replay platform: USER_FE confirmed %s'" \
	"$build_script"
grep -Fq "'before VI device enable'" "$build_script"
grep -Fq "'after VI pipe creation'" "$build_script"
grep -Fq "'offline replay platform: teardown complete'" "$build_script"
grep -Fq "'single-frame raw send begin'" "$build_script"
grep -Fq "'single-frame raw send end, ret=%#x'" "$build_script"
grep -Fq "'single-frame FE wait end, ret=%#x'" "$build_script"
grep -Fq "'RGB-map DMA unavailable for USER_FE; continuing without RGB map'" \
	"$build_script"
grep -Fq "'BE wait frame=%u returned %#x'" "$build_script"
grep -Fq "'first VPSS output frame %ux%u lengths=%u/%u/%u'" \
	"$build_script"
if grep -Fq 'raw_dump_test' "$build_script"; then
	echo "standalone RAW capture path is still present" >&2
	exit 1
fi
grep -Fq 'set -eu' "$session_tool"
grep -Fq 'systemd-run --unit=maixcam-raw-camera' "$session_tool"
# shellcheck disable=SC2016
grep -Fq 'timeout 30 "$capture_camera" --ispctl raw capture "$capture_output"' \
	"$session_tool"
grep -Fq 'SERIES_FRAME=%03d STATUS=PASS' "$session_tool"
grep -Fq 'EFFECTIVE_EXPOSURE_STATE=%s' "$session_tool"
grep -Fq 'capture-state.txt' "$session_tool"
grep -Fq 'sleep 1' "$session_tool"
# shellcheck disable=SC2016
grep -Fq 'timeout 90 "$operation_binary" "$@"' "$session_tool"

python3 - "$tmp_dir" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
root.joinpath("control-1.yuv").write_bytes(bytes(24))
control_2 = bytearray(24)
control_2[0] = 1
root.joinpath("control-2.yuv").write_bytes(control_2)
root.joinpath("candidate-1.yuv").write_bytes(bytes([10]) * 24)
candidate_2 = bytearray([10] * 24)
candidate_2[0] = 11
root.joinpath("candidate-2.yuv").write_bytes(candidate_2)
PY
tolerance_args=(--width 4 --height 4 \
	--plane-tolerance Y:0.1:1 --plane-tolerance U:0.3:1 \
	--plane-tolerance V:0.3:1)
python3 "$tolerance_tool" "${tolerance_args[@]}" \
	--control "$tmp_dir/control-1.yuv" --control "$tmp_dir/control-2.yuv" \
	--candidate "$tmp_dir/control-1.yuv" --candidate "$tmp_dir/control-2.yuv" \
	--expect equivalent --output "$tmp_dir/equivalent.json" >/dev/null
grep -Fq '"status": "PASS_EQUIVALENT"' "$tmp_dir/equivalent.json"
python3 "$tolerance_tool" "${tolerance_args[@]}" \
	--control "$tmp_dir/control-1.yuv" --control "$tmp_dir/control-2.yuv" \
	--candidate "$tmp_dir/candidate-1.yuv" --candidate "$tmp_dir/candidate-2.yuv" \
	--expect different --output "$tmp_dir/different.json" >/dev/null
grep -Fq '"status": "PASS_DISTINGUISHABLE"' "$tmp_dir/different.json"
if python3 "$tolerance_tool" --width 4 --height 4 \
	--plane-tolerance Y:0:0 --plane-tolerance U:0:0 \
	--plane-tolerance V:0:0 \
	--control "$tmp_dir/control-1.yuv" --control "$tmp_dir/control-2.yuv" \
	--candidate "$tmp_dir/control-1.yuv" --candidate "$tmp_dir/control-2.yuv" \
	--expect equivalent --output "$tmp_dir/invalid-control.json" >/dev/null; then
	echo "replay tolerance accepted an unstable control set" >&2
	exit 1
fi
grep -Fq '"status": "INVALID_CONTROL_VARIABILITY"' \
	"$tmp_dir/invalid-control.json"
if python3 "$tolerance_tool" "${tolerance_args[@]}" \
	--control "$tmp_dir/control-1.yuv" --control "$tmp_dir/control-1.yuv" \
	--candidate "$tmp_dir/candidate-1.yuv" --candidate "$tmp_dir/candidate-2.yuv" \
	--expect different --output "$tmp_dir/duplicate-control.json" \
	>/dev/null 2>&1; then
	echo "replay tolerance accepted a duplicate control path" >&2
	exit 1
fi
if python3 "$tolerance_tool" "${tolerance_args[@]}" \
	--control "$tmp_dir/control-1.yuv" --control "$tmp_dir/control-2.yuv" \
	--candidate "$tmp_dir/candidate-1.yuv" --candidate "$tmp_dir/candidate-2.yuv" \
	--expect different --output "$tmp_dir/control-1.yuv" \
	>/dev/null 2>&1; then
	echo "replay tolerance accepted an input path as output" >&2
	exit 1
fi

printf 'shell_syntax=PASS\npath_validation=PASS\nin_process_capture=PASS\nraw_unpack_contract=PASS\nreplay_tolerance=PASS\n'
