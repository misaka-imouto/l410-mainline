/*
 * fp_poweron - deassert the fingerprint sensor reset before the daemon runs.
 *
 * The huawei-fingerprint driver probes with the reset GPIO held low and only
 * powers the sensor on through FP_IOC_CMD_SET_POWERON (0x660e).  The vendor
 * daemon normally issues it; doing it from systemd's ExecStartPre makes the
 * bring-up deterministic.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define FP_IOC_CMD_SET_POWERON 0x660e

int main(void)
{
	int fd = open("/dev/fingerprint", O_RDWR);
	int ret;

	if (fd < 0) {
		perror("open /dev/fingerprint");
		return 1;
	}
	ret = ioctl(fd, FP_IOC_CMD_SET_POWERON);
	if (ret < 0)
		fprintf(stderr, "SET_POWERON failed: %d\n", errno);
	close(fd);
	return ret < 0 ? 1 : 0;
}
