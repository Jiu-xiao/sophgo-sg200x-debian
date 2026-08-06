#ifndef SC035HGS_REPLAY_PLATFORM_H
#define SC035HGS_REPLAY_PLATFORM_H

#include "raw_replay.h"
#include "sample_comm.h"

CVI_S32 sc035hgs_replay_platform_init(SIZE_S *input_size,
	PIC_SIZE_E *sensor_pic_size);
CVI_S32 sc035hgs_replay_platform_validate_raw(const RAW_REPLAY_INFO *raw_info);
CVI_S32 sc035hgs_replay_platform_deinit(void);

#endif
