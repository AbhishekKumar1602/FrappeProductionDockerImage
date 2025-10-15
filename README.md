# FRAPPE Production Docker Image

A production-focused Docker image for running Frappe in containers that share the same persistent volumes. This image bundles Node, wkhtmltopdf, Nginx, Gunicorn, Socket.IO, background workers, scheduler, and a Redis-backed leader-election boot flow so **multiple identical containers** can run against the **same** site data safely.

The leader container performs one-time / coordinated tasks (site init, migrations, building assets). Followers wait for the leader to finish and then start serving.

## Highlights

* Designed to run **multiple identical containers** against the **same persistent volumes**.
* Uses **Redis** for leader election and coordination.
* Leader handles site setup, migrations, and asset builds; followers start after markers appear.
* Includes common production components: Nginx, Gunicorn, Socket.IO, workers, scheduler, Node.js, wkhtmltopdf.

## Quick Start (TL;DR)

1. Copy the example environment and apps file and update them:

```bash
cp .env.example .env
cp apps.json.example apps.json
```

2. Build the image (embed `apps.json` into the build):

```bash
docker buildx build \
  --no-cache-filter=builder \
  --build-arg APPS_JSON_BASE64="$(base64 -w0 apps.json)" \
  -t frappe-prod-image .
```

3. Create persistent volumes for sites and logs:

```bash
docker volume create frappe-sites
docker volume create frappe-logs
```

4. Start the first instance (this will become the **leader**):

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

5. Start additional instances (followers) **pointing to the same volumes**:

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

## How it works
* **Leader election**: Containers coordinate with Redis. On startup they attempt to acquire leadership.
* **Leader responsibilities**: site creation/initialization, running database migrations, building frontend assets, and writing markers that indicate those steps completed.
* **Followers**: wait for the leader to finish (presence of marker files / flags in the shared volumes or Redis), then start the web server and workers.
* **Idempotency**: operations are safe to re-run; leader logic guards against race conditions so multiple simultaneous containers won’t corrupt the shared data.

## Environment & Configuration
* `.env` contains runtime configuration (Redis URL, database connection, admin credentials for site creation, etc.). Fill this file before running containers.
* `apps.json` (embedded at build time) lists Frappe/ERPNext apps to include.
* Important: ensure the same `.env` and `apps.json` are used for all containers that share volumes.

## Volumes and Persistence
* Use Docker volumes (or bind mounts) for:
  * `sites` — store site data, uploaded files, and site configs.
  * `logs` — store application logs.

Example mount points used in the Quick Start:

```
-v frappe-sites:/home/frappe/frappe-bench/sites
-v frappe-logs:/home/frappe/frappe-bench/logs
```

## Ports
* The container exposes port `80`. Map it to the host as needed (e.g., `-p 8081:80`).
* If running multiple containers on one host for testing, map each to a different host port.

## Troubleshooting
* **No leader elected / Redis errors**: confirm Redis is reachable from containers and the URL in `.env` is correct.
* **Site init or migrations hang**: check leader logs (`docker logs -f <leader>`) for errors and ensure file permissions on volumes permit the container to write markers.
* **Follower never starts serving**: verify that the leadership marker files exist in the shared volume and that follower can read them.

## Best Practices
* Run Redis as a highly-available service (or ensure it's reliably reachable) — leader election depends on it.
* Use a single, consistent `.env` and `apps.json` for all containers attached to the same volumes.
* Back up the `frappe-sites` volume regularly (it contains user data and sites).
* For production, run containers behind a load balancer and do health checks against the web process.

## Example: Compose / Orchestration
You can run instances with Docker Compose, Kubernetes, or any orchestration layer — just mount the same persistent storage and supply identical env/config. Make sure Redis is shared and reachable by all replicas.
