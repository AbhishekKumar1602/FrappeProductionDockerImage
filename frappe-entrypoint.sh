#!/usr/bin/env bash
set -euo pipefail

################################
#     REQUIRED ENVIRONMENT     #
################################
: "${SITE:?SITE is required}"
: "${ADMIN_PASS:?ADMIN_PASS is required}"
: "${DB_TYPE:?DB_TYPE is required}"
: "${DB_HOST:?DB_HOST is required}"
: "${DB_PORT:?DB_PORT is required}"
: "${DB_ROOT_USER:?DB_ROOT_USER is required}"
: "${DB_ROOT_PASS:?DB_ROOT_PASS is required}"
: "${DB_NAME:?DB_NAME is required}"
: "${DB_PASS:?DB_PASS is required}"
: "${REDIS_HOST:?REDIS_HOST is required}"
: "${REDIS_PASS:?REDIS_PASS is required}"
: "${REDIS_CACHE_PORT:?REDIS_CACHE_PORT is required}"
: "${REDIS_QUEUE_PORT:?REDIS_QUEUE_PORT is required}"
: "${REDIS_SOCKETIO_PORT:?REDIS_SOCKETIO_PORT is required}"

################################
#     OPTIONAL ENVIRONMENT     #
################################
: "${APPS:=}"

######################
#     CORE PATHS     #
######################
BENCH_TEMPLATE_DIR="/opt/frappe-bench-template"
BENCH_DIR="/home/frappe/frappe-bench"
SITES_DIR="${BENCH_DIR}/sites"
SITE_DIR="${SITES_DIR}/${SITE}"
UPDATED_APPS_DIR="${BENCH_TEMPLATE_DIR}/apps"
EXISTING_APPS_DIR="${BENCH_DIR}/apps"

########################
#     REDIS CONFIG     #
########################
REDIS_CACHE_URL="redis://:${REDIS_PASS}@${REDIS_HOST}:${REDIS_CACHE_PORT}"
REDIS_QUEUE_URL="redis://:${REDIS_PASS}@${REDIS_HOST}:${REDIS_QUEUE_PORT}"
REDIS_SOCKETIO_URL="redis://:${REDIS_PASS}@${REDIS_HOST}:${REDIS_SOCKETIO_PORT}"

################################
#     LOGGING / FAILURE        #
################################
log() {
  printf '%s [%s] %s\n' \
    "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    "${SITE}" \
    "$*"
}

fatal() {
  log "FATAL: $*"
  exit 1
}

########################
#     RETRY CONFIG     #
########################
: "${REDIS_RETRIES:=10}"
: "${REDIS_RETRY_DELAY:=3}"
: "${DB_RETRIES:=10}"
: "${DB_RETRY_DELAY:=3}"

########################
#     RETRY HELPER     #
########################
retry() {
  local max_attempts="$1"
  local delay="$2"
  shift 2

  local attempt=1
  while true; do
    if "$@"; then
      return 0
    fi

    if (( attempt >= max_attempts )); then
      return 1
    fi

    log "Retry ${attempt}/${max_attempts} failed; retrying in ${delay}s..."
    sleep "${delay}"
    attempt=$((attempt + 1))
  done
}

trap 'fatal "Init Container Terminated Unexpectedly"' INT TERM

log "Starting Init Container..."

############################
#     PREFLIGHT CHECKS     #
############################
redis_ping() {
  REDISCLI_AUTH="${REDIS_PASS}" \
    redis-cli -h "$1" -p "$2" PING >/dev/null 2>&1
}

check_redis() {
  for port in "${REDIS_CACHE_PORT}" "${REDIS_QUEUE_PORT}" "${REDIS_SOCKETIO_PORT}"; do
    redis_ping "${REDIS_HOST}" "${port}" || return 1
  done
}

check_mariadb() {
  MYSQL_PWD="${DB_ROOT_PASS}" \
    mysql -h "${DB_HOST}" -P "${DB_PORT}" -u "${DB_ROOT_USER}" \
    -e "SELECT 1;" >/dev/null 2>&1
}

check_postgres() {
  PGPASSWORD="${DB_ROOT_PASS}" \
    psql "host=${DB_HOST} port=${DB_PORT} user=${DB_ROOT_USER} dbname=postgres" \
    -c "SELECT 1;" >/dev/null 2>&1
}

check_db() {
  case "${DB_TYPE,,}" in
    mariadb|mysql) check_mariadb ;;
    postgres)      check_postgres ;;
    *) fatal "Unsupported DB_TYPE: ${DB_TYPE}" ;;
  esac
}

log "Waiting for Redis..."
retry "${REDIS_RETRIES}" "${REDIS_RETRY_DELAY}" check_redis \
  || fatal "Redis is not available in time."

log "Waiting for Database (${DB_TYPE})..."
retry "${DB_RETRIES}" "${DB_RETRY_DELAY}" check_db \
  || fatal "Database is not available in time."

log "Preflight Checks Passed."

############################
#     GLOBAL INIT LOCK     #
############################
LOCK_FILE="/tmp/frappe-init.lock"
exec 9>"${LOCK_FILE}" || fatal "Failed to open init lock."
flock -n 9 || fatal "Another init process is running."

#########################
#     BENCH SEEDING     #
#########################
mkdir -p "${BENCH_DIR}"

BENCH_INIT_MARKER="${BENCH_DIR}/.bench_initialized"

if [[ ! -f "${BENCH_INIT_MARKER}" ]]; then
  log "First-time bench initialization detected"

  if [[ -n "$(ls -A "${BENCH_DIR}" 2>/dev/null)" ]]; then
    log "WARNING: ${BENCH_DIR} not empty but not initialized, proceeding carefully"
  fi

  log "Seeding frappe-bench Directory..."
  cp -a "${BENCH_TEMPLATE_DIR}/." "${BENCH_DIR}" \
    || fatal "Frappe-Bench seeding failed."

  chown -R frappe:frappe "${BENCH_DIR}"
  touch "${BENCH_INIT_MARKER}"
  chown frappe:frappe "${BENCH_INIT_MARKER}"

  log "Bench initialization completed"
else
  log "Bench already initialized – skipping seeding"
fi

########################
#     REFRESH APPS     #
########################
if [[ -d "${UPDATED_APPS_DIR}" ]]; then
  log "Refreshing apps Directory..."
  TMP_APPS="${BENCH_DIR}/.apps.new"
  rm -rf "${TMP_APPS}"
  cp -a "${UPDATED_APPS_DIR}" "${TMP_APPS}" || fatal "Apps copy failed."
  chown -R frappe:frappe "${TMP_APPS}"
  rm -rf "${EXISTING_APPS_DIR}" || fatal "Failed to remove existing apps directory."
  mv "${TMP_APPS}" "${EXISTING_APPS_DIR}" || fatal "Apps swap failed."
fi

#########################
#     GLOBAL CONFIG     #
#########################
gosu frappe bash -lc "
  cd '${BENCH_DIR}' &&
  bench set-config -g redis_cache '${REDIS_CACHE_URL}' &&
  bench set-config -g redis_queue '${REDIS_QUEUE_URL}' &&
  bench set-config -g redis_socketio '${REDIS_SOCKETIO_URL}' &&
  bench set-config -g db_host '${DB_HOST}' &&
  bench set-config -g db_port '${DB_PORT}'
" || fatal "Global config failed"

#####################
#     SITE INIT     #
#####################
if [[ ! -d "${SITE_DIR}" ]]; then
  log "Creating site ${SITE}"
  gosu frappe bash -lc "
    cd '${BENCH_DIR}' &&
    bench new-site '${SITE}' \
      --db-type '${DB_TYPE}' \
      --db-host '${DB_HOST}' \
      --db-port '${DB_PORT}' \
      --db-root-username '${DB_ROOT_USER}' \
      --db-root-password '${DB_ROOT_PASS}' \
      --db-name '${DB_NAME}' \
      --db-password '${DB_PASS}' \
      --admin-password '${ADMIN_PASS}' \
      --force
  " || fatal "Site creation failed"
else
  gosu frappe bash -lc "cd '${BENCH_DIR}' && bench use '${SITE}'" \
    || fatal "bench use failed"
fi

########################
#     INSTALL APPS     #
########################
if [[ -n "${APPS}" ]]; then
  for app in ${APPS//,/ }; do
    gosu frappe bash -lc "
      cd '${BENCH_DIR}' &&
      if bench --site '${SITE}' list-apps | grep -qx '${app}'; then
        echo 'App already installed: ${app}'
      else
        bench --site '${SITE}' install-app '${app}'
      fi
    " || fatal "App install failed: ${app}"
  done
fi

################################
#     MIGRATIONS / BUILD       #
################################
gosu frappe bash -lc "cd '${BENCH_DIR}' && bench --site '${SITE}' migrate" \
  || fatal "Migration failed"

gosu frappe bash -lc "cd '${BENCH_DIR}' && bench build --production" \
  || fatal "Assets build failed"

gosu frappe bash -lc "
  cd '${BENCH_DIR}' &&
  bench --site '${SITE}' clear-cache &&
  bench --site '${SITE}' clear-website-cache
" || fatal "Cache clear failed"

################
#     DONE     #
################
log "Init Container Exited Successfully."
exit 0