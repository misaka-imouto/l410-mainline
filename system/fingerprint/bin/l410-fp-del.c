// SPDX-License-Identifier: GPL-2.0
/*
 * l410-fp-del - list/delete fingerprint templates stored by the vendor HAL.
 *
 * The Huawei daemon (com.huawei.Fingerprint) exposes no delete or list method:
 * its D-Bus interface is only StartSession/DeviceProperties/ClearPovImage/
 * SearchDevice/GetStatus/Close/Reload/Enroll/Identify/IdentifyWithMultipleUser,
 * and Reload(int) merely refreshes the template db.  The templates live inside
 * the TEE; deleting the files under /data/sec_storage_data is undone on the
 * next daemon start (they are re-materialised from the TEE with their original
 * mtime).
 *
 * The delete path exists one level down, in the vendor HAL library
 * (libhwFingerprint.so): CommonDriverDeleteFp / Device_Delete_Fingerprint call
 * fpc_tac_send_delete_fingerprint_set(), i.e. a TA command.  This tool loads
 * that library with dlopen() and drives the same entry points, emulating what
 * UOS's control centre does over the Android HAL/binder interface.
 *
 * Usage (the vendor daemon must be stopped so the tool can own the TA session):
 *
 *   sudo systemctl stop hwfp_init
 *   sudo LD_LIBRARY_PATH=/opt/uos-fp/lib l410-fp-del --list
 *   sudo LD_LIBRARY_PATH=/opt/uos-fp/lib l410-fp-del --delete <id>
 *   sudo systemctl start hwfp_init
 *
 * Afterwards verify with (no finger needed):
 *
 *   sudo grep -a primary_indices_count /var/log/fp_kirin/fp_hal.log | tail -1
 *
 * WARNING: the entry points are reverse engineered from symbols, not from
 * Huawei headers.  --list is read-only; --delete calls a TA command and a
 * wrong argument may wipe the whole template database.  Back up
 * /data/sec_storage_data before using --delete, and only run it with the
 * machine owner present (they may have to re-enrol).
 */
#include <dlfcn.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define LIBHW "libhwFingerprint.so"

typedef int (*init_fn)(void *);
typedef int (*get_num_fn)(const char *, int *);
typedef int (*get_list_fn)(const char *, void *);
typedef int (*delete_fn)(const char *, int *);

static void *sym(void *h, const char *name)
{
	void *p = dlsym(h, name);

	if (!p)
		fprintf(stderr, "warning: %s not exported by %s\n", name, LIBHW);
	return p;
}

int main(int argc, char **argv)
{
	void *h;
	init_fn init;
	get_num_fn get_num;
	get_list_fn get_list;
	delete_fn del;
	const char *account = "zhtsg";
	int ret, num = -1;
	int do_list = 0, do_delete = 0, del_id = -1;

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--list")) {
			do_list = 1;
		} else if (!strcmp(argv[i], "--delete") && i + 1 < argc) {
			do_delete = 1;
			del_id = atoi(argv[++i]);
		} else if (!strcmp(argv[i], "--account") && i + 1 < argc) {
			account = argv[++i];
		} else {
			fprintf(stderr,
				"usage: %s [--account USER] --list | --delete ID\n",
				argv[0]);
			return 2;
		}
	}
	if (!do_list && !do_delete) {
		fprintf(stderr, "nothing to do: pass --list or --delete <id>\n");
		return 2;
	}

	h = dlopen(LIBHW, RTLD_NOW);
	if (!h) {
		fprintf(stderr, "cannot dlopen %s: %s\n", LIBHW, dlerror());
		fprintf(stderr, "hint: LD_LIBRARY_PATH=/opt/uos-fp/lib\n");
		return 1;
	}

	init = (init_fn)sym(h, "CommonInitFingerprint");
	get_num = (get_num_fn)sym(h, "CommonDriverGetFpNum");
	get_list = (get_list_fn)sym(h, "CommonDriverGetFpList");
	del = (delete_fn)sym(h, "CommonDriverDeleteFp");
	if (!init || !get_num || !del) {
		fprintf(stderr, "required HAL entry points missing\n");
		return 1;
	}

	/*
	 * CommonInitFingerprint() takes a pointer to a caller-owned struct (it
	 * writes the struct size there).  32 bytes is what the HAL itself
	 * allocates internally; zeroed memory keeps it predictable.
	 */
	unsigned char init_buf[32] = { 0 };

	ret = init(init_buf);
	printf("CommonInitFingerprint -> %d\n", ret);

	ret = get_num(account, &num);
	printf("CommonDriverGetFpNum(%s) -> %d, num=%d\n", account, ret, num);

	if (do_list) {
		/* Layout of the list entries is unknown; print the raw buffer. */
		unsigned char list[4096] = { 0 };

		if (get_list) {
			ret = get_list(account, list);
			printf("CommonDriverGetFpList(%s) -> %d\n", account, ret);
			printf("raw:");
			for (size_t i = 0; i < sizeof(list) && (i < 128); i++)
				printf(" %02x", list[i]);
			printf("\n");
		}
	}

	if (do_delete) {
		int id = del_id;

		if (del_id < 0) {
			fprintf(stderr, "refusing to delete without a valid id\n");
			return 2;
		}
		ret = del(account, &id);
		printf("CommonDriverDeleteFp(%s, %d) -> %d\n", account, id, ret);
	}

	return 0;
}
