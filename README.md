# onedev-railway

Deployment files for running [OneDev](https://onedev.io) — a self-hosted Git
server with built-in CI/CD, code review, issue tracking and package registries —
on [Railway](https://railway.com).

Two images are built from this repository:

| Directory | Service | Base image | Purpose |
|---|---|---|---|
| `server/` | OneDev server | `1dev/server:latest` | Git hosting, web UI, REST API, package registries |
| `agent/`  | OneDev agent  | `1dev/agent:latest`  | CI/CD worker that runs build jobs |

Point each Railway service's **root directory** at the matching folder.

## Why a custom image at all

The published images are configured entirely through environment variables, so
almost nothing here is a fork. Each layer adds exactly one thing Railway needs
that an environment variable cannot express:

* **`server/entrypoint.sh`** — OneDev ships with *account self sign-up enabled*
  and stores that flag in its database, so a deployment reachable from the
  internet lets strangers create accounts until somebody opens the admin UI.
  The entrypoint waits for `/readyz` and turns it off through OneDev's own REST
  API. It also seeds a job executor, because Railway blocks nested containers
  and OneDev's default Docker executor therefore cannot run.
* **`agent/entrypoint.sh`** — an agent authenticates with a token that exists
  only as a row in the *server's* database, so it cannot be generated on the
  agent side. The agent asks the server to mint one on first boot and keeps it
  on its own volume. It also serves a liveness endpoint on `$PORT`, since the
  agent otherwise publishes no HTTP and a crash loop would read as healthy.

Every step is guarded by a marker file on the volume, so a later deploy never
reverts a setting the operator has since changed in the admin UI.

## Environment variables

### Server

| Variable | Value |
|---|---|
| `hibernate_dialect` | `io.onedev.server.persistence.PostgreSQLDialect` |
| `hibernate_connection_driver_class` | `org.postgresql.Driver` |
| `hibernate_connection_url` | `jdbc:postgresql://<host>:<port>/<database>` |
| `hibernate_connection_username` / `hibernate_connection_password` | Postgres credentials |
| `http_host` | `::` — dual-stack, so both Railway's IPv4 health prober and IPv6 peers are served |
| `http_port` / `PORT` | `6610` |
| `ssh_port` | `6611` — git over SSH, published with a Railway TCP proxy |
| `cluster_ip` | `127.0.0.1` — skips OneDev's auto-discovery, which probes the database host and can fail on a private IPv6 network |
| `initial_user`, `initial_password`, `initial_email` | first administrator, created on first boot only |
| `initial_server_url` | `https://<public domain>` |

### Agent

| Variable | Value |
|---|---|
| `serverUrl` | `http://<server>.railway.internal:6610` |
| `ONEDEV_ADMIN_USER` / `ONEDEV_ADMIN_PASSWORD` | the server's `initial_user` / `initial_password`, used once to mint an agent token |
| `agentToken` | optional — set it to skip minting and use a token you created yourself |
| `PORT` | port for the liveness endpoint |

## Volumes

* Server — `/opt/onedev` (the whole installation, including `site/` where git
  repositories, LFS objects, build artifacts and packages live)
* Agent — `/agent/work` (job workspaces and the minted token)

## Licence

OneDev is MIT licensed. The files in this repository are provided under the same
terms.
