# Frappe Production Docker Image
A production-focused image that bakes Node, wkhtmltopdf, Nginx, Gunicorn, Socket.IO, workers, scheduler, and a leader-elected boot flow (site init, migrate, assets). It’s designed to run **one or more** identical containers against the **same** persistent volumes with Redis-based coordination.

## Quick Start (TL;DR)

```bash
cp .env.example .env
cp apps.json.example apps.json

docker buildx build \
  --no-cache-filter=builder \
  --build-arg APPS_JSON_BASE64="$(base64 -w0 apps.json)" \
  -t frappe-prod-image .
```

> Create Volumes (Persistent Data & Logs):

```bash
docker volume create frappe-sites
docker volume create frappe-logs
```

> Run First Instance (Leader):

```bash
docker rm -f frappe-a 2>/dev/null || true
docker run -d --name frappe-a \
  --env-file ./.env \
  -p 8081:80 \
  -v frappe-sites:/home/frappe/frappe-bench/sites \
  -v frappe-logs:/home/frappe/frappe-bench/logs \
  frappe-prod-image

docker logs -f frappe-a
```

> Optionally Run Second Instance (Follower) **Pointing to the Same Volumes**:

```bash
docker rm -f frappe-b 2>/dev/null || true
docker run -d --name frappe-b \
  --env-file ./.env \
  -p 8082:80 \
  -v frappe-sites:/home/frappe/frappe-bench/sites \
  -v frappe-logs:/home/frappe/frappe-bench/logs \
  frappe-prod-image

docker logs -f frappe-b
```

> The containers self-elect a **leader** via Redis. The leader handles site creation (if needed), migrations, and asset builds; followers wait for markers and then start serving.

## What gets built into the image ?
* **Base:** Python 3.11 slim (Debian bookworm)
* **Node via nvm:** v20.19.x, global Yarn
* **wkhtmltopdf:** 0.12.6.1-x packages
* **Nginx:** runs as `frappe`, templated by `nginx-entrypoint.sh`
* **bench**: installed via `pip` and used to init/build
* **Builder Stage:** `bench init` with your `apps.json`, then `bench build --production`
* **Final Stage:** supervisord manages:
  * Nginx
  * Gunicorn (backend)
  * Socket.IO
  * Workers: default, short, long
  * Scheduler (toggle via `ENABLE_SCHEDULER`)

## Runtime Overview
* **Entrypoint:** `frappe-entrypoint.sh` (orchestrates boot)
* **Leader Election & Locks:** Redis (`LOCK_REDIS_*` defaults to the queue Redis)
* **Markers (in `sites/`):**
  * `.migrated_${IMAGE_REV}` — migrate done for this image rev
  * `.assets_built_${IMAGE_REV}` — assets built for this image rev
  * `.lock.init_${IMAGE_REV}` — init FS lock
* **Healthcheck:** hits `http://127.0.0.1/api/method/ping` with `Host: ${SITE}` every 30s

## Environment Variables

### Required (Site & DB)
* `SITE` — e.g. `mysite.localhost`
* `ADMIN_PASS` — admin password for initial site
* `DB_TYPE` — `mariadb` (or `mysql`, `postgres`)
* `DB_HOST`, `DB_PORT`
* `DB_ROOT_USER`, `DB_ROOT_PASS`
* Optional: `DB_NAME`, `DB_PASS` (custom db name/user password)

### Redis
* `REDIS_HOST`, `REDIS_PASS`
* `REDIS_CACHE_PORT` (6379), `REDIS_QUEUE_PORT` (6380), `REDIS_SOCKETIO_PORT` (6381)

### Boot Behavior
* `IMAGE_REV` — **bump this on deploys** to force fresh migrate/assets (e.g. `v1`, `v2`)
* `RUN_MIGRATIONS_ON_BOOT` — `leader` (default) or anything else to skip
* `APPS` — space-separated app names to install on first boot (e.g. `erpnext payments`)
* `AUTO_INSTALL_NEW_APPS` — `1` to auto-install any baked apps not yet installed
* `AUTO_APPS_ALLOWLIST` / `AUTO_APPS_DENYLIST` — refine which baked apps to auto-install
* `REBUILD_ASSETS_ON_BOOT` — `auto` (default), `1/true/yes`, or `0/false/no`
* `SKIP_INIT` — `1` to skip creating site (useful for pre-existing sites)

### Leader/Follower controls
* `IS_LEADER` — set `1` to force leader, any other value to force follower (skips election)
* `LEADER_ELECTION_TIMEOUT` — seconds to try to acquire leader lock (default 2)
* `MIGRATION_LOCK_TIMEOUT` — migrate lock wait (default 180)
* `FOLLOWER_WAIT_SECS` — delay before followers start waiting on markers (default 0)
* `LOCK_HEARTBEAT_SECS` / `LOCK_RENEW_TTL_SECS` — lock heartbeat/TTL (30/300 defaults)

### Nginx
* `BACKEND` (default `127.0.0.1:8000`)
* `SOCKETIO` (default `127.0.0.1:9000`)
* `UPSTREAM_REAL_IP_ADDRESS`, `UPSTREAM_REAL_IP_HEADER`, `UPSTREAM_REAL_IP_RECURSIVE`
* `PROXY_READ_TIMEOUT` (default `120`)
* `CLIENT_MAX_BODY_SIZE` (default `50m`)
* Optional: `SITE` is used by Nginx to set `X-Frappe-Site-Name` when not provided by header.

## apps.json
Used at **build time** to pin apps & branches.

```json
[
  {"url":"https://github.com/frappe/erpnext.git","branch":"version-15"},
  {"url":"https://github.com/frappe/payments.git","branch":"version-15"},
  {"url":"https://<userName>:<PAT>@<customAppA-repo-url>", "branch": "<branch-name>"},
  {"url":"https://<userName>:<PAT>@<customAppB-repo-url>", "branch": "<branch-name>"}
]
```

> Private Repos: Embed a read-only PAT in the URL at build time only. The builder strips `.git` dirs and caches; PATs aren’t needed at runtime.

## Build
```bash
docker buildx build \
  --no-cache-filter=builder \
  --build-arg APPS_JSON_BASE64="$(base64 -w0 apps.json)" \
  -t frappe-prod-image .
```

* `--no-cache-filter=builder` ensures the **builder** stage rebuilds your JS/CSS bundles when apps change.
* The final image contains the built assets.

## Run (Single Instance)
```bash
docker run -d --name frappe-a \
  --env-file ./.env \
  -p 8081:80 \
  -v frappe-sites:/home/frappe/frappe-bench/sites \
  -v frappe-logs:/home/frappe/frappe-bench/logs \
  frappe-prod-image
```

Browse: `http://localhost:8081`


## Run (Two or More Replicas with Leader Election)
All point to the **same** `sites` and `logs` volumes:

```bash
docker run -d --name frappe-a \
  --env-file ./.env \
  -p 8081:80 \
  -v frappe-sites:/home/frappe/frappe-bench/sites \
  -v frappe-logs:/home/frappe/frappe-bench/logs \
  frappe-prod-image

docker run -d --name frappe-b \
  --env-file ./.env \
  -p 8082:80 \
  -v frappe-sites:/home/frappe/frappe-bench/sites \
  -v frappe-logs:/home/frappe/frappe-bench/logs \
  frappe-prod-image
```

* One becomes **leader** (runs `bench migrate`, builds assets if needed).
* The others waits for `.migrated_${IMAGE_REV}` and `.assets_built_${IMAGE_REV}` markers, then serves.

> You can override roles with `IS_LEADER=1` on exactly one container if you prefer static roles.

## Upgrades / Deploys
1. **Build** a new image (update apps.json branches if needed).
2. **Bump** `IMAGE_REV` in your `.env` (e.g., `v2`).
3. **Rolling Restart** your containers (one by one) with the new image:
   * First container starts, wins leader, migrates, rebuilds assets.
   * Second container starts, sees markers, serves.

## Production Tips
* **Persistent volumes:** Always mount `sites/` and `logs/`. Optionally mount `sites/assets/` separately for CDN sync.
* **Backups:** Use `restic` or your preferred backup tool to snapshot `sites/` and database regularly.
* **TLS/Edge:** Terminate TLS in front (e.g., reverse proxy or cloud LB). Nginx inside listens on 80.
* **DB sizing:** Ensure DB and Redis are reachable before boot; the entrypoint waits on TCP but not on schema health.
* **Scheduler:** `ENABLE_SCHEDULER=1` by default. Set `0` on followers if you only want one scheduler (or just let both start—the leader election does not coordinate scheduler concurrency; Frappe’s own scheduler is idempotent but many teams still prefer a single scheduler).

## Troubleshooting
* **Healthcheck Failing**: Ensure the site exists and DNS/`SITE` aligns with the Host header. For local testing, keep `SITE=mysite.localhost`.
* **Migrations Stuck**: Check Redis lock reachability/auth (`LOCK_REDIS_*`), and container logs for `bench migrate` output.
* **Assets Not Updating**: Bump `IMAGE_REV` or set `REBUILD_ASSETS_ON_BOOT=1` for that boot.
* **Permission Errors**: The entrypoint fixes ownership of `sites/` and `logs/` at start; verify your volume driver and host FS perms.
* **Multiple Leaders**: If you’ve overridden `IS_LEADER` on more than one container, only one will be able to obtain the migrate lock; remove manual overrides or ensure uniqueness.

## Ports
* Container **80** → Nginx (proxied to Gunicorn :8000 and Socket.IO :9000 internally)
* Expose/Map as needed (e.g., `-p 8081:80`)
