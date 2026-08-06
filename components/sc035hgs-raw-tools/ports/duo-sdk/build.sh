#!/usr/bin/env bash
# Build a development test_mmf RAW owner and the standalone replay tool.
set -euo pipefail

port_root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
component_root=$(cd "$port_root/../.." && pwd)
repo_root=$(cd "$component_root/../.." && pwd)
# shellcheck disable=SC1091
source "$repo_root/versions.env"
# shellcheck disable=SC1091
source "$repo_root/components/sg2002-ipc/versions.env"

board=${BOARD:-maixcam-sc035hgs}
sdk_cache=${SDK_CACHE:-$component_root/.cache/sdk}
board_build_root=${BOARD_BUILD_ROOT:-$component_root/.cache/boards/$board-sd}
middleware_source=${MIDDLEWARE_SOURCE:-$board_build_root/middleware}
kernel_source=${KERNEL_SOURCE:-$board_build_root/kernel}
osdrv_source=${OSDRV_SOURCE:-$board_build_root/osdrv}
output_dir=${OUTPUT_DIR:-$component_root/out}
cross_compile=${CROSS_COMPILE:-riscv64-unknown-linux-musl-}

if [[ $board != maixcam-sc035hgs ]]; then
	echo "unsupported board: $board (expected maixcam-sc035hgs)" >&2
	exit 2
fi
: "${MIDDLEWARE_COMMIT:?MIDDLEWARE_COMMIT is required}"
: "${RTOS_SDK_REPO:?RTOS_SDK_REPO is required}"
: "${RTOS_SDK_COMMIT:?RTOS_SDK_COMMIT is required}"
for directory in "$middleware_source" "$kernel_source" "$osdrv_source"; do
	test -d "$directory" || { echo "prepared source tree is missing: $directory" >&2; exit 1; }
done
test -x "${cross_compile}gcc" || { echo "cross compiler is missing: ${cross_compile}gcc" >&2; exit 1; }

middleware_head=$(git -C "$middleware_source" rev-parse HEAD)
middleware_pin=$(git -C "$middleware_source" rev-parse "$MIDDLEWARE_COMMIT^{commit}")
if [[ $middleware_head != "$middleware_pin" ]]; then
	echo "middleware HEAD $middleware_head does not match pin $middleware_pin" >&2
	exit 1
fi

mkdir -p "$sdk_cache" "$output_dir"
vendor_git="$sdk_cache/duo-buildroot-sdk-v2.git"
if [[ ! -d $vendor_git/objects ]]; then
	git init --bare "$vendor_git"
	git --git-dir="$vendor_git" remote add origin "$RTOS_SDK_REPO"
fi
git --git-dir="$vendor_git" remote set-url origin "$RTOS_SDK_REPO"
if ! git --git-dir="$vendor_git" cat-file -e "$RTOS_SDK_COMMIT^{commit}" 2>/dev/null; then
	git --git-dir="$vendor_git" fetch --depth 1 origin "$RTOS_SDK_COMMIT"
fi

work_root=$(mktemp -d /tmp/sc035hgs-raw-tools.XXXXXX)
middleware_work=$work_root/middleware
vendor_linux_include=$work_root/vendor-linux-include
repro_flags="-ffile-prefix-map=$work_root=/usr/src/sc035hgs-raw-tools -fdebug-prefix-map=$work_root=/usr/src/sc035hgs-raw-tools"
trap 'rm -rf "$work_root"' EXIT

mkdir -p "$middleware_work"
cp -a "$middleware_source/." "$middleware_work/"
ln -s "$kernel_source" "$work_root/kernel"
ln -s "$osdrv_source" "$work_root/osdrv"
ln -s Makefile.param "$middleware_work/mpi_param.mk"
test ! -e "$middleware_work/include/linux"

git --git-dir="$vendor_git" archive "$RTOS_SDK_COMMIT" \
	cvi_mpi/include/linux \
	cvi_mpi/modules/isp/common/inc \
	cvi_mpi/modules/isp/common/raw_replay_test \
	| tar -x -C "$middleware_work" --strip-components=1
mv "$middleware_work/include/linux" "$vendor_linux_include"
git -C "$middleware_work" apply \
	"$port_root/patches/0001-build-raw-tools-against-current-cv181x.patch"
cp "$component_root/src/test_mmf/raw_capture.c" \
	"$component_root/src/test_mmf/raw_capture.h" \
	"$middleware_work/sample/test_mmf/"
git -C "$middleware_work" apply \
	"$port_root/patches/0002-add-in-process-raw-capture.patch"
git -C "$middleware_work" apply \
	"$port_root/patches/0003-enforce-raw-replay-input-contract.patch"
git -C "$middleware_work" apply \
	"$port_root/patches/0004-use-offline-replay-platform.patch"
git -C "$middleware_work" apply \
	"$port_root/patches/0005-bound-replay-observation-and-exit.patch"

raw_replay_dir=$middleware_work/sample/raw_replay_test
raw_replay_lib_dir=$middleware_work/modules/isp/common/raw_replay
test_mmf_dir=$middleware_work/sample/test_mmf
mkdir -p "$raw_replay_dir"
cp "$middleware_work/modules/isp/common/raw_replay_test/raw_replay_test.mk" \
	"$raw_replay_dir/Makefile"
cp "$component_root/src/raw_replay_main.c" "$raw_replay_dir/main.c"
cp "$component_root/src/replay_platform.c" \
	"$component_root/src/replay_platform.h" "$raw_replay_dir/"

source_date_epoch=$(git -C "$middleware_source" show -s --format=%ct HEAD)
case "$source_date_epoch" in
	*[!0-9]*|'') echo "invalid middleware commit timestamp" >&2; exit 1 ;;
esac
export SOURCE_DATE_EPOCH=$source_date_epoch

build_env=(
	CHIP_ARCH=CV181X
	CVIARCH=CV181X
	SDK_VER=musl_riscv64
	CROSS_COMPILE_MUSL_RISCV64="$cross_compile"
	CONFIG_ARCH=riscv
	CONFIG_CROSS_COMPILE_KERNEL="$cross_compile"
	CONFIG_CP_EXT_WIRELESS=y
	CONFIG_NO_FB=1
	CONFIG_SENSOR_GCORE_GC2083=y
	CONFIG_SENSOR_GCORE_GC4653=y
	CONFIG_SENSOR_OV_OS04A10=y
	CONFIG_SENSOR_OV_OV2685=y
	CONFIG_SENSOR_OV_OV5647=y
	CONFIG_SENSOR_SMS_SC035GS=y
	CONFIG_SENSOR_SMS_SC035HGS=y
	CONFIG_SENSOR_LONTIUM_LT6911=y
	"CVI_TARGET_PACKAGES_INCLUDE=-I$middleware_work/component/isp/common $repro_flags"
)
middleware_libs=$(PKG_CONFIG_PATH="$middleware_work/pkgconfig" pkg-config --libs \
	--define-variable=mw_dir="$middleware_work" cvi_common cvi_sample)

start_epoch=$(date +%s)
env "${build_env[@]}" \
	CVI_TARGET_PACKAGES_INCLUDE="-I$middleware_work/component/isp/common -I$middleware_work/modules/isp/cv181x/isp_algo/inc -I$vendor_linux_include -Wno-error=format-truncation $repro_flags" \
	make -C "$raw_replay_lib_dir" -j"$(nproc)" \
	KERNEL_DIR="$kernel_source" PWD="$raw_replay_lib_dir" \
	"$middleware_work/lib/libraw_replay.a"
env "${build_env[@]}" \
	CVI_TARGET_PACKAGES_INCLUDE="-I$middleware_work/component/isp/common -I$middleware_work/modules/isp/cv181x/isp_algo/inc -I$vendor_linux_include -Wno-error=format-truncation $repro_flags" \
	make -C "$raw_replay_dir" -j"$(nproc)" \
	KERNEL_DIR="$kernel_source" PWD="$raw_replay_dir" SAMPLE_STATIC=1 \
	EXTRA_LDFLAGS="-Wl,--start-group -lraw_replay $middleware_libs -Wl,--end-group -lpthread -ldl -lm" all
env "${build_env[@]}" make -C "$test_mmf_dir" -j"$(nproc)" \
	KERNEL_DIR="$kernel_source" PWD="$test_mmf_dir" all
elapsed_seconds=$(( $(date +%s) - start_epoch ))

install -m 0755 "$test_mmf_dir/test_mmf" \
	"$output_dir/sc035hgs-test_mmf-raw"
install -m 0755 "$raw_replay_dir/raw_replay_test" "$output_dir/sc035hgs-raw-replay"
install -m 0755 "$component_root/tools/sc035hgs-raw-session" \
	"$output_dir/sc035hgs-raw-session"

replay_strings=$work_root/sc035hgs-raw-replay.strings
"${cross_compile}strings" "$output_dir/sc035hgs-raw-replay" >"$replay_strings"
linked_raw_replay_object=$work_root/linked-raw_replay.o
"${cross_compile}ar" p "$middleware_work/lib/libraw_replay.a" raw_replay.o \
	>"$linked_raw_replay_object"
read -r raw_replay_source_sha _ < <(sha256sum "$raw_replay_lib_dir/raw_replay.c")
read -r raw_replay_object_sha _ < <(sha256sum "$linked_raw_replay_object")
read -r replay_platform_source_sha _ < <(sha256sum "$raw_replay_dir/replay_platform.c")
read -r replay_platform_object_sha _ < <(sha256sum "$raw_replay_dir/replay_platform.o")
read -r replay_binary_sha _ < <(sha256sum "$output_dir/sc035hgs-raw-replay")
contract_file=$output_dir/sc035hgs-raw-replay.contract.txt
contract_markers=(
	'offline replay platform: sensor and MIPI startup disabled'
	'offline replay platform: VPSS dual MEM/ISP route configured'
	'offline replay platform: replay timing configured before VI device'
	'offline replay platform: USER_FE selected %s'
	'offline replay platform: USER_FE confirmed %s'
	'for USER_FE geometry priming'
	'offline replay platform: USER_FE geometry primed %ux%u bayer=%d wdr=%d, expected ret=%#x'
	'before VI device enable'
	'after VI pipe creation'
	'offline replay platform: ready'
	'RAW metadata matches offline platform'
	'raw replay stopped before offline platform teardown'
	'offline replay platform: teardown complete'
	'single-frame raw send begin'
	'single-frame raw send end, ret=%#x'
	'single-frame FE wait end, ret=%#x'
	'RGB-map DMA descriptor is empty'
	'RGB-map DMA unavailable for USER_FE; continuing without RGB map'
	'error: get_rgbmap_buf failed with %#x, stopping replay'
	'start_raw_replay returned %#x'
	'raw replay ready'
	'BE wait frame=%u returned %#x'
	'BE stable wait complete, frames=%u'
	'first VPSS output frame %ux%u lengths=%u/%u/%u'
	'VPSS output frame dump complete'
	'error: VPSS output wait timed out, last ret=%#x'
	'vencThread end...'
)
{
	printf 'status=PASS\n'
	printf 'raw_replay_source_sha256=%s\n' "$raw_replay_source_sha"
	printf 'linked_raw_replay_object_sha256=%s\n' "$raw_replay_object_sha"
	printf 'replay_platform_source_sha256=%s\n' "$replay_platform_source_sha"
	printf 'replay_platform_object_sha256=%s\n' "$replay_platform_object_sha"
	printf 'replay_binary_sha256=%s\n' "$replay_binary_sha"
	for marker in "${contract_markers[@]}"; do
		grep -Fq "$marker" "$replay_strings" || {
			echo "linked replay binary is missing contract marker: $marker" >&2
			exit 1
		}
		printf 'marker=%s\n' "$marker"
	done
} >"$contract_file"

for binary in sc035hgs-test_mmf-raw sc035hgs-raw-replay; do
	file "$output_dir/$binary" >"$output_dir/$binary.file.txt"
	"${cross_compile}readelf" -h -d "$output_dir/$binary" \
		>"$output_dir/$binary.readelf.txt"
done
(
	cd "$output_dir"
	sha256sum sc035hgs-test_mmf-raw sc035hgs-raw-replay \
		sc035hgs-raw-session sc035hgs-raw-replay.contract.txt >SHA256SUMS
)
{
	printf 'status=PASS\n'
	printf 'board=%s\n' "$board"
	printf 'vendor_commit=%s\n' "$RTOS_SDK_COMMIT"
	printf 'middleware_commit=%s\n' "$middleware_head"
	printf 'source_date_epoch=%s\n' "$source_date_epoch"
	printf 'build_elapsed_seconds=%s\n' "$elapsed_seconds"
} >"$output_dir/sc035hgs-raw-tools.build.env"
