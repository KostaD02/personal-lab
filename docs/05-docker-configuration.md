<h1>0.5 Docker Configuration</h1>

Now that the OS is breathing and the storage is mounted, it is time to install the core of this setup.
Containerizing services ensures that configuration remains isolated and the host system stays clean.

Since we are using **Docker Compose** on our **192.168.1.22** node,
we require a setup that is reproducible,
organized, and prevents logs from consuming the entire root partition.

- [Installation: Docker Engine \& Compose](#installation-docker-engine--compose)
- [Daemon Optimization](#daemon-optimization)
- [Standardized Directory Structure](#standardized-directory-structure)
- [Shared Network Infrastructure](#shared-network-infrastructure)
- [Summary](#summary)

## Installation: Docker Engine & Compose

In [01-arch-installation.md](/docs/01-arch-installation.md), we installed Docker Engine and Docker Compose but if you missed installing them, here is the command:

```bash
sudo pacman -S docker docker-compose
```

To manage Docker as a non-root user, add your user to the docker group:

```bash
sudo usermod -aG docker $USER
newgrp docker
```

## Daemon Optimization

By default, Docker does not limit log sizes, which can lead to significant disk usage over time.
We will configure the daemon to rotate logs and define specific address pools to avoid conflicts with existing network infrastructure.

First we need to create the directory where Docker will store its data:

```bash
sudo mkdir -p /mnt/data/docker
```

Lets create a configuration file:

```bash
sudo vim /etc/docker/daemon.json
```

Insert the following configuration into the file:

```json
{
  "data-root": "/mnt/data/docker",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
```

Enable and start the Docker service to apply the changes:

```bash
sudo systemctl enable --now docker
```

## Standardized Directory Structure

Maintaining a consistent directory structure is vital for long-term management. All Docker configurations should reside in a dedicated path, such as `/opt/stacks`, to separate configuration from application data volumes.

```bash
/opt/stacks/
├── dashboard/
│   └── homarr/
│       └── docker-compose.yml
├── media/
│   └── immich/
│       └── docker-compose.yml
├── utility/
│   └── microbin/
│       └── docker-compose.yml
├── workspace/
│   └── excalidraw/
│       └── docker-compose.yml
└── tools/
    └── it-tools/
        └── docker-compose.yml
```

> [!NOTE]
> This directory structure is specific to my setup. You can change it to your liking.

## Shared Network Infrastructure

To allow containers in different categories to communicate, specifically for a reverse proxy to reach various applications, we must create a persistent external bridge network.

```bash
docker network create proxy-nw
```

In subsequent `docker-compose.yml` **files**, this network is referenced as an external entity to ensure connectivity across stacks:

```yaml
networks:
  proxy-nw:
    external: true
```

## Summary

This configuration transforms Docker from a basic runtime into a structured docker environment.
