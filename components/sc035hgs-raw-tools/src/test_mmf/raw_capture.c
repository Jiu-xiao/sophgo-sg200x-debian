#include "raw_capture.h"

#include <dirent.h>
#include <errno.h>
#include <limits.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "cvi_vi.h"
#include "raw_dump_internal.h"

#define RAW_CAPTURE_ROOT "/mnt/data/raw"
#define RAW_CAPTURE_DIRECTORY_MAX 400U

static bool has_suffix(const char *text, const char *suffix)
{
	size_t text_length = strlen(text);
	size_t suffix_length = strlen(suffix);

	return text_length >= suffix_length &&
	       !strcmp(text + text_length - suffix_length, suffix);
}

static int require_empty_directory(const char *path)
{
	struct dirent *entry;
	DIR *directory = opendir(path);
	int ret = 0;

	if (!directory)
		return -errno;
	errno = 0;
	while ((entry = readdir(directory))) {
		if (strcmp(entry->d_name, ".") && strcmp(entry->d_name, "..")) {
			ret = -ENOTEMPTY;
			break;
		}
	}
	if (!ret && errno)
		ret = -errno;
	if (closedir(directory) && !ret)
		ret = -errno;
	return ret;
}

static int canonical_capture_directory(const char *path, char *resolved,
				       size_t resolved_size)
{
	struct stat status;
	size_t root_length = strlen(RAW_CAPTURE_ROOT);

	if (!path || !resolved || resolved_size < PATH_MAX || path[0] != '/' ||
	    strlen(path) >= RAW_CAPTURE_DIRECTORY_MAX)
		return -EINVAL;
	if (!realpath(path, resolved))
		return -errno;
	if (strlen(resolved) >= RAW_CAPTURE_DIRECTORY_MAX)
		return -ENAMETOOLONG;
	if (strncmp(resolved, RAW_CAPTURE_ROOT, root_length) ||
	    (resolved[root_length] && resolved[root_length] != '/'))
		return -EPERM;
	if (stat(resolved, &status))
		return -errno;
	if (!S_ISDIR(status.st_mode))
		return -ENOTDIR;
	if (access(resolved, W_OK))
		return -errno;
	return require_empty_directory(resolved);
}

static int require_nonempty_file(const char *path)
{
	struct stat status;

	if (stat(path, &status))
		return -errno;
	return S_ISREG(status.st_mode) && status.st_size > 0 ? 0 : -EIO;
}

static int find_capture_prefix(const char *directory, char *prefix,
			       size_t prefix_size)
{
	struct dirent *entry;
	char raw_path[MAIXCAM_RAW_CAPTURE_PATH_SIZE];
	char companion_path[MAIXCAM_RAW_CAPTURE_PATH_SIZE];
	DIR *stream = opendir(directory);
	int raw_count = 0;
	int ret = 0;

	if (!stream)
		return -errno;
	errno = 0;
	while ((entry = readdir(stream))) {
		size_t name_length;
		int length;

		if (!has_suffix(entry->d_name, ".raw"))
			continue;
		if (++raw_count != 1) {
			ret = -EEXIST;
			break;
		}
		name_length = strlen(entry->d_name) - strlen(".raw");
		length = snprintf(prefix, prefix_size, "%s/%.*s", directory,
				  (int)name_length, entry->d_name);
		if (length < 0 || (size_t)length >= prefix_size) {
			ret = -ENAMETOOLONG;
			break;
		}
		length = snprintf(raw_path, sizeof(raw_path), "%s.raw", prefix);
		if (length < 0 || (size_t)length >= sizeof(raw_path)) {
			ret = -ENAMETOOLONG;
			break;
		}
	}
	if (!ret && errno)
		ret = -errno;
	if (closedir(stream) && !ret)
		ret = -errno;
	if (ret)
		return ret;
	if (raw_count != 1)
		return -ENOENT;
	if (require_nonempty_file(raw_path))
		return -EIO;

	for (size_t i = 0; i < 2; ++i) {
		const char *suffix = i ? ".json" : ".txt";
		int length = snprintf(companion_path, sizeof(companion_path),
				      "%s%s", prefix, suffix);

		if (length < 0 || (size_t)length >= sizeof(companion_path) ||
		    require_nonempty_file(companion_path))
			return -EIO;
	}
	return 0;
}

int maixcam_raw_capture(int isp_pipe, const char *output_directory,
			char *captured_prefix, size_t captured_prefix_size)
{
	RAW_DUMP_INFO_S dump_info;
	char resolved[PATH_MAX];
	int ret;

	if (!captured_prefix || !captured_prefix_size)
		return -EINVAL;
	captured_prefix[0] = '\0';
	ret = canonical_capture_directory(output_directory, resolved,
					  sizeof(resolved));
	if (ret)
		return ret;

	memset(&dump_info, 0, sizeof(dump_info));
	dump_info.pathPrefix = resolved;
	dump_info.u32TotalFrameCnt = 1;
	if (cvi_raw_dump(isp_pipe, &dump_info) != CVI_SUCCESS)
		return -EIO;
	return find_capture_prefix(resolved, captured_prefix,
				   captured_prefix_size);
}
