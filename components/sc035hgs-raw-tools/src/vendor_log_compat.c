#include <stddef.h>

#include <linux/cvi_common.h>

/* decoderRaw uses the cvi_debug globals normally owned by the SYS process. */
CVI_S32 *log_levels = NULL;
CVI_CHAR const *log_name[8] = {
	(CVI_CHAR *)"EMG", (CVI_CHAR *)"ALT", (CVI_CHAR *)"CRI", (CVI_CHAR *)"ERR",
	(CVI_CHAR *)"WRN", (CVI_CHAR *)"NOT", (CVI_CHAR *)"INF", (CVI_CHAR *)"DBG",
};
