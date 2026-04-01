<h1>The Arr Media Lab</h1>

This guide outlines the configuration of a fully automated, hardware-accelerated media stack. It is optimized for Docker on Arch Linux, focusing on "Atomic Moves" to preserve disk health and ensure instant media availability.

> [!IMPORTANT]
> **Disclaimer:** This guide is for educational and homelab experimentation purposes only. The author does not condone or encourage the illegal downloading of copyrighted material. Please use these tools responsibly and in compliance with your local laws.

- [The Foundation: Folder Structure](#the-foundation-folder-structure)
- [The Docker Stack](#the-docker-stack)
- [Critical Service Configuration](#critical-service-configuration)
  - [Prowlarr \& FlareSolverr (Bypassing Cloudflare)](#prowlarr--flaresolverr-bypassing-cloudflare)
  - [Jellyfin Playback \& Transcoding](#jellyfin-playback--transcoding)
- [The Automation Loop: Connecting Services](#the-automation-loop-connecting-services)
  - [Syncing Indexers (Prowlarr to Sonarr/Radarr)](#syncing-indexers-prowlarr-to-sonarrradarr)
  - [Connecting the Downloader (Sonarr/Radarr to qBittorrent)](#connecting-the-downloader-sonarrradarr-to-qbittorrent)
- [Dashboard Integration](#dashboard-integration)

## The Foundation: Folder Structure

Before touching Docker, you must establish a consistent path mapping. This prevents "Double Space" issues where files are copied (slow) instead of hardlinked (instant). By mapping everything under a single `/data` root inside containers, the OS can perform instant file pointers rather than data duplication.

```bash
sudo mkdir -p /mnt/data/media/{downloads/{tv,movies},tv,movies}
sudo mkdir -p /mnt/data/docker/volumes/{sonarr,radarr,prowlarr,jellyfin}/config

sudo chown -R 1000:1000 /mnt/data/media /mnt/data/docker/volumes
```

## The Docker Stack

Place this in your media stack directory. This configuration uses a shared network for internal service communication and passes through the host GPU device for transcoding.

```yaml
services:
  prowlarr:
    image: lscr.io/linuxserver/prowlarr:latest
    container_name: prowlarr
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Asia/Tbilisi
    volumes:
      - /mnt/data/docker/volumes/prowlarr/config:/config
    ports:
      - 9696:9696
    networks:
      - proxy-nw
    restart: unless-stopped

  sonarr:
    image: lscr.io/linuxserver/sonarr:latest
    container_name: sonarr
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Asia/Tbilisi
    volumes:
      - /mnt/data/docker/volumes/sonarr/config:/config
      - /mnt/data/media:/data
    ports:
      - 8989:8989
    networks:
      - proxy-nw
    restart: unless-stopped

  radarr:
    image: lscr.io/linuxserver/radarr:latest
    container_name: radarr
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Asia/Tbilisi
    volumes:
      - /mnt/data/docker/volumes/radarr/config:/config
      - /mnt/data/media:/data
    ports:
      - 7878:7878
    networks:
      - proxy-nw
    restart: unless-stopped

  flaresolverr:
    image: ghcr.io/flaresolverr/flaresolverr:latest
    container_name: flaresolverr
    environment:
      - LOG_LEVEL=info
      - TZ=Asia/Tbilisi
    networks:
      - proxy-nw
    restart: unless-stopped

  jellyfin:
    image: lscr.io/linuxserver/jellyfin:latest
    container_name: jellyfin
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Asia/Tbilisi
    volumes:
      - /mnt/data/docker/volumes/jellyfin/config:/config
      - /mnt/data/media:/data
    ports:
      - 8096:8096
    devices:
      - /dev/dri:/dev/dri # Pass-through for Hardware Acceleration
    networks:
      - proxy-nw
    restart: unless-stopped

networks:
  proxy-nw:
    external: true
```

## Critical Service Configuration

### Prowlarr & FlareSolverr (Bypassing Cloudflare)

Many public indexers are protected by Cloudflare’s "Under Attack" mode. FlareSolverr acts as a proxy to solve these challenges.

- Access Prowlarr at `http://<IP>:9696`.
- Go to **Settings > Indexers > Add Proxy > FlareSolverr**.
- **Host:** `http://flaresolverr:8191`.
- **Tag:** Create a tag named `flare`.

Apply the `flare` tag to indexers to route them through the solver:

| Indexer Name | Type   | Best For...               | Tag Required |
| ------------ | ------ | ------------------------- | ------------ |
| 1337x        | Public | General Movies and TV     | `flare`      |
| Nyaa.si      | Public | High-Quality Anime        | `flare`      |
| EZTV         | Public | Standard TV Show releases | None         |
| YTS          | Public | Small file size Movies    | None         |
| LimeTorrents | Public | General backup            | `flare`      |

### Jellyfin Playback & Transcoding

> [!NOTE]
> This section is for Intel QuickSync (QSV) or VA-API.

To ensure smooth playback on all devices and utilize Hardware Acceleration (HWA):

1.  Navigate to **Dashboard > Playback > Transcoding**.
2.  **Hardware Acceleration:** Select **Intel QuickSync (QSV)** or **VA-API**.
3.  **Enable Decoding:** Check **H264, HEVC, VC1, VP8, VP9, and AV1** (if supported).
4.  **Low-Power Encoding:** Enable the low-power encoders for H264/HEVC.
5.  **Device Path:** Ensure `/dev/dri/renderD128` is targeted (for Intel).
6.  **Library Metadata:** Disable "Prefer embedded titles over filenames" to avoid messy torrent names in your UI.

## The Automation Loop: Connecting Services

For the "Brains" (Sonarr/Radarr) to work with the "Downloader" (qBittorrent) and "Eyes" (Prowlarr), follow these steps:

### Syncing Indexers (Prowlarr to Sonarr/Radarr)

1. In Prowlarr, go to **Settings > General** and copy the **API Key**.
2. Go to **Settings > Connect > + (Add)**.
3. Select **Sonarr**. Use `http://sonarr:8989` as the URL and input Sonarr's API Key (found in Sonarr's Settings > General).
4. Repeat for **Radarr** using `http://radarr:7878`.
5. Prowlarr will now automatically push indexers to your managers.

### Connecting the Downloader (Sonarr/Radarr to qBittorrent)

1. In Sonarr and Radarr, go to **Settings > Download Clients > + (Add) > qBittorrent**.
2. **Host:** Use your server IP (e.g., `192.168.1.22`) or the Docker service name `qbittorrent`.
3. **Port:** Use the Web UI port (usually `8080` or `8090`).
4. **Username** and **Password**: Use the username and password you set in the qBittorrent stack.
5. **Category:** Set this to `tv` for Sonarr and `movies` for Radarr. This ensures files land in the correct subfolders for automatic importing.
6. **Remote Path Mappings (Crucial):** If the "Test" works but files aren't importing after a download, scroll to the bottom of Download Clients and add a mapping:
   - **Host:** `qbittorrent`
   - **Remote Path:** `/downloads/`
   - **Local Path:** `/data/downloads/`
7. **Note on Anime:** When adding anime series in Sonarr, change **Series Type** to **Anime** to ensure compatibility with absolute episode numbering.

## Dashboard Integration

Use these endpoints and API key locations for your dashboard:

| App             | Port   | API Key Location     |
| :-------------- | :----- | :------------------- |
| **Sonarr**      | `8989` | Settings > General   |
| **Radarr**      | `7878` | Settings > General   |
| **Prowlarr**    | `9696` | Settings > General   |
| **Jellyfin**    | `8096` | Dashboard > API Keys |
| **qBittorrent** | `8090` | Web UI Credentials   |

Have fun!
