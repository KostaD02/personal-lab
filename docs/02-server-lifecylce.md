<h1> 02. Server Life Cycle </h1>

This guide covers how to configure the server to ensure it remains operational 24/7.
It includes hardware-level power recovery, kernel-level stability via GRUB,
and the suppression of OS-level sleep and hibernation triggers to maintain a persistent connection at `192.168.1.22`.

- [BIOS Configuration: The "Stay Alive" Foundation](#bios-configuration-the-stay-alive-foundation)
  - [How to enter BIOS](#how-to-enter-bios)
  - [BIOS Settings](#bios-settings)
- [Kernel Stability via GRUB](#kernel-stability-via-grub)
- [OS-Level Suppression: The "Anti-Nap" Protocol](#os-level-suppression-the-anti-nap-protocol)
  - [Masking Systemd Targets](#masking-systemd-targets)
- [Network Stability: Wi-Fi Power Management](#network-stability-wi-fi-power-management)
  - [Disable Wi-Fi Power Save](#disable-wi-fi-power-save)
- [Summary](#summary)

## BIOS Configuration: The "Stay Alive" Foundation

Before the OS even loads, the hardware must be told never to accept a powered-down state.

### How to enter BIOS

To enter BIOS there are two easy way:

1. Using common BIOS keys when booting up:
   1. ASUS: `DEL` or `F2`
   2. MSI / Gigabyte / ASRock: `Delete`
   3. HP: `F10` (sometimes Esc first)
   4. Dell: `F2` or `F12`
   5. Lenovo: `F2` or `Fn + F2`
2. Open terminal while server is running and run: `systemctl reboot --firmware-setup`

### BIOS Settings

We need to change following settings:

| Setting           | Value    | Purpose                                                                     |
| ----------------- | -------- | --------------------------------------------------------------------------- |
| AC Power Recovery | Power On | Automatically reboots the server after a power outage.                      |
| ErP Ready         | Disabled | Prevents the motherboard from cutting power to networking for "efficiency." |
| Fast Boot         | Disabled | Ensures all hardware (including that Wi-Fi card) is properly initialized.   |

## Kernel Stability via GRUB

To prevent the kernel from idling or throttling the PCIe bus (which handles the Wi-Fi connection), the GRUB configuration must be updated to disable power-saving features that can cause latency or "ghosting" on the network.

Edit the GRUB configuration:

```bash
sudo vim /etc/default/grub
```

Update the command line:

Locate the `GRUB_CMDLINE_LINUX_DEFAULT` line and add `consoleblank=0` and `pcie_aspm=off`. It should look like this:

```bash
GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 consoleblank=0 pcie_aspm=off"
```

- `consoleblank=0`: Disables screen blanking, which can sometimes trigger ACPI sleep signals.
- `pcie_aspm=off`: Disables Active State Power Management for PCIe, ensuring the Wi-Fi card stays at full power.

Rebuild the GRUB config:

```bash
sudo grub-mkconfig -o /boot/grub/grub.cfg
```

## OS-Level Suppression: The "Anti-Nap" Protocol

Even with the hardware and kernel prepared, Systemd will try to manage power for "efficiency." We must explicitly forbid these actions.

### Masking Systemd Targets

Masking is the strongest way to disable a service in Arch. It links the service to `/dev/null`, making it impossible to start.

Run the masking command:

```bash
sudo systemctl mask sleep.target suspend.target hibernation.target hybrid-sleep.target
```

Verify the status:

```bash
systemctl status sleep.target
```

You should see `Loaded: masked`.

Configuring the Login Daemon (logind.conf)

The login daemon manages physical triggers like the power button and idle timeouts. We need to tell it to ignore everything.

Open the configuration:

```bash
sudo vim /etc/systemd/logind.conf
```

Modify the `[Login]` section:

Ensure the following lines are uncommented (remove the #) and set to ignore:

```Ini
[Login]
HandlePowerKey=ignore
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
IdleAction=ignore
IdleActionSec=0
```

Apply the changes:

```bash
sudo systemctl restart systemd-logind
```

## Network Stability: Wi-Fi Power Management

> [!NOTE]
> This step is only necessary if you are using Wi-Fi as your server's internet connection.

By default, Arch and NetworkManager will try to pulse the power to the Wi-Fi card to save energy. This is a disaster for a server at `192.168.1.22` because it introduces latency spikes and can cause the interface to "ghost" (become unreachable) until a physical packet is sent from the server.

### Disable Wi-Fi Power Save

We need to create a configuration file that forces NetworkManager to keep the radio at 100% power at all times.

Create the configuration file:

```bash
sudo vim /etc/NetworkManager/conf.d/default-wifi-powersave-on.conf
```

Set the following value:

```Ini
[connection]
wifi.powersave = 2
```

NetworkManager uses an internal enumeration for power settings:

- `1`: Default (Uses the system-wide default)
- `2`: Disable (Forces power-saving OFF)
- `3`: Enable (Forces power-saving ON)

Apply and Verify

Restart NetworkManager to apply the change:

```bash
sudo systemctl restart NetworkManager
```

Verify the interface status:

Ensure the `iw` utility is installed and check the interface:

```bash
sudo pacman -S iw wireless_tools
iw dev wlan0 get power_save
```

Output should confirm: `Power save: off`.

## Summary

By completing these steps, the server is transitioned from a "desktop-first" energy-saving configuration to a "server-first" persistent operation mode.

- **Hardware Layer**: BIOS settings ensure that if power is cut, the server resumes immediately upon power restoration without human intervention.
- **Kernel Layer**: GRUB parameters prevent the CPU and PCIe bus from entering low-power "ghosting" states that disrupt remote access.
- **System Layer**: systemd masking and logind overrides create a "Never Sleep" policy, treating physical triggers (like lid closures or power buttons) and inactivity as non-events.
- **Network Layer**: Disabling Wi-Fi power management ensures the `192.168.1.22` address remains responsive and low-latency, preventing SSH timeouts.

The system is now a reliable, 24/7 "Immortal" node ready to host the educata and MirrorTab stacks.
