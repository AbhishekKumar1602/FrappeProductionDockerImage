#!/usr/bin/env bash
set -euo pipefail

################################
#     REQUIRED ENVIRONMENT     #
################################
: "${SITE:?SITE is required}"
: "${DB_TYPE:?DB_TYPE is required}"
: "${DB_HOST:?DB_HOST is required}"
: "${DB_PORT:?DB_PORT is required}"
: "${DB_ROOT_USER:?DB_ROOT_USER is required}"
: "${DB_ROOT_PASS:?DB_ROOT_PASS is required}"
: "${ADMIN_PASS:?ADMIN_PASS is required}"
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

################################
#     CORE PATHS / CONSTANTS   #
################################
BENCH_TEMPLATE_DIR="/opt/frappe-bench-template"
BENCH_DIR="/home/frappe/frappe-bench"
SITES_DIR="${BENCH_DIR}/sites"
SITE_DIR="${SITES_DIR}/${SITE}"

########################
#     REDIS CONFIG     #
########################
REDIS_CACHE_URL="redis://:${REDIS_PASS}@${REDIS_HOST}:${REDIS_CACHE_PORT}"
REDIS_QUEUE_URL="redis://:${REDIS_PASS}@${REDIS_HOST}:${REDIS_QUEUE_PORT}"
REDIS_SOCKETIO_URL="redis://:${REDIS_PASS}@${REDIS_HOST}:${REDIS_SOCKETIO_PORT}"

######################
#     UTIL FUNCS     #
######################
log() {
  local ts
  ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

  printf '%s [%s] %s\n' \
    "${ts}" \
    "${SITE:-unknown-site}" \
    "$*"
}

cleanup_on_exit() {
  local status=$?
  set +e
  if [[ ${status} -ne 0 ]]; then
    log "Entrypoint: Exiting With Failure Status ${status}."
  else
    log "Entrypoint: Exiting Successfully."
  fi
}

trap cleanup_on_exit EXIT INT TERM

log "Starting Entrypoint....."

#############################
#     Pre-Flight Checks     #
#############################
redis_ping() {
  local HOST="$1"
  local PORT="$2"

  REDISCLI_AUTH="${REDIS_PASS:-}" \
    redis-cli -h "${HOST}" -p "${PORT}" PING
}

check_redis() {
  local FAILED=0
  local HOST="${REDIS_HOST}"
  local CHECKS=(
    "CACHE:${REDIS_CACHE_PORT}"
    "QUEUE:${REDIS_QUEUE_PORT}"
    "SOCKETIO:${REDIS_SOCKETIO_PORT}"
  )

  for ENTRY in "${CHECKS[@]}"; do
    IFS=':' read -r NAME PORT <<< "${ENTRY}"

    if redis_ping "${HOST}" "${PORT}" >/dev/null 2>&1; then
      log "Redis ${NAME} Check: OK."
    else
      log "ERROR: Redis ${NAME} connection/authentication failed (${HOST}:${PORT})."
      FAILED=1
    fi
  done

  return "${FAILED}"
}

check_mariadb() {
  local HOST="${DB_HOST}"
  local PORT="${DB_PORT}"

  if MYSQL_PWD="${DB_ROOT_PASS}" \
     mysql -h "${HOST}" -P "${PORT}" -u "${DB_ROOT_USER}" \
     -e "SELECT 1;" >/dev/null 2>&1; then
    log "MariaDB Check: OK."
    return 0
  fi

  log "ERROR: MariaDB connection/authentication failed (${HOST}:${PORT})."
  return 1
}

check_postgres() {
  local HOST="${DB_HOST}"
  local PORT="${DB_PORT}"

  if PGPASSWORD="${DB_ROOT_PASS}" \
     psql "host=${HOST} port=${PORT} user=${DB_ROOT_USER} dbname=postgres" \
     -c "SELECT 1;" >/dev/null 2>&1; then
    log "Postgres Check OK."
    return 0
  fi

  log "ERROR: Postgres connection/authentication failed (${HOST}:${PORT})."
  return 1
}

check_db() {
  case "${DB_TYPE,,}" in
    mariadb|mysql)
      check_mariadb
      ;;
    postgres)
      check_postgres
      ;;
    *)
      log "ERROR: Unsupported DB_TYPE: ${DB_TYPE}."
      return 2
      ;;
  esac
}

log "Starting preflight checks for redis and ${DB_TYPE} readiness."

if ! check_redis; then
  rc=$?
  log "One or more Redis checks failed (rc=${rc}). Exiting."
  exit "${rc}"
fi

if ! check_db; then
  rc=$?
  log "Database checks failed (rc=${rc}). Exiting."
  exit "${rc}"
fi

log "Preflight checks for redis and ${DB_TYPE} done."

###############################
#   BENCH + SETUP TEMPLATE    #
###############################
if [[ -d "${BENCH_TEMPLATE_DIR}" ]]; then

  if [[ ! -d "${BENCH_DIR}" ]]; then
    log "Bench Directory (${BENCH_DIR}) does not exist; creating."
    mkdir -p "${BENCH_DIR}"
    chown frappe:frappe "${BENCH_DIR}"
  fi

  if command -v mountpoint >/dev/null 2>&1; then
    if mountpoint -q "${BENCH_DIR}"; then
      log "Bench Directory (${BENCH_DIR}) is a mountpoint, likely NFS."
    else
      log "Bench Directory (${BENCH_DIR}) is not a mountpoint; continuing anyway."
    fi
  fi

  if [[ -z "$(ls -A "${BENCH_DIR}" 2>/dev/null || true)" ]]; then
    log "Bench Directory (${BENCH_DIR}) is empty; seeding from Bench Template Directory (${BENCH_TEMPLATE_DIR})."
    cp -a "${BENCH_TEMPLATE_DIR}/." "${BENCH_DIR}/"
    chown -R frappe:frappe "${BENCH_DIR}"
  else
    log "Bench Directory (${BENCH_DIR}) is not empty; skipping seeding from template."
  fi
else
  log "Bench Template Directory ${BENCH_TEMPLATE_DIR} not found; skipping seeding."
fi

################################
#     GLOBAL BENCH CONFIG      #
################################
gosu frappe bash -lc '
  set -euo pipefail
  cd "'"${BENCH_DIR}"'"
  bench set-config -g redis_cache    "'"${REDIS_CACHE_URL}"'"
  bench set-config -g redis_queue    "'"${REDIS_QUEUE_URL}"'"
  bench set-config -g redis_socketio "'"${REDIS_SOCKETIO_URL}"'"
  bench set-config -g db_host "'"${DB_HOST}"'"
  bench set-config -g db_port "'"${DB_PORT}"'"
'

######################
#     SITE INIT      #
######################
if [[ ! -d "${SITE_DIR}" ]]; then
  log "Site directory ${SITE_DIR} not found; creating site ${SITE} (DB_TYPE=${DB_TYPE})."

  DB_ENGINE_FLAGS=()
  if [[ "${DB_TYPE,,}" == "mariadb" || "${DB_TYPE,,}" == "mysql" ]]; then
    DB_ENGINE_FLAGS+=( --no-mariadb-socket )
  fi

  DB_ROOT_PW_FLAG=( --db-root-password "${DB_ROOT_PASS}" )
  DB_NAME_FLAG=( --db-name "${DB_NAME}" )
  DB_PASS_FLAG=( --db-password "${DB_PASS}" )

  set +e
  gosu frappe bash -c '
    set -euo pipefail
    cd "$1"
    shift
    exec "$@"
  ' _ "${BENCH_DIR}" \
    bench new-site "${SITE}" \
      --db-type "${DB_TYPE}" \
      --db-host "${DB_HOST}" \
      --db-port "${DB_PORT}" \
      --db-root-username "${DB_ROOT_USER}" \
      --admin-password "${ADMIN_PASS}" \
      --force \
      "${DB_ENGINE_FLAGS[@]}" \
      "${DB_ROOT_PW_FLAG[@]}" \
      "${DB_NAME_FLAG[@]}" \
      "${DB_PASS_FLAG[@]}"
  rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    log "Site Creation failed with code ${rc}."
    exit "${rc}"
  fi
else
  log "Site directory ${SITE_DIR} already exists; running bench use ${SITE}."
  set +e
  gosu frappe bash -lc "cd '${BENCH_DIR}'; bench use '${SITE}'"
  rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    log "bench use '${SITE}' failed with code ${rc}."
    exit "${rc}"
  fi
fi

########################
#     INSTALL APPS     #
########################
is_app_installed() {
  local NEEDLE="$1"; shift
  for ITEM in "$@"; do
    [[ "$ITEM" == "$NEEDLE" ]] && return 0
  done
  return 1
}

log "Ensuring all apps specified in env are installed on site ${SITE}."

IFS=$'\n' read -r -d '' -a requested_apps < <(
  printf '%s\n' "${APPS//,/ }" \
    | awk '{$1=$1};1' \
    | tr ' ' '\n' \
    | sed '/^$/d' && printf '\0'
)

if [[ ${#requested_apps[@]} -eq 0 ]]; then
  log "No apps specified in env; nothing to install."
else
  log "Fetching list of apps already installed on site ${SITE}."

  set +e
  installed_apps_json=$(gosu frappe bash -lc "cd '${BENCH_DIR}'; bench --site '${SITE}' list-apps --format json")
  rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    log "Fetching list of installed apps failed with code ${rc}."
    exit "${rc}"
  fi

  IFS=$'\n' read -r -d '' -a installed_apps < <(
    {
      printf '%s\n' "${installed_apps_json}" \
        | jq -r --arg site "${SITE}" '
            if type == "array" then
              .[]
            elif type == "object" and has($site) then
              .[$site][]
            else empty end
          ' 2>/dev/null || true
      printf '\0'
    }
  )

  for app in "${requested_apps[@]}"; do
    [[ -z "$app" ]] && continue

    if is_app_installed "$app" "${installed_apps[@]}"; then
      log "App '${app}' already installed; skipping."
      continue
    fi

    log "Installing missing app '${app}' on site ${SITE}."

    set +e
    gosu frappe bash -lc "cd '${BENCH_DIR}'; bench --site '${SITE}' install-app '${app}'"
    rc=$?
    set -e

    if [[ $rc -ne 0 ]]; then
      log "App installation failed for ${app} with code ${rc}."
      exit "${rc}"
    fi

    log "Successfully installed app: ${app}"
  done
fi

######################
#     MIGRATIONS     #
######################
log "Running bench migrate for ${SITE}."

set +e
gosu frappe bash -lc "cd '${BENCH_DIR}'; bench --site '${SITE}' migrate"
rc=$?
set -e

if [[ $rc -ne 0 ]]; then
  log "Migration failed with code ${rc}."
  exit "${rc}"
fi

########################
#     ASSETS BUILD     #
########################
log "Building assets for ${SITE}."

rm -rf "${SITES_DIR}/assets/.webassets-cache" 2>/dev/null || true

set +e
gosu frappe bash -lc "set -e; cd '${BENCH_DIR}'; bench build --production"
rc=$?
set -e

if [[ $rc -ne 0 ]]; then
  log "Assets Build failed with code ${rc}."
  exit "${rc}"
fi

#######################
#     CLEAR CACHE     #
#######################
log "Clearing caches for ${SITE}."

set +e
gosu frappe bash -lc "set -e; cd '${BENCH_DIR}'; \
  bench --site '${SITE}' clear-cache; \
  bench --site '${SITE}' clear-website-cache"
rc=$?
set -e

if [[ $rc -ne 0 ]]; then
  log "Clear Cache failed with code ${rc}."
  exit "${rc}"
fi

#########################
#     INIT COMPLETE     #
#########################
log "Init Finished Successfully."
exit 0
