#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "dpcm_api.h"

static void usage(const char *program)
{
	fprintf(stderr,
		"Usage: %s INPUT.raw WIDTH HEIGHT OUTPUT.raw16le\n",
		program);
}

static int parse_dimension(const char *text, const char *name, uint32_t *value)
{
	char *end = NULL;
	uintmax_t parsed;

	errno = 0;
	parsed = strtoumax(text, &end, 10);
	if (errno != 0 || end == text || *end != '\0' || parsed == 0 ||
	    parsed > UINT32_MAX) {
		fprintf(stderr, "invalid %s: %s\n", name, text);
		return -1;
	}
	*value = (uint32_t)parsed;
	return 0;
}

static int read_all(int fd, uint8_t *buffer, size_t size)
{
	size_t offset = 0;

	while (offset < size) {
		size_t chunk = size - offset;
		ssize_t count;

		if (chunk > (size_t)SSIZE_MAX)
			chunk = (size_t)SSIZE_MAX;
		count = read(fd, buffer + offset, chunk);

		if (count < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
		if (count == 0) {
			errno = EIO;
			return -1;
		}
		offset += (size_t)count;
	}
	return 0;
}

static int write_all(int fd, const uint8_t *buffer, size_t size)
{
	size_t offset = 0;

	while (offset < size) {
		size_t chunk = size - offset;
		ssize_t count;

		if (chunk > (size_t)SSIZE_MAX)
			chunk = (size_t)SSIZE_MAX;
		count = write(fd, buffer + offset, chunk);

		if (count < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
		if (count == 0) {
			errno = EIO;
			return -1;
		}
		offset += (size_t)count;
	}
	return 0;
}

static void encode_little_endian(uint8_t *decoded, size_t pixel_count)
{
	size_t index;

	for (index = 0; index < pixel_count; ++index) {
		uint16_t value;

		memcpy(&value, decoded + index * sizeof(value), sizeof(value));
		decoded[index * 2] = (uint8_t)(value & 0xffu);
		decoded[index * 2 + 1] = (uint8_t)(value >> 8);
	}
}

int main(int argc, char **argv)
{
	struct stat input_stat;
	struct stat output_stat;
	uint32_t width;
	uint32_t height;
	uint32_t stride;
	size_t input_size;
	size_t pixel_count;
	size_t output_size;
	uint8_t *input = NULL;
	uint8_t *decoded = NULL;
	int input_fd = -1;
	int output_fd = -1;
	int status = EXIT_FAILURE;
	RAW_INFO raw_info;
	CVI_S32 decode_status;

	if (argc != 5) {
		usage(argv[0]);
		return 2;
	}
	if (parse_dimension(argv[2], "width", &width) != 0 ||
	    parse_dimension(argv[3], "height", &height) != 0)
		return 2;
	if ((size_t)width > SIZE_MAX / (size_t)height) {
		fprintf(stderr, "pixel count overflows the target size type\n");
		return 2;
	}
	pixel_count = (size_t)width * (size_t)height;
	if (pixel_count > SIZE_MAX / sizeof(uint16_t)) {
		fprintf(stderr, "decoded frame size overflows the target size type\n");
		return 2;
	}
	output_size = pixel_count * sizeof(uint16_t);

	input_fd = open(argv[1], O_RDONLY | O_CLOEXEC);
	if (input_fd < 0) {
		fprintf(stderr, "cannot open input %s: %s\n", argv[1], strerror(errno));
		goto done;
	}
	if (fstat(input_fd, &input_stat) != 0) {
		fprintf(stderr, "cannot stat input %s: %s\n", argv[1], strerror(errno));
		goto done;
	}
	if (!S_ISREG(input_stat.st_mode) || input_stat.st_size <= 0 ||
	    (uintmax_t)input_stat.st_size > SIZE_MAX) {
		fprintf(stderr, "input must be a non-empty regular file of supported size\n");
		goto done;
	}
	input_size = (size_t)input_stat.st_size;
	if (input_size % height != 0) {
		fprintf(stderr,
			"input size %zu is not divisible by height %" PRIu32 "\n",
			input_size, height);
		goto done;
	}
	if (input_size / height == 0 || input_size / height > UINT32_MAX) {
		fprintf(stderr, "compressed stride is outside the RAW_INFO range\n");
		goto done;
	}
	stride = (uint32_t)(input_size / height);

	if (stat(argv[4], &output_stat) == 0 &&
	    output_stat.st_dev == input_stat.st_dev &&
	    output_stat.st_ino == input_stat.st_ino) {
		fprintf(stderr, "input and output must be different files\n");
		goto done;
	}

	input = malloc(input_size);
	decoded = malloc(output_size);
	if (input == NULL || decoded == NULL) {
		fprintf(stderr, "cannot allocate input and decoded frame buffers\n");
		goto done;
	}
	if (read_all(input_fd, input, input_size) != 0) {
		fprintf(stderr, "cannot read input %s: %s\n", argv[1], strerror(errno));
		goto done;
	}

	raw_info.width = width;
	raw_info.height = height;
	raw_info.stride = stride;
	raw_info.buffer = input;
	decode_status = decoderRaw(raw_info, decoded);
	if (decode_status != 0) {
		fprintf(stderr, "decoderRaw failed with status %#" PRIx32 "\n",
			(uint32_t)decode_status);
		goto done;
	}
	encode_little_endian(decoded, pixel_count);

	output_fd = open(argv[4], O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
	if (output_fd < 0) {
		fprintf(stderr, "cannot open output %s: %s\n", argv[4], strerror(errno));
		goto done;
	}
	if (write_all(output_fd, decoded, output_size) != 0) {
		fprintf(stderr, "cannot write output %s: %s\n", argv[4], strerror(errno));
		goto done;
	}
	if (close(output_fd) != 0) {
		output_fd = -1;
		fprintf(stderr, "cannot close output %s: %s\n", argv[4], strerror(errno));
		goto done;
	}
	output_fd = -1;
	printf("decoded=%s width=%" PRIu32 " height=%" PRIu32
	       " stride=%" PRIu32 " output_bytes=%zu\n",
	       argv[1], width, height, stride, output_size);
	status = EXIT_SUCCESS;

done:
	if (output_fd >= 0)
		close(output_fd);
	if (input_fd >= 0)
		close(input_fd);
	free(decoded);
	free(input);
	return status;
}
