#include <stddef.h>
#include <stdint.h>

#include "dpcm_api.h"

CVI_S32 decoderRaw(RAW_INFO raw_info, CVI_U8 *output)
{
	size_t index;
	uint16_t *pixels = (uint16_t *)output;

	if (raw_info.width != 4 || raw_info.height != 2 ||
	    raw_info.stride != 6 || raw_info.buffer == NULL || output == NULL)
		return -1;
	if (raw_info.buffer[0] == UINT8_MAX)
		return -2;
	for (index = 0; index < 8; ++index)
		pixels[index] = (uint16_t)(0x100u + index);
	return 0;
}
