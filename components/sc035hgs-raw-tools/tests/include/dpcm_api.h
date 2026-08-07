#ifndef TEST_DPCM_API_H
#define TEST_DPCM_API_H

#include <stdint.h>

typedef uint8_t CVI_U8;
typedef uint32_t CVI_U32;
typedef int32_t CVI_S32;

typedef struct {
	CVI_U32 width;
	CVI_U32 height;
	CVI_U32 stride;
	CVI_U8 *buffer;
} RAW_INFO;

CVI_S32 decoderRaw(RAW_INFO raw_info, CVI_U8 *output);

#endif
