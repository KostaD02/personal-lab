<h1>03. Storage Configuration</h1>

This guide covers the identification, partitioning, formatting, and persistent mounting of secondary storage drives. It ensures that data volumes remain available across reboots, providing a dedicated space for Docker volumes, backups, and large datasets at `/mnt/data`.

> [!IMPORTANT]
> **Single Drive Users**: If your server only has one physical drive (the boot SSD), you can skip this guide. You are already using your full capacity at the root partition `(/)`.

- [Drive Identification](#drive-identification)
  - [Locate the hardware](#locate-the-hardware)
- [Partitioning and Formatting](#partitioning-and-formatting)
  - [1. Create the Partition Table](#1-create-the-partition-table)
  - [2. Create the Partition](#2-create-the-partition)
  - [3. Wipe and Create the Filesystem](#3-wipe-and-create-the-filesystem)
  - [4. Verify the UUID](#4-verify-the-uuid)
- [Mount Point Creation](#mount-point-creation)
  - [Create the directory and Set Ownership](#create-the-directory-and-set-ownership)
- [Automated Mounting via FSTAB](#automated-mounting-via-fstab)
  - [Add the entry](#add-the-entry)
  - [Parameters Explained](#parameters-explained)
- [Test the configuration](#test-the-configuration)
  - [Verification](#verification)
- [Summary](#summary)

## Drive Identification

Before we can mount a drive, we must identify its hardware path. We use the UUID for persistent mounting because hardware paths (like `/dev/sdb`) can change if you swap SATA ports, whereas the UUID is baked into the partition itself.

### Locate the hardware

Run the following command to list all block devices:

```bash
lsblk
```

Look for the drive that matches the size of your secondary HDD. Identify the **NAME** (e.g., `sdb`).

## Partitioning and Formatting

If your drive is brand new or contains a non-Linux filesystem (like NTFS), you need to initialize it.

> [!CAUTION]
> These steps will permanently erase all data on the target drive. Verify the device name (e.g., `/dev/sdb`) multiple times!

### 1. Create the Partition Table

We use GPT because it's the modern standard for drives of any size.

```bash
sudo parted /dev/sdb mklabel gpt
```

### 2. Create the Partition

We will create a single partition using 100% of the drive's capacity.

```bash
sudo parted /dev/sdb mkpart primary ext4 0% 100%
```

### 3. Wipe and Create the Filesystem

Now we format the newly created partition (`/dev/sdb1`) to `ext4`. We also add a label (`DATA`) for easier identification.

```bash
sudo mkfs.ext4 -L "DATA" /dev/sdb1
```

### 4. Verify the UUID

Formatting generates a unique ID. Run the following to retrieve the new **UUID**:

```bash
lsblk -f
```

## Mount Point Creation

A drive must be attached to a directory to be accessible. We will use `/mnt/data`.

### Create the directory and Set Ownership

```bash
sudo mkdir -p /mnt/data
sudo chown $USER:$USER /mnt/data
```

> [!WARNING]
> Do not move files into `/mnt/data` until the drive is mounted. Anything written to this folder while the drive is unmounted will consume space on your primary SSD and become "invisible" once the HDD is attached.

## Automated Mounting via FSTAB

The `/etc/fstab` file tells the OS to mount the drive automatically at boot.

Open the configuration:

```bash
sudo vim /etc/fstab
```

### Add the entry

Add the following line to the end of the file, replacing the UUID with your own:

```
# /dev/sdb1

UUID=<YOUR_UUID> /mnt/data ext4 defaults,noatime,nofail 0 2
```

### Parameters Explained

| Option       | Description                                                                                  |
| :----------- | :------------------------------------------------------------------------------------------- |
| **defaults** | Standard options (rw, exec, etc.).                                                           |
| **noatime**  | Disables "last accessed" timestamps, reducing disk wear and improving performance.           |
| **nofail**   | **Crucial.** Prevents the system from hanging at boot if the drive is disconnected or fails. |
| **0 2**      | `0`: Disables dump backups. `2`: Sets the order for filesystem error checking.               |

## Test the configuration

> [!IMPORTANT]
> Never reboot immediately. A typo in `fstab` can break your boot process.

Reload the daemon and mount:

```bash
sudo systemctl daemon-reload
sudo mount -a
```

### Verification

Check the mount status and test write access:

```bash
df -h | grep /mnt/data
touch /mnt/data/test_write && rm /mnt/data/test_write
```

## Summary

By completing these steps, the server's storage capacity has been expanded from a single boot drive to a dual-volume system.

Have fun!
