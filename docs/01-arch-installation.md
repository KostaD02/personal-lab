<h1> 01. Arch Linux Installation </h1>

This guide covers the clean installation of Arch Linux on the primary drive, preparing it for a Docker-heavy workload.

- [Preparation of Installation Media](#preparation-of-installation-media)
  - [For Windows Users:](#for-windows-users)
  - [For Linux Users:](#for-linux-users)
- [Starting the Installation](#starting-the-installation)
  - [Initial Setup and Connectivity](#initial-setup-and-connectivity)
    - [1. Launch the utility:](#1-launch-the-utility)
    - [2. Find your device:](#2-find-your-device)
    - [3. Scan for networks:](#3-scan-for-networks)
    - [4. Connect to your network:](#4-connect-to-your-network)
    - [5. Exit from `iwctl`:](#5-exit-from-iwctl)
  - [Verify Internet Connection](#verify-internet-connection)
  - [Update System Clock](#update-system-clock)
  - [Choosing the Installation Path](#choosing-the-installation-path)
    - [1. Manual Installation (The Traditional Way)](#1-manual-installation-the-traditional-way)
    - [2. Guided Installation (The Easy Way)](#2-guided-installation-the-easy-way)
  - [Running the Guided Installer](#running-the-guided-installer)
  - [Configuration Menu Settings](#configuration-menu-settings)
    - [1. Archinstall language](#1-archinstall-language)
    - [2. Locales](#2-locales)
    - [3. Mirrors](#3-mirrors)
    - [4. Disk configuration -\> Partitioning](#4-disk-configuration---partitioning)
    - [5. Swap](#5-swap)
    - [6. Bootloader](#6-bootloader)
    - [7. Kernels](#7-kernels)
    - [8. Hostname](#8-hostname)
    - [9. Authentication](#9-authentication)
    - [10. Profile](#10-profile)
    - [11. Applications](#11-applications)
    - [12. Network manager](#12-network-manager)
    - [13. Additional packages](#13-additional-packages)
    - [14. Timezone](#14-timezone)
    - [15. Automatic time sync (NTP)](#15-automatic-time-sync-ntp)
  - [Install](#install)
  - [Post Installation Configurations](#post-installation-configurations)
    - [1. Enable core services](#1-enable-core-services)
    - [2. Grant user permissions](#2-grant-user-permissions)
    - [3. Check the Network Interface](#3-check-the-network-interface)
    - [4. Exit](#4-exit)
- [Post Installation](#post-installation)
- [Check Network Manager](#check-network-manager)
  - [Connect to Network](#connect-to-network)
  - [Find your assigned IP](#find-your-assigned-ip)
- [Configure Static IP Address](#configure-static-ip-address)
  - [Set Static IP Address](#set-static-ip-address)
  - [Apply new address](#apply-new-address)
- [Enable Remote Access (SSH)](#enable-remote-access-ssh)
- [Enable Docker Engine](#enable-docker-engine)
- [Check Service Persistence](#check-service-persistence)
- [Check SSH Connection](#check-ssh-connection)
- [Summary](#summary)

## Preparation of Installation Media

Before touching the server, you need to flash the Arch ISO to a USB drive (2GB minimum).

> [!CAUTION]
> All data on the USB drive will be erased.

### For Windows Users:

1. Download the Arch Linux ISO from the [official website](https://archlinux.org/download/#bittorrent-download).
2. Download [Rufus](https://rufus.ie/en/).
3. Insert a USB drive (minimum 2GB).
4. Open Rufus.
5. Select the Arch ISO.
6. Click 'Start'.
7. When the 'ISOHybrid image detected' prompt appears, select **Write in DD Image mode**.

> [!NOTE]
> Rufus recommends ISO mode, but for Arch, DD mode is the standard to avoid boot failures.

### For Linux Users:

TBD

## Starting the Installation

1. Insert the USB drive into the server.
2. Power on the server and enter the BIOS/UEFI settings.
3. Select the USB drive as the boot device.
4. Select Arch Linux install medium (x86_64, UEFI).
5. Wait for the system to boot into the live environment. You will be greeted by the `root@archiso` prompt.

### Initial Setup and Connectivity

If you are not using an Ethernet cable, use the `iwctl` utility to connect to your network.

#### 1. Launch the utility:

```bash
iwctl
```

#### 2. Find your device:

```bash
device list
```

#### 3. Scan for networks:

```bash
station wlan0 scan
station wlan0 get-networks
```

#### 4. Connect to your network:

```bash
station wlan0 connect <Your-SSID>
```

> [!NOTE]
> Your-SSID is the name of your network

#### 5. Exit from `iwctl`:

```bash
quit
```

### Verify Internet Connection

```bash
ping -c 3 google.com
```

You should see the following output:

```
64 bytes from XXX.XXX.XXX.XXX: icmp_seq=1 ttl=56 time=X ms
64 bytes from XXX.XXX.XXX.XXX: icmp_seq=2 ttl=56 time=X ms
64 bytes from XXX.XXX.XXX.XXX: icmp_seq=3 ttl=56 time=X ms
```

Press `Ctrl+C` or `⌘+C` to exit the ping utility.

You should see 3 amount of packets sent and received. Hopefully with 3 received and 0% packet loss.

### Update System Clock

```bash
timedatectl set-ntp true
```

This will enable the Network Time Protocol (NTP), which will keep your system clock synchronized with the internet.

To check if it worked:

```bash
timedatectl status
```

You should see output with current date and `NTP service: active`.

### Choosing the Installation Path

Once your environment is prepared, you have two primary ways to proceed with the installation.

#### 1. Manual Installation (The Traditional Way)

This involves manual partitioning via `gdisk`, creating filesystems, mounting subvolumes, and using `pacstrap`. It offers absolute control but is prone to human error.

#### 2. Guided Installation (The Easy Way)

Arch Linux includes an official guided installer called `archinstall`. This script automates the partitioning and base configuration while allowing for high levels of customization.

> [!TIP]
> For this `personal-lab` project, we use `archinstall`. It ensures a clean, reproducible foundation and gets us to final configuration faster.

### Running the Guided Installer

Type the following command to begin:

```bash
archinstall
```

### Configuration Menu Settings

> [!NOTE]
> The following selections are based on my specific preferences and hardware requirements for this lab.

Once inside the archinstall menu, configure the following settings. If a setting isn't listed here, you can leave it at the default.

#### 1. Archinstall language

Select English or your preferred language.

#### 2. Locales

Select `en_US.UTF-8`.

#### 3. Mirrors

1. Select regions: Closest region to you.
2. Add custom servers: skip this step.
3. Optional repositories: `multilib`. Even though we are building a server, having the 32-bit compatibility libraries is a "just in case" move that saves headaches later when certain Docker images or dependencies act up.
4. Add custom repository: skip this step.

#### 4. Disk configuration -> Partitioning

1. Disk configuration type: Use a best-effort default partition layout.
2. Select your preferred disk (The faster better SSD over HDD).
3. Filesystem: `btrfs`.
4. Would you like to use `BTRFS` subvolumes with a default structure?: Yes.
5. Would you like to use compression or disable CoW?: Use compression.

#### 5. Swap

Swap on zram: disabled.

#### 6. Bootloader

1. Bootloader: `grub`.
2. Install to removable location: `No`.

#### 7. Kernels

1. Kernels: `linux`.

#### 8. Hostname

Just input whatever you want, in my case I entered: `personal-lab`.

#### 9. Authentication

1. Root password: Your **strong** password!
2. User account: Create a user account with your **strong** password and set `Superuser` to `true`; This will give `sudo` permissions to the user.

#### 10. Profile

> [!TIP]
> This is where you can select the packages you want to install. Personally I'm going to use it time to time as desktop so going to choose `Desktop` option but if you are not going to use it as desktop, you can choose `Server` option.

1. Profile type: `Desktop`.
2. Environment: `KDE Plasma`.
3. Graphics: Choose based on your system, in my case it's Intel (open-source).
4. Greeter: `sddm`.

#### 11. Applications

1. Bluetooth: if you want to use it, select `Yes`.
2. Audio: `pipewire`.

#### 12. Network manager

1. Select: `Use Network Manager (default backend)`.

#### 13. Additional packages

> [!NOTE]
> The following core packages are required for the server's infrastructure and management: `docker`, `docker-compose` and `openssh`. Others are optional.

| Package                                                    | Purpose                                                                                  |
| ---------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| [openssh](https://www.openssh.org/portable.html)           | Secure Shell (SSH) server for remote access.                                             |
| [docker](https://www.docker.com/)                          | Containerization engine for self-hosted services.                                        |
| [docker-compose](https://www.docker.com/)                  | Tool for defining and running multi-container Docker applications.                       |
| [git](https://git-scm.com/)                                | Distributed version control system for project management.                               |
| [vim](https://www.vim.org/)                                | Advanced text editor for system configuration.; Or you can go with `nano` if you prefer. |
| [btop](https://github.com/aristocratos/btop)               | Resource monitor showing detailed CPU, memory, and network usage.                        |
| [ufw](https://www.openssh.org/portable.html)               | Uncomplicated Firewall for managing network security.                                    |
| [bash-completion](https://github.com/scop/bash-completion) | Programmable completion for Bash command line.                                           |

#### 14. Timezone

1. Select your timezone or leave `UTC`.

#### 15. Automatic time sync (NTP)

1. Select `Yes`.

### Install

Let's wait for install. After successful installation, you will see a completion screen. There will be three option:

1. Exit archinstall
2. Reboot system
3. chroot into installation for post-installation configurations.

Select `chroot into installation for post-installation configurations`, so we can enable core services and grant user permissions.

### Post Installation Configurations

#### 1. Enable core services

This ensures the server is reachable and ready to work the moment you turn it on.

```bash
systemctl enable NetworkManager
systemctl enable sshd
systemctl enable docker
```

#### 2. Grant user permissions

This allows you to run Docker commands without sudo every time.

```bash
usermod -aG docker <username>
```

> [!TIP]
> If you forgot username, run this command `ls /home`.

#### 3. Check the Network Interface

```bash
ip link
```

Here you should see at least one **UP**.
Other **DOWN** interfaces means it's either not connected or not enabled.

#### 4. Exit

Now it's time to exit and reboot system.

```bash
exit
reboot
```

## Post Installation

After rebooting, you will be logged in to your system.
Then we need to open terminal (KONSOLE is KDE), shortcut is: `CTRL + ALT + T` or `⌘ + Space` and then `Terminal`.

## Check Network Manager

Then lets check if network manager is running:

```bash
systemctl status NetworkManager
```

You should see **active (running)** in the output.

### Connect to Network

If you are already using ethernet, you can skip this step.

If you are using wifi, run this command:

```bash
nmcli device wifi connect <SSID>
```

### Find your assigned IP

```bash
ip addr show
```

You should see your assigned IP address in the output.
There would be **UP** and then IP address.
In my case it's `192.168.1.6`, which is my assigned IP address.

But there is a small issue. This was assigned by router dynamicly via DHCP. If your router reboots or the lease expires, it might decide to give that IP to your phone or your other device.

We can fix this by adding a static IP address.

## Configure Static IP Address

First we need to find connection name. Run this command:

```bash
nmcli connection show
```

In the output table, look at the **NAME** column.

- If you are using Ethernet, it is usually Wired connection 1.
- If you are using Wi-Fi, it will be the name of your SSID (your Wi-Fi network name).

### Set Static IP Address

I'm going to set up `192.168.1.22` as static IP address.

```bash
sudo nmcli con mod "<CONNECTION_NAME>" ipv4.addresses 192.168.1.22/24
sudo nmcli con mod "<CONNECTION_NAME>" ipv4.gateway 192.168.1.1
sudo nmcli con mod "<CONNECTION_NAME>" ipv4.dns "1.1.1.1,8.8.8.8"
sudo nmcli con mod "<CONNECTION_NAME>" ipv4.method manual
```

### Apply new address

```bash
sudo nmcli con up "<CONNECTION_NAME>"
```

## Enable Remote Access (SSH)

Since the goal is to run this server headless, you must ensure the SSH service starts automatically on every boot:

```bash
sudo systemctl enable --now sshd
```

## Enable Docker Engine

Similarly, ensure the Docker engine is active and set to start on boot so your containers are always ready:

```bash
sudo systemctl enable --now docker
```

## Check Service Persistence

```bash
systemctl is-enabled sshd
systemctl is-enabled docker
systemctl is-enabled NetworkManager
```

You should see `enabled` in the output 3 times.

> [!NOTE]
> If you see `disabled` in the output, it means the service is not enabled to start on boot. Run the `sudo systemctl enable --now <service_name>` command to enable it.

## Check SSH Connection

Now lets check if we can connect to the server from another computer on the same network. Run this command on another computer:

```bash
ssh <username>@<ip_address>
```

Since it's first time you connect to the server, you will see a message like this:

```
The authenticity of host '[IP_ADDRESS]' can't be established.
ECDSA key fingerprint is SHA256:[IP_ADDRESS].
Are you sure you want to continue connecting (yes/no/[IP_ADDRESS])?
```

Type `yes` and press `Enter`. You will be asked for your password. Enter your password and press `Enter`.

After successful login, you will see the prompt `[<username>@<hostname> ~]$`. This means you are successfully connected to the server.

## Summary

By following this guide, you have successfully transformed a bare-metal machine into a functional Arch Linux server. We have:

- Deployed a clean **BTRFS** file system with a **KDE Plasma** desktop environment.
- Configured **NetworkManager** with a static IP (**192.168.1.22**) to ensure consistent network discovery.
- Hardened the system by enabling **SSH** for headless management and **Docker** for container orchestration.

The server is now ready for headless operation. You can disconnect the monitor and peripherals, as all future management will take place via SSH.

Have fun!
