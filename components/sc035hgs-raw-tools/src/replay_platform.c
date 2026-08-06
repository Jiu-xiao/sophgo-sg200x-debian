#include "replay_platform.h"

#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#include "cvi_ae.h"
#include "cvi_awb.h"
#include "cvi_bin.h"
#include "cvi_isp.h"

#define REPLAY_VI_DEV 0
#define REPLAY_VI_PIPE 0
#define REPLAY_VI_CHN 0
#define REPLAY_FPS 25
#define REPLAY_YUV_BLOCK_COUNT 4

typedef struct {
	bool sys_initialized;
	bool dev_enabled;
	bool pipe_created;
	bool pipe_started;
	bool ae_registered;
	bool awb_registered;
	bool isp_initialized;
	bool isp_running;
	bool channel_enabled;
	SIZE_S input_size;
	PIC_SIZE_E sensor_pic_size;
	ISP_PUB_ATTR_S isp_pub_attr;
} REPLAY_PLATFORM_STATE;

static REPLAY_PLATFORM_STATE state;

static CVI_S32 select_user_fe_source(const char *stage)
{
	CVI_S32 ret;

	ret = CVI_VI_SetPipeFrameSource(REPLAY_VI_PIPE,
		VI_PIPE_FRAME_SOURCE_USER_FE);
	if (ret != CVI_SUCCESS) {
		printf("offline replay platform: USER_FE selection failed %s, ret=%#x\n",
			stage, ret);
		return ret;
	}
	printf("offline replay platform: USER_FE selected %s\n", stage);
	return CVI_SUCCESS;
}

static CVI_S32 configure_user_fe_source(const char *stage)
{
	VI_PIPE_FRAME_SOURCE_E source = VI_PIPE_FRAME_SOURCE_BUTT;
	CVI_S32 ret;

	ret = select_user_fe_source(stage);
	if (ret != CVI_SUCCESS)
		return ret;
	ret = CVI_VI_GetPipeFrameSource(REPLAY_VI_PIPE, &source);
	if (ret != CVI_SUCCESS)
		return ret;
	if (source != VI_PIPE_FRAME_SOURCE_USER_FE) {
		printf("offline replay platform: USER_FE readback failed %s, source=%d\n",
			stage, source);
		return CVI_FAILURE;
	}
	printf("offline replay platform: USER_FE confirmed %s\n", stage);
	return CVI_SUCCESS;
}

static CVI_S32 prime_user_fe_geometry(void)
{
	VI_PIPE pipes[] = { REPLAY_VI_PIPE };
	VIDEO_FRAME_INFO_S frame = {0};
	const VIDEO_FRAME_INFO_S *frames[] = { &frame };
	CVI_S32 ret;

	frame.stVFrame.u32Width = state.input_size.u32Width;
	frame.stVFrame.u32Height = state.input_size.u32Height;
	frame.stVFrame.enBayerFormat =
		(BAYER_FORMAT_E)state.isp_pub_attr.enBayer;
	frame.stVFrame.enPixelFormat = 0;
	frame.stVFrame.enCompressMode = COMPRESS_MODE_NONE;
	frame.stVFrame.enDynamicRange =
		state.isp_pub_attr.enWDRMode == WDR_MODE_NONE ?
		DYNAMIC_RANGE_SDR10 : DYNAMIC_RANGE_HDR10;

	/*
	 * This OSdrv records the geometry before rejecting the zero physical
	 * address. Middleware maps that ioctl failure to FAILED_NOT_ENABLED.
	 */
	ret = CVI_VI_SendPipeRaw(1, pipes, frames, 0);
	if (ret != CVI_ERR_VI_FAILED_NOT_ENABLED) {
		printf("offline replay platform: USER_FE geometry prime returned unexpected %#x\n",
			ret);
		return CVI_FAILURE;
	}
	printf("offline replay platform: USER_FE geometry primed %ux%u bayer=%d wdr=%d, expected ret=%#x\n",
		state.input_size.u32Width, state.input_size.u32Height,
		state.isp_pub_attr.enBayer, state.isp_pub_attr.enWDRMode, ret);
	return CVI_SUCCESS;
}

static CVI_S32 init_system(const SIZE_S *size)
{
	VB_CONFIG_S vb_config = {0};
	CVI_U32 block_size;
	CVI_U32 rotated_block_size;

	block_size = COMMON_GetPicBufferSize(size->u32Width, size->u32Height,
		VI_PIXEL_FORMAT, DATA_BITWIDTH_8, COMPRESS_MODE_NONE, DEFAULT_ALIGN);
	rotated_block_size = COMMON_GetPicBufferSize(size->u32Height, size->u32Width,
		VI_PIXEL_FORMAT, DATA_BITWIDTH_8, COMPRESS_MODE_NONE, DEFAULT_ALIGN);
	if (rotated_block_size > block_size)
		block_size = rotated_block_size;

	vb_config.u32MaxPoolCnt = 1;
	vb_config.astCommPool[0].u32BlkSize = block_size;
	vb_config.astCommPool[0].u32BlkCnt = REPLAY_YUV_BLOCK_COUNT;
	vb_config.astCommPool[0].enRemapMode = VB_REMAP_MODE_CACHED;

	return SAMPLE_COMM_SYS_Init(&vb_config);
}

static CVI_S32 configure_pipeline_modes(void)
{
	VI_VPSS_MODE_S vi_vpss_mode = {0};
	VPSS_MODE_S vpss_mode = {0};
	CVI_S32 ret;

	vi_vpss_mode.aenMode[REPLAY_VI_PIPE] = VI_OFFLINE_VPSS_ONLINE;
	ret = CVI_SYS_SetVIVPSSMode(&vi_vpss_mode);
	if (ret != CVI_SUCCESS)
		return ret;

	vpss_mode.enMode = VPSS_MODE_DUAL;
	vpss_mode.aenInput[0] = VPSS_INPUT_MEM;
	vpss_mode.ViPipe[0] = REPLAY_VI_PIPE;
	vpss_mode.aenInput[1] = VPSS_INPUT_ISP;
	vpss_mode.ViPipe[1] = REPLAY_VI_PIPE;
	ret = CVI_SYS_SetVPSSModeEx(&vpss_mode);
	if (ret != CVI_SUCCESS)
		return ret;
	printf("offline replay platform: VPSS dual MEM/ISP route configured\n");

	return CVI_SUCCESS;
}

static CVI_S32 configure_replay_timing(void)
{
	VI_DEV_TIMING_ATTR_S timing_attr = {
		.bEnable = CVI_FALSE,
		.s32FrmRate = REPLAY_FPS,
	};
	CVI_S32 ret;

	ret = CVI_VI_SetDevTimingAttr(REPLAY_VI_DEV, &timing_attr);
	if (ret != CVI_SUCCESS)
		return ret;
	printf("offline replay platform: replay timing configured before VI device\n");

	return CVI_SUCCESS;
}

static CVI_S32 start_isp(void)
{
	ISP_BIND_ATTR_S bind_attr = {0};
	CVI_S32 ret;

	ret = SAMPLE_COMM_ISP_Aelib_Callback(REPLAY_VI_PIPE);
	if (ret != CVI_SUCCESS)
		return ret;
	state.ae_registered = true;

	ret = SAMPLE_COMM_ISP_Awblib_Callback(REPLAY_VI_PIPE);
	if (ret != CVI_SUCCESS)
		return ret;
	state.awb_registered = true;

	bind_attr.stAeLib.s32Id = REPLAY_VI_PIPE;
	bind_attr.stAwbLib.s32Id = REPLAY_VI_PIPE;
	bind_attr.sensorId = 0;
	snprintf(bind_attr.stAeLib.acLibName, sizeof(bind_attr.stAeLib.acLibName),
		"%s", CVI_AE_LIB_NAME);
	snprintf(bind_attr.stAwbLib.acLibName, sizeof(bind_attr.stAwbLib.acLibName),
		"%s", CVI_AWB_LIB_NAME);
	ret = CVI_ISP_SetBindAttr(REPLAY_VI_PIPE, &bind_attr);
	if (ret != CVI_SUCCESS)
		return ret;

	ret = CVI_ISP_MemInit(REPLAY_VI_PIPE);
	if (ret != CVI_SUCCESS)
		return ret;
	ret = CVI_ISP_SetPubAttr(REPLAY_VI_PIPE, &state.isp_pub_attr);
	if (ret != CVI_SUCCESS)
		return ret;
	ret = CVI_ISP_Init(REPLAY_VI_PIPE);
	if (ret != CVI_SUCCESS)
		return ret;
	state.isp_initialized = true;

	ret = SAMPLE_COMM_BIN_ReadParaFrombin();
	if (ret != CVI_SUCCESS)
		printf("offline replay platform: initial PQ load returned %#x; explicit replay PQ will follow\n",
			ret);

	ret = SAMPLE_COMM_ISP_Run(REPLAY_VI_PIPE);
	if (ret != CVI_SUCCESS)
		return ret;
	state.isp_running = true;

	return CVI_SUCCESS;
}

static void remember_error(CVI_S32 candidate, CVI_S32 *first_error)
{
	if (candidate != CVI_SUCCESS && *first_error == CVI_SUCCESS)
		*first_error = candidate;
}

CVI_S32 sc035hgs_replay_platform_init(SIZE_S *input_size,
	PIC_SIZE_E *sensor_pic_size)
{
	SAMPLE_INI_CFG_S ini_config = {0};
	VI_DEV_ATTR_S dev_attr = {0};
	VI_PIPE_ATTR_S pipe_attr = {0};
	VI_CHN_ATTR_S channel_attr = {0};
	CVI_S32 ret;

	if (input_size == NULL || sensor_pic_size == NULL || state.sys_initialized)
		return CVI_FAILURE;

	printf("offline replay platform: sensor and MIPI startup disabled\n");
	ret = SAMPLE_COMM_VI_ParseIni(&ini_config);
	if (ret != CVI_SUCCESS)
		return ret;
	if (ini_config.devNum != 1 ||
		ini_config.enSnsType[0] != SMS_SC035HGS_MIPI_480P_120FPS_12BIT) {
		printf("offline replay platform: expected one SC035HGS RAW12 sensor, got devs=%u type=%d\n",
			ini_config.devNum, ini_config.enSnsType[0]);
		return CVI_FAILURE;
	}

	ret = SAMPLE_COMM_VI_GetSizeBySensor(ini_config.enSnsType[0],
		&state.sensor_pic_size);
	if (ret != CVI_SUCCESS)
		return ret;
	ret = SAMPLE_COMM_SYS_GetPicSize(state.sensor_pic_size, &state.input_size);
	if (ret != CVI_SUCCESS)
		return ret;
	ret = SAMPLE_COMM_VI_GetDevAttrBySns(ini_config.enSnsType[0], &dev_attr);
	if (ret != CVI_SUCCESS)
		return ret;
	ret = SAMPLE_COMM_ISP_GetIspAttrBySns(ini_config.enSnsType[0],
		&state.isp_pub_attr);
	if (ret != CVI_SUCCESS)
		return ret;

	dev_attr.stWDRAttr.enWDRMode = ini_config.enWDRMode[0];
	dev_attr.snrFps = REPLAY_FPS;
	state.isp_pub_attr.enWDRMode = ini_config.enWDRMode[0];
	state.isp_pub_attr.f32FrameRate = REPLAY_FPS;
	if (dev_attr.stSize.u32Width != state.input_size.u32Width ||
		dev_attr.stSize.u32Height != state.input_size.u32Height ||
		state.isp_pub_attr.stSnsSize.u32Width != state.input_size.u32Width ||
		state.isp_pub_attr.stSnsSize.u32Height != state.input_size.u32Height) {
		printf("offline replay platform: inconsistent sensor-derived dimensions\n");
		return CVI_FAILURE;
	}

	ret = init_system(&state.input_size);
	if (ret != CVI_SUCCESS)
		return ret;
	state.sys_initialized = true;

	CVI_VI_SetDevNum(1);
	ret = configure_pipeline_modes();
	if (ret != CVI_SUCCESS)
		goto fail;

	ret = select_user_fe_source("for USER_FE geometry priming");
	if (ret != CVI_SUCCESS)
		goto fail;
	ret = configure_replay_timing();
	if (ret != CVI_SUCCESS)
		goto fail;
	ret = prime_user_fe_geometry();
	if (ret != CVI_SUCCESS)
		goto fail;

	ret = CVI_VI_SetDevAttr(REPLAY_VI_DEV, &dev_attr);
	if (ret != CVI_SUCCESS)
		goto fail;
	ret = configure_user_fe_source("before VI device enable");
	if (ret != CVI_SUCCESS)
		goto fail;
	ret = CVI_VI_EnableDev(REPLAY_VI_DEV);
	if (ret != CVI_SUCCESS)
		goto fail;
	state.dev_enabled = true;

	pipe_attr.bYuvSkip = CVI_FALSE;
	pipe_attr.u32MaxW = state.input_size.u32Width;
	pipe_attr.u32MaxH = state.input_size.u32Height;
	pipe_attr.enPixFmt = PIXEL_FORMAT_RGB_BAYER_12BPP;
	pipe_attr.enBitWidth = DATA_BITWIDTH_12;
	pipe_attr.stFrameRate.s32SrcFrameRate = -1;
	pipe_attr.stFrameRate.s32DstFrameRate = -1;
	pipe_attr.bNrEn = CVI_TRUE;
	pipe_attr.enCompressMode = COMPRESS_MODE_NONE;
	pipe_attr.bYuvBypassPath = CVI_FALSE;
	ret = CVI_VI_CreatePipe(REPLAY_VI_PIPE, &pipe_attr);
	if (ret != CVI_SUCCESS)
		goto fail;
	state.pipe_created = true;
	ret = configure_user_fe_source("after VI pipe creation");
	if (ret != CVI_SUCCESS)
		goto fail;
	ret = CVI_VI_StartPipe(REPLAY_VI_PIPE);
	if (ret != CVI_SUCCESS)
		goto fail;
	state.pipe_started = true;

	ret = start_isp();
	if (ret != CVI_SUCCESS)
		goto fail;

	ret = SAMPLE_COMM_VI_GetChnAttrBySns(ini_config.enSnsType[0],
		&channel_attr);
	if (ret != CVI_SUCCESS)
		goto fail;
	channel_attr.enPixelFormat = VI_PIXEL_FORMAT;
	channel_attr.enDynamicRange = ini_config.enWDRMode[0] == WDR_MODE_NONE ?
		DYNAMIC_RANGE_SDR10 : DYNAMIC_RANGE_HDR10;
	channel_attr.enVideoFormat = VIDEO_FORMAT_LINEAR;
	channel_attr.enCompressMode = COMPRESS_MODE_NONE;
	channel_attr.bMirror = CVI_FALSE;
	channel_attr.bFlip = CVI_FALSE;
	ret = CVI_VI_SetChnAttr(REPLAY_VI_PIPE, REPLAY_VI_CHN, &channel_attr);
	if (ret != CVI_SUCCESS)
		goto fail;
	ret = CVI_VI_EnableChn(REPLAY_VI_PIPE, REPLAY_VI_CHN);
	if (ret != CVI_SUCCESS)
		goto fail;
	state.channel_enabled = true;

	*input_size = state.input_size;
	*sensor_pic_size = state.sensor_pic_size;
	printf("offline replay platform: ready %ux%u bayer=%d wdr=%d fps=%d\n",
		state.input_size.u32Width, state.input_size.u32Height,
		state.isp_pub_attr.enBayer, state.isp_pub_attr.enWDRMode, REPLAY_FPS);
	return CVI_SUCCESS;

fail:
	sc035hgs_replay_platform_deinit();
	return ret;
}

CVI_S32 sc035hgs_replay_platform_validate_raw(const RAW_REPLAY_INFO *raw_info)
{
	CVI_BOOL expected_wdr;

	if (raw_info == NULL || !state.sys_initialized)
		return CVI_FAILURE;
	expected_wdr = state.isp_pub_attr.enWDRMode == WDR_MODE_NONE ?
		CVI_FALSE : CVI_TRUE;
	if (raw_info->width != (CVI_S32)state.input_size.u32Width ||
		raw_info->height != (CVI_S32)state.input_size.u32Height ||
		raw_info->bayerID != (CVI_S32)state.isp_pub_attr.enBayer ||
		!!raw_info->enWDR != !!expected_wdr) {
		printf("offline replay platform: RAW mismatch raw=%dx%d bayer=%d wdr=%d expected=%ux%u bayer=%d wdr=%d\n",
			raw_info->width, raw_info->height, raw_info->bayerID,
			raw_info->enWDR, state.input_size.u32Width,
			state.input_size.u32Height, state.isp_pub_attr.enBayer,
			expected_wdr);
		return CVI_FAILURE;
	}
	printf("RAW metadata matches offline platform\n");
	return CVI_SUCCESS;
}

CVI_S32 sc035hgs_replay_platform_deinit(void)
{
	CVI_S32 first_error = CVI_SUCCESS;
	CVI_S32 ret;

	if (state.channel_enabled) {
		ret = CVI_VI_DisableChn(REPLAY_VI_PIPE, REPLAY_VI_CHN);
		remember_error(ret, &first_error);
		state.channel_enabled = false;
	}

	if (state.isp_running) {
		SAMPLE_COMM_ISP_Stop(REPLAY_VI_PIPE);
		state.isp_running = false;
		state.isp_initialized = false;
		state.ae_registered = false;
		state.awb_registered = false;
	} else {
		if (state.isp_initialized) {
			ret = CVI_ISP_Exit(REPLAY_VI_PIPE);
			remember_error(ret, &first_error);
			state.isp_initialized = false;
		}
		if (state.awb_registered) {
			ret = SAMPLE_COMM_ISP_Awblib_UnCallback(REPLAY_VI_PIPE);
			remember_error(ret, &first_error);
			state.awb_registered = false;
		}
		if (state.ae_registered) {
			ret = SAMPLE_COMM_ISP_Aelib_UnCallback(REPLAY_VI_PIPE);
			remember_error(ret, &first_error);
			state.ae_registered = false;
		}
	}

	if (state.pipe_started) {
		ret = CVI_VI_StopPipe(REPLAY_VI_PIPE);
		remember_error(ret, &first_error);
		state.pipe_started = false;
	}
	if (state.pipe_created) {
		ret = CVI_VI_DestroyPipe(REPLAY_VI_PIPE);
		remember_error(ret, &first_error);
		state.pipe_created = false;
	}
	if (state.dev_enabled) {
		ret = CVI_VI_DisableDev(REPLAY_VI_DEV);
		remember_error(ret, &first_error);
		state.dev_enabled = false;
	}
	if (state.sys_initialized) {
		SAMPLE_COMM_SYS_Exit();
		state.sys_initialized = false;
	}

	memset(&state, 0, sizeof(state));
	printf("offline replay platform: teardown complete, ret=%#x\n", first_error);
	return first_error;
}
