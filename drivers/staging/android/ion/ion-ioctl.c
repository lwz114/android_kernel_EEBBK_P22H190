/*
 *
 * Copyright (C) 2011 Google, Inc.
 *
 * This software is licensed under the terms of the GNU General Public
 * License version 2, as published by the Free Software Foundation, and
 * may be copied, distributed, and modified under those terms.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 */

#include <linux/kernel.h>
#include <linux/dma-buf.h>
#include <linux/file.h>
#include <linux/fs.h>
#include <linux/uaccess.h>

#include "ion.h"

/*
 * Modern Android (11+) ION allocation ioctl: gralloc4 submits the request
 * as a 24-byte structure (0xc0184900) that carries the fd it expects back.
 * The legacy ION_IOC_ALLOC wire format is identical (len/mask/flags/fd),
 * but expose an explicit alias so gralloc4's request is handled regardless
 * of which userspace header it was built against.
 */
struct ion_allocation_data_modern {
	__u64 len;
	__u32 heap_id_mask;
	__u32 flags;
	__u32 fd;
	__u32 unused;
};

#define ION_IOC_MODERN_ALLOC	_IOWR(ION_IOC_MAGIC, 0, \
				      struct ion_allocation_data_modern)

union ion_ioctl_arg {
	struct ion_allocation_data allocation;
	struct ion_heap_query query;
	struct ion_phy_data phy;
};

static int validate_ioctl_arg(unsigned int cmd, union ion_ioctl_arg *arg)
{
	int ret = 0;

	switch (cmd) {
	case ION_IOC_HEAP_QUERY:
		ret = arg->query.reserved0 != 0;
		ret |= arg->query.reserved1 != 0;
		ret |= arg->query.reserved2 != 0;
		break;
	default:
		break;
	}

	return ret ? -EINVAL : 0;
}

/* fix up the cases where the ioctl direction bits are incorrect */
static unsigned int ion_ioctl_dir(unsigned int cmd)
{
	switch (cmd) {
	default:
		return _IOC_DIR(cmd);
	}
}

long ion_ioctl(struct file *filp, unsigned int cmd, unsigned long arg)
{
	int ret = 0;
	unsigned int dir;
	union ion_ioctl_arg data;

	/*
	 * gralloc4 issues the allocation as the 24-byte modern ioctl
	 * (0xc0184900).  Its layout matches ion_allocation_data; handle it
	 * explicitly so the returned fd is written back into the caller's
	 * buffer exactly as gralloc4 expects, without disturbing the legacy
	 * ION_IOC_ALLOC / vendor-specific paths.
	 */
	if (cmd == ION_IOC_MODERN_ALLOC) {
		struct ion_allocation_data_modern modern_data;
		int fd;
		unsigned int mask;

		if (copy_from_user(&modern_data, (void __user *)arg,
				   sizeof(modern_data)))
			return -EFAULT;

		mask = modern_data.heap_id_mask;
		if (!mask || mask == (1U << 0))
			mask = (1U << 3);

		fd = ion_alloc(modern_data.len, mask, modern_data.flags);
		if (fd < 0)
			return fd;

		modern_data.fd = fd;
		if (copy_to_user((void __user *)arg, &modern_data,
				 sizeof(modern_data)))
			return -EFAULT;

		return 0;
	}

	dir = ion_ioctl_dir(cmd);

	if (_IOC_SIZE(cmd) > sizeof(data))
		return -EINVAL;

	/*
	 * The copy_from_user is unconditional here for both read and write
	 * to do the validate. If there is no write for the ioctl, the
	 * buffer is cleared
	 */
	if (copy_from_user(&data, (void __user *)arg, _IOC_SIZE(cmd)))
		return -EFAULT;

	ret = validate_ioctl_arg(cmd, &data);
	if (ret) {
		pr_warn_once("%s: ioctl validate failed\n", __func__);
		return ret;
	}

	if (!(dir & _IOC_WRITE))
		memset(&data, 0, sizeof(data));

	switch (cmd) {
	case ION_IOC_ALLOC:
	{
		int fd;

		fd = ion_alloc(data.allocation.len,
			       data.allocation.heap_id_mask,
			       data.allocation.flags);
		if (fd < 0)
			return fd;

		data.allocation.fd = fd;

		break;
	}
	case ION_IOC_PHY:
	{
		int fd = data.phy.fd;

		ret = ion_phys(fd, (unsigned long *)&data.phy.addr,
			      (size_t *)&data.phy.len);
		break;
	}
	case ION_IOC_HEAP_QUERY:
		ret = ion_query_heaps(&data.query);
		break;
	case ION_IOC_VERSION:
		break;
	default:
		return -ENOTTY;
	}

	if (dir & _IOC_READ) {
		if (copy_to_user((void __user *)arg, &data, _IOC_SIZE(cmd)))
			return -EFAULT;
	}
	return ret;
}
