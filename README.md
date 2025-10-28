# FRAPPE Production Docker Image
This repository provides a production-focused Docker image and orchestration examples to run Frappe/ERPNext using **multiple identical containers** against the **same persistent `sites` volume**. Containers coordinate via Redis: one container becomes the leader and performs one-off tasks (site creation, app installs, migrations, asset builds). Followers wait until the leader finishes.


**Security note:** For private app repos, avoid embedding PATs in the image. Use runtime secrets, build-time secure pipelines, or private build contexts.

## Build the image (recommended)
If you want to include `apps.json` at build-time (so `bench init` happens in the builder), you can embed it via build-arg:

```bash
docker buildx build \
  --no-cache-filter=builder \
  --build-arg APPS_JSON_BASE64="$(base64 -w0 apps.json)" \
  -t frappe-prod-image:latest .
```

**Important:** Do not embed private tokens into the image unless you are building in a secure environment and rotate tokens.

## Run with Docker Compose 

1. Copy example .env and app.json and update accordingly:

```bash
cp .env.example .env
cp apps.json.example apps.json
```

2. Ensure Volumes Exist:
```bash
docker volume create frappe-sites
docker volume create frappe-logs
```

3. Start Services:
```bash
docker compose up -d
```

4. Check Logs:
```bash
docker compose logs -f --tail=100
```

> One container should become **LEADER** and perform site creation / app installs / migrations / assets builds. Followers wait for the markers and then start serving.

## Readiness & Healthchecks
* The entrypoint creates a readiness marker at:
```bash
/home/frappe/frappe-bench/sites/.ready_<IMAGE_REV>
```
when `apps`, `migrations`, and `assets` for `IMAGE_REV` are completed.
* Use this file for readiness probes in orchestrators (Kubernetes readiness `exec: test -f ...`).
* Container `HEALTHCHECK` in image points to `/api/method/ping`, but orchestration readiness should rely on the `.ready_...` marker to avoid routing traffic to a container that is still waiting.

## Handling Partial Failures and Stale Steps
* If leader crashes mid-step, it leaves an `.in_progress` marker (e.g. `.apps_installing_in_progress_v1`).
* A subsequent leader checks the marker timestamp — if it's older than `STEP_STALE_SECS`, it will remove it and take over.
* Tune `STEP_STALE_SECS` based on expected installation time.

## Volumes & Permissions
* If using host bind mounts, ensure ownership permits the `frappe` user (UID typically `1000`) to write:

```bash
docker run --rm -v frappe-sites:/mnt/tmp busybox chown -R 1000:1000 /mnt/tmp
```
* In k8s, use RWX-capable storage (NFS, CephFS) if running >1 replica.

## Redis & Reliability
Leader election **depends** on Redis. For production:
* Run Redis in a highly available mode (Sentinel or Cluster) or managed Redis (ElastiCache, Redis Enterprise).
* A single, flaky Redis instance can cause split-brain or election instability.

## Troubleshooting
* **No leader / Redis errors**: Check connectivity to Redis and credentials; logs show PING failures.
* **Follower never proceeds**: Inspect presence/ownership of `.migrated_*`, `.apps_installed_*`, `.assets_built_*` markers in the `sites` volume. Ensure follower can read them.
* **Stuck due to stale marker**: Increase `STEP_STALE_SECS` or manually remove the offending `.in_progress` file if you understand the state.
* **Permission denied writing markers**: Adjust volume ownership (`chown`) or correct mount options.
