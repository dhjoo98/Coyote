/*
 * Copyright (c) 2025,  Systems Group, ETH Zurich
 * All rights reserved.
 *
 * This file is part of the Coyote device driver for Linux.
 * Coyote can be found at: https://github.com/fpgasystems/Coyote
 *
 * This source code is free software; you can redistribute it and/or modify it
 * under the terms and conditions of the GNU General Public License,
 * version 2, as published by the Free Software Foundation.
 *
 * This program is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
 * more details.
 *
 * The full GNU General Public License is included in this distribution in
 * the file called "COPYING". If not found, a copy of the GNU General Public
 * License can be found <https://www.gnu.org/licenses/>.
 */

#include "reconfig_ops.h"

int reconfig_dev_open(struct inode *inode, struct file *file) {
    // Parse inode arg into reconfig_dev struct and check it's non-null (BUG_ON)
    int minor = iminor(inode);
    struct reconfig_dev *device = container_of(inode->i_cdev, struct reconfig_dev, cdev);
    BUG_ON(!device);

    // Set file private data, so the attributes of the opened reconfig_dev can be accessed in other methods
    file->private_data = (void *) device;

    #ifdef PLATFORM_VERSAL
        pr_warn("Reconfiguration currently not supported on Versal devices.");
        return 1;
    #endif

    dbg_info("reconfiguration device %d acquired, pid %d\n", minor, current->pid);
    return 0;
}

int reconfig_dev_release(struct inode *inode, struct file *file) {
    // The release method for reconfig_dev is largely obsolete
    // Since `open` did not allocate any dynamic memory or interact with hardware
    // Therefore, we simply check that the device is non-null with BUG_ON
    int minor = iminor(inode);
    struct reconfig_dev *device = container_of(inode->i_cdev, struct reconfig_dev, cdev);
    BUG_ON(!device);

    dbg_info("reconfiguration device %d released, pid %d\n", minor, current->pid);
    return 0;
}

long reconfig_dev_ioctl(struct file *file, unsigned int command, unsigned long arg) {
    int ret_val = 0;

    // Parse device attributes and PCIe driver data
    struct reconfig_dev *device = (struct reconfig_dev *) file->private_data;
    BUG_ON(!device);
    struct bus_driver_data *bus_data = device->bd_data;
    BUG_ON(!bus_data);

    // Array of arguments passed from/back to user-space; number of arguments depends on IOCTL call
    unsigned long tmp[MAX_USER_ARGS];

    switch (command) {
        // Host-side memory allocation to hold bitstreams
        // Args: n_pages, host PID, configuration ID (crid)
        case IOCTL_ALLOC_HOST_RECONFIG_MEM:
            ret_val = copy_from_user(&tmp, (unsigned long *) arg, 3 * sizeof(unsigned long));
            if (ret_val != 0) {
                pr_warn("user data could not be coppied, return %d\n", ret_val);
            } else {
                ret_val = alloc_reconfig_buffer(device, tmp[0], tmp[1], tmp[2]);
                if (ret_val != 0) {
                    pr_warn("reconfig buffers could not be allocated, return %d\n", ret_val);
                } else {
                    dbg_info("allocated reconfig buffers, n_pages %d\n", device->curr_buff.n_pages);
                }
            }
            break;

        // Release host-side memory for bitstream
        // Args: virtual address, host PID, configuration ID (crid)
        case IOCTL_FREE_HOST_RECONFIG_MEM:
            ret_val = copy_from_user(&tmp, (unsigned long *) arg, 3 * sizeof(unsigned long));
            if (ret_val != 0) {
                pr_warn("user data could not be coppied, return %d\n", ret_val);
            }
            else {
                // NOTE: free_reconfig_buffer always returns zero; hence no error handling
                ret_val = free_reconfig_buffer(device, tmp[0], tmp[1], tmp[2]);
                dbg_info("reconfig buffer freed, virtual address 0x%lx\n", tmp[0]);
            }
            break;

        // Reconfigure shell
        // Args: bitstream virtual address, buffer length, host PID, configuration ID (crid)
        case IOCTL_RECONFIGURE_SHELL:
            ret_val = copy_from_user(&tmp, (unsigned long *)arg, 4 * sizeof(unsigned long));
            if (ret_val != 0) {
                pr_warn("user data could not be coppied, return %d\n", ret_val);
            } else {
                dbg_info("starting shell reconfiguration, pid %d\n", current->pid);
                uint64_t start_time = ktime_get_ns();

                // Lock mutex, to avoid multiple reconfigurations at the same time
                mutex_lock(&device->rcnfg_lock);

                // Clean up current shell state
                shell_pci_remove(bus_data);

                // Decouple
                bus_data->stat_cnfg->reconfig_dcpl_set = 0x1;

                // Reconfigure and wait until completion
                ret_val = reconfigure_start(device, tmp[0], tmp[1], tmp[2], tmp[3]);
                if (ret_val != 0) {
                    pr_warn("shell reconfiguration not successful, return %d\n", ret_val);
                    return -1;
                }

                wait_event_interruptible(device->waitqueue_rcnfg, atomic_read(&device->wait_rcnfg) == FLAG_SET);
                atomic_set(&device->wait_rcnfg, FLAG_CLR);

                // Reset end-of-start up time (active-low)
                bus_data->stat_cnfg->reconfig_eost_reset = 0x0;
                bus_data->stat_cnfg->reconfig_eost_reset = 0x1;

                // Couple and re-init the shell, unlock mutex
                dbg_info("shell reconfiguration complete, coupling the design and unlocking mutex\n");
                bus_data->stat_cnfg->reconfig_dcpl_clr = 0x1;
                shell_pci_init(bus_data);
                mutex_unlock(&device->rcnfg_lock);

                uint64_t stop_time = ktime_get_ns();
                dbg_info("shell reconfiguration time %llu ms\n", (stop_time - start_time) / (1000 * 1000));
            }
            break;

        // Reconfigure app
        // Args: virtual address, buffer length, host PID, configuration ID (crid), vFPGA ID
        case IOCTL_RECONFIGURE_APP:
            ret_val = copy_from_user(&tmp, (unsigned long *) arg, 5 * sizeof(unsigned long));
            if (ret_val != 0) {
                pr_warn("user data could not be coppied, return %d\n", ret_val);
            } else {
                dbg_info("trying to obtain reconfig lock, pid %d\n", current->pid);

                // Lock mutex, to avoid multiple reconfigurations at the same time
                mutex_lock(&device->rcnfg_lock);

                // Decouple
                bus_data->shell_cnfg->reconfig_dcpl_app_set = (1 << (uint32_t) tmp[4]);

                // Diagnostic snapshot of BPSS AXI-level counters before PR.
                // NOTE: these are AXI handshake counts (user-logic ↔ BPSS), NOT PCIe completion
                // counts. After large HBM loads the H2C delta stays non-zero permanently because
                // the HBM load path does not send per-transfer completions back through BPSS.
                // The design has been verified to complete HBM offloads correctly in the static
                // shell, so we log only and do not poll/wait.
                dbg_info("pre-PR BPSS stats: ch0 h2c req=%u cmpl=%u (delta=%d), c2h req=%u cmpl=%u (delta=%d) | ch1 h2c req=%u cmpl=%u (delta=%d), c2h req=%u cmpl=%u (delta=%d)\n",
                         (uint32_t)(bus_data->shell_cnfg->hdma_debug[0]),
                         (uint32_t)(bus_data->shell_cnfg->hdma_debug[1]),
                         (int)((uint32_t)(bus_data->shell_cnfg->hdma_debug[0]) - (uint32_t)(bus_data->shell_cnfg->hdma_debug[1])),
                         (uint32_t)(bus_data->shell_cnfg->hdma_debug[0] >> 32),
                         (uint32_t)(bus_data->shell_cnfg->hdma_debug[1] >> 32),
                         (int)((uint32_t)(bus_data->shell_cnfg->hdma_debug[0] >> 32) - (uint32_t)(bus_data->shell_cnfg->hdma_debug[1] >> 32)),
                         (uint32_t)(bus_data->shell_cnfg->hdma_debug[3]),
                         (uint32_t)(bus_data->shell_cnfg->hdma_debug[4]),
                         (int)((uint32_t)(bus_data->shell_cnfg->hdma_debug[3]) - (uint32_t)(bus_data->shell_cnfg->hdma_debug[4])),
                         (uint32_t)(bus_data->shell_cnfg->hdma_debug[3] >> 32),
                         (uint32_t)(bus_data->shell_cnfg->hdma_debug[4] >> 32),
                         (int)((uint32_t)(bus_data->shell_cnfg->hdma_debug[3] >> 32) - (uint32_t)(bus_data->shell_cnfg->hdma_debug[4] >> 32)));

                // Reconfigure and wait until completion
                uint64_t start_time = ktime_get_ns();
                ret_val = reconfigure_start(device, tmp[0], tmp[1], tmp[2], tmp[3]);
                if (ret_val != 0) {
                    pr_warn("app reconfiguration not successful, return %d\n", ret_val);
                    return -1;
                }

                wait_event_interruptible(device->waitqueue_rcnfg, atomic_read(&device->wait_rcnfg) == FLAG_SET);
                uint64_t stop_time = ktime_get_ns();
                dbg_info("app reconfiguration time %llu ms\n", (stop_time - start_time) / (1000 * 1000));
                atomic_set(&device->wait_rcnfg, FLAG_CLR);

                // Couple and unlock mutex
                dbg_info("app reconfiguration complete, coupling the design and unlocking mutex\n");
                bus_data->shell_cnfg->reconfig_dcpl_app_clr = (1 << (uint32_t)tmp[4]);
                mutex_unlock(&device->rcnfg_lock);
            }
            break;

        // Read PR config
        // Return: partial reconfiguration (EN_PR) enabled or not
        case IOCTL_PR_CNFG:
            tmp[0] = (uint64_t) bus_data->en_pr;
            dbg_info("reading PR config 0x%lx\n", tmp[0]);
            ret_val = copy_to_user((unsigned long *) arg, &tmp, sizeof(unsigned long));
            if (ret_val != 0) {
                pr_warn("could not copy data to user space, return %d\n", ret_val);
            }
            break;

        // Read PR and writeback stats
        // Return: Number of DMA requests, completions and data beats on the PR & WB channel
        case IOCTL_PR_WB_STATS:
            dbg_info("retrieving PR & WB stats from the static layer");
            for (int i = 0; i < N_HDMA_STAT_CH_REGS; i++) {
                tmp[i] = bus_data->stat_cnfg->hdma_debug[i];
            }
            ret_val = copy_to_user((unsigned long *) arg, &tmp, N_HDMA_STAT_CH_REGS * sizeof(unsigned long));
            if (ret_val != 0) {
                pr_warn("could not copy data to user space, return %d\n", ret_val);
            }
            break;

        default:
            dbg_info("reconfig device received unknown IOCTL call %d", command);
            ret_val = 1;
            break;
    }

    return ret_val;
}

int reconfig_dev_mmap(struct file *file, struct vm_area_struct *vma) {
    // Parse device attributes
    struct reconfig_dev *device = (struct reconfig_dev *) file->private_data;
    BUG_ON(!device);
    uint64_t page_size = device->bd_data->ltlb_meta->page_size;
    uint64_t page_shift = device->bd_data->ltlb_meta->page_shift;

    // Map previously allocated reconfiguration buffers to user-space
    // Buffers must have been allocated using IOCTL_ALLOC_HOST_RECONFIG_MEM
    vma->vm_page_prot = pgprot_noncached(vma->vm_page_prot);
    if (vma->vm_pgoff == MMAP_RECONFIG) {
        dbg_info("reconfig device, starting mmap\n");

        // Align virtual address (vma->vm_start) to page boundary
        uint64_t vaddr = ((vma->vm_start + page_size - 1) >> page_shift) << page_shift;

        // Check pages have been allocated and the current process was the one that allocated them
        if (device->curr_buff.n_pages != 0 && device->curr_buff.pid == current->pid) {
            spin_lock(&device->mem_lock);

            // Store metadata about the recently allocated buffer to the map (reconfig_buffs_map)
            struct reconfig_buff_metadata *new_buff = kzalloc(sizeof(struct reconfig_buff_metadata), GFP_KERNEL);
            BUG_ON(!new_buff);
            new_buff->vaddr = vaddr;
            new_buff->pid = current->pid;
            new_buff->crid = device->curr_buff.crid;
            new_buff->n_pages = device->curr_buff.n_pages;
            new_buff->pages = device->curr_buff.pages;

            // FIX: DMA-map each page to obtain an IOMMU-aware address (IOVA).
            // page_to_phys() returns the CPU physical address, which is incorrect when an IOMMU
            // (e.g., AMD-Vi) is active. The FPGA DMA engine must use the IOVA returned by
            // dma_map_page() so that transactions are correctly translated by the IOMMU.
            // This mirrors the approach already used in vfpga_gup.c for user data buffers.
            // DMA mapping is done here (at mmap time) rather than at alloc time so that
            // the mapping reflects the correct IOVA range after the DMA mask has been set.
            new_buff->dma_addrs = vmalloc(new_buff->n_pages * sizeof(dma_addr_t));
            if (!new_buff->dma_addrs) {
                pr_warn("failed to allocate DMA address array for reconfig buffer\n");
                kfree(new_buff);
                spin_unlock(&device->mem_lock);
                return -ENOMEM;
            }

            for (int i = 0; i < new_buff->n_pages; i++) {
                new_buff->dma_addrs[i] = dma_map_page(
                    &device->bd_data->pci_dev->dev,
                    new_buff->pages[i],
                    0,
                    page_size,
                    DMA_TO_DEVICE
                );
                if (dma_mapping_error(&device->bd_data->pci_dev->dev, new_buff->dma_addrs[i])) {
                    pr_warn("failed to DMA-map reconfig page %d\n", i);
                    for (int j = 0; j < i; j++) {
                        dma_unmap_page(&device->bd_data->pci_dev->dev,
                                       new_buff->dma_addrs[j], page_size, DMA_TO_DEVICE);
                    }
                    vfree(new_buff->dma_addrs);
                    kfree(new_buff);
                    spin_unlock(&device->mem_lock);
                    return -EIO;
                }
            }

            hash_add(reconfig_buffs_map, &new_buff->entry, vaddr);

            // Remap each page to user-space
            uint64_t virtual_address_tmp = vaddr;
            for (int i = 0; i < new_buff->n_pages; i++) {
                if (remap_pfn_range(
                        vma, virtual_address_tmp,
                        page_to_pfn(device->curr_buff.pages[i]), page_size, vma->vm_page_prot)
                    ) {
                        pr_warn("failed to remap, virtual address 0x%llx\n", virtual_address_tmp);
                        return -EIO;
                    }
                virtual_address_tmp += page_size;
            }

            // Mark current buff as empty, to allow future mmaps (see first if in this function)
            device->curr_buff.n_pages = 0;

            spin_unlock(&device->mem_lock);
            dbg_info("reconfig device, completed mmap\n");
            return 0;
        }
    }

    return -EINVAL;
}
