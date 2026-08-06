#ifndef MAIXCAM_RAW_CAPTURE_H
#define MAIXCAM_RAW_CAPTURE_H

#include <stddef.h>

#define MAIXCAM_RAW_CAPTURE_PATH_SIZE 512U

int maixcam_raw_capture(int isp_pipe, const char *output_directory,
			char *captured_prefix, size_t captured_prefix_size);

#endif
