<h1>0.6 Initial Stack Deployment</h1>

With the Docker engine optimized and the directory structure ready, we will deploy our first two services.
[Homarr](https://homarr.dev/) (dashboard) will serve as our central command center, and
[MicroBin](https://microbin.eu/) will provide a self-hosted "pastebin" for quick data sharing.

> [!NOTE]
> These are stacks which I want to use. You can install whatever you want.
> The important part is that you understand the process and can replicate it for other services.

- [Homarr](#homarr)
  - [Setup](#setup)
  - [Docker Compose Configuration](#docker-compose-configuration)
- [MicroBin](#microbin)
  - [Setup](#setup-1)
  - [Docker Compose Configuration](#docker-compose-configuration-1)
- [Summary](#summary)

## Homarr

Homarr is a sleek, modern dashboard for your home lab.
It allows you to organize all your future services in one place.

### Setup

Create the specific directory for the stack:

```bash
mkdir -p /opt/stacks/dashboard/homarr
cd /opt/stacks/dashboard/homarr
vim docker-compose.yml
```

### Docker Compose Configuration

Based on the [official documentation](https://homarr.dev/docs/getting-started/installation/docker/):

```yaml
services:
  homarr:
    container_name: homarr
    image: ghcr.io/homarr-labs/homarr:latest
    restart: unless-stopped
    volumes:
      - /mnt/data/docker/volumes/homarr:/appdata
    environment:
      - SECRET_ENCRYPTION_KEY=ceef22674baa68544d8b3493131c6ff0b77d1d84941d5cbe677d8e51e745f440
    ports:
      - "7575:7575"
    networks:
      - proxy-nw

networks:
  proxy-nw:
    external: true
```

> [!NOTE]
> The `SECRET_ENCRYPTION_KEY` is a randomly generated string of 64 characters.
> You can generate one using the `openssl rand -hex 32` command.

- Volumes: `/mnt/data/docker/volumes/homarr:/appdata` - This is where Homarr stores its configuration and data. It specifically stores the data on my second drive. I would recommend to store the data on a separate drive if you have one. To configure storage you can read [03-storage-configuration.md](03-storage-configuration.md).
- Networks: `proxy-nw` - This is an external network that Homarr uses to communicate with other services.
- Ports: `7575:7575` - This maps port `7575` on the host to port `7575` in the container. You can change this if you want to.

> [!NOTE]
> Host port doesn't have to match the Container port. It's just a mapping.

We can start the container using the following command:

```bash
sudo docker compose up -d
```

Try to open it in your browser: `http://192.168.1.22:7575` (replace it with your IP address and port).

## MicroBin

MicroBin is a tiny, self-hosted implementation of a pastebin.
It is highly efficient and perfect for moving snippets of code or
configuration files between your workstation and the server.

### Setup

Create the directory for the tool:

```bash
mkdir -p /opt/stacks/utility/microbin
cd /opt/stacks/utility/microbin
vim docker-compose.yml
```

### Docker Compose Configuration

Based on the [official documentation](https://microbin.eu/docs/installation-and-configuration/docker):

```yaml
services:
  microbin:
    container_name: microbin
    image: danielszabo99/microbin:latest
    restart: unless-stopped
    volumes:
      - /mnt/data/docker/volumes/microbin:/app/data
    ports:
      - "8000:8080"
    networks:
      - proxy-nw

networks:
  proxy-nw:
    external: true
```

We can start the container using the following command:

```bash
sudo docker compose up -d
```

Try to open it in your browser: `http://192.168.1.22:8000` (replace it with your IP address and port).

## Summary

We have successfully deployed two services on our Arch Linux server: Homarr (dashboard) and MicroBin (pastebin).
These services are now accessible via the web interface and can be used to manage and share data between your workstation and the server.
You can add more services by following the same process. Checkout my stacks here [stacks](/stacks/README.md).

Have fun!
