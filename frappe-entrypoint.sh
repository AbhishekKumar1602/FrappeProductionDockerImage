#!/usr/bin/env bash
set -euo pipefail

BENCH_DIR="/home/frappe/frappe-bench"
SITES_DIR="${BENCH_DIR}/sites"

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

############################
#     BEHAVIOR TOGGLES     #
############################
: "${IMAGE_REV:?IMAGE_REV is required}"
: "${APPS:=}"
: "${SKIP_INIT:=0}"

#################################
#     LEADER/WATCH SETTINGS     #
#################################
: "${LEADER_ELECTION_TIMEOUT:=2}"
: "${MIGRATION_LOCK_TIMEOUT:=180}"
: "${FOLLOWER_WAIT_SECS:=0}"
: "${LOCK_HEARTBEAT_SECS:=30}"
: "${LOCK_RENEW_TTL_SECS:=300}"

##################################
#     PATHS, LOCKS & MARKERS     #
##################################
SITE_DIR="${SITES_DIR}/${SITE}"
LOCK_LEADER="frappe:leader:${SITE}:${IMAGE_REV}"
LOCK_MIGRATE="frappe:migrate:${SITE}"
MIGRATION_MARKER="${SITES_DIR}/.migrated_${IMAGE_REV}"
ASSETS_MARKER="${SITES_DIR}/.assets_built_${IMAGE_REV}"
APPS_MARKER="${SITES_DIR}/.apps_installed_${IMAGE_REV}"
INIT_FS_LOCK="${SITES_DIR}/.lock.init_${IMAGE_REV}"

########################
#     REDIS CONFIG     #
########################
REDIS_CACHE_URL="redis://:${REDIS_PASS}@${REDIS_HOST}:${REDIS_CACHE_PORT}"
REDIS_QUEUE_URL="redis://:${REDIS_PASS}@${REDIS_HOST}:${REDIS_QUEUE_PORT}"
REDIS_SOCKETIO_URL="redis://:${REDIS_PASS}@${REDIS_HOST}:${REDIS_SOCKETIO_PORT}"
LOCK_REDIS_HOST="${LOCK_REDIS_HOST:-${REDIS_HOST}}"
LOCK_REDIS_PORT="${LOCK_REDIS_PORT:-${REDIS_QUEUE_PORT}}"
LOCK_REDIS_PASS="${LOCK_REDIS_PASS:-${REDIS_PASS}}"

###########################
#  Helper & Tracking Vars #
###########################
LEADER_LOCK_TOKEN=""
MIGRATE_LOCK_TOKEN=""
LOCKS_TO_CLEAN=()
NEW_SITE_CREATED=0

wait_for_marker_forever() {
  local marker="$1" what="$2" ; local slept=0
  log "Waiting for ${what} marker: ${marker}."
  while [[ ! -f "${marker}" ]]; do
    sleep 2; slept=$((slept+2))
    if (( slept % 60 == 0 )); then
      log "Still waiting for ${what} (marker ${marker} not present; ${slept}s elapsed)."
    fi
  done
}

uuid() { (cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || openssl rand -hex 16) | tr -d '\n'; }

redis_cli() {
  local host="$1"; local port="$2"; shift 2
  if [ $# -ge 2 ] && [ "$1" = "-a" ]; then
    local auth_flag=("-a" "$2")
    shift 2
    redis-cli -h "$host" -p "$port" "${auth_flag[@]}" "$@"
  else
    redis-cli -h "$host" -p "$port" "$@"
  fi
}

register_lock_for_cleanup() {
  local lock="$1"
  for k in "${LOCKS_TO_CLEAN[@]:-}"; do
    [ "$k" = "$lock" ] && return
  done
  LOCKS_TO_CLEAN+=("$lock")
}

cleanup_on_exit() {
  set +e
  log "Entrypoint: running cleanup on exit."

  for lock in "${LOCKS_TO_CLEAN[@]:-}"; do
    stop_heartbeat "$lock" || true
  done

  if [[ -n "${LEADER_LOCK_TOKEN:-}" ]]; then
    log "Releasing leader lock (${LOCK_LEADER})."
    redis_lock_release "${LOCK_LEADER}" "${LEADER_LOCK_TOKEN}" || true
    LEADER_LOCK_TOKEN=""
  fi

  if [[ -n "${MIGRATE_LOCK_TOKEN:-}" ]]; then
    log "Releasing migrate lock (${LOCK_MIGRATE})."
    redis_lock_release "${LOCK_MIGRATE}" "${MIGRATE_LOCK_TOKEN}" || true
    MIGRATE_LOCK_TOKEN=""
  fi
}

#############################
#     Pre-Flight Checks     #
#############################
log() { printf '%s %s\n' "$(date -u +'%H:%M:%S')" "$*"; }

check_redis() {
  local failed=0
  local ports_names=(
    "CACHE:${REDIS_CACHE_PORT}"
    "QUEUE:${REDIS_QUEUE_PORT}"
    "SOCKETIO:${REDIS_SOCKETIO_PORT}"
  )

  for np in "${ports_names[@]}"; do
    local name=${np%%:*}
    local port=${np#*:}
    local result=""

    export REDISCLI_AUTH="${REDIS_PASS:-}"
    result="$(redis_cli "${REDIS_HOST}" "${port}" PING 2>/dev/null || true)"
    unset REDISCLI_AUTH

    if [ "${result}" != "PONG" ]; then
      result="$(redis_cli "${REDIS_HOST}" "${port}" -a "${REDIS_PASS}" PING 2>/dev/null || true)"
    fi

    if [ "${result}" = "PONG" ]; then
      continue
    fi

    log "ERROR: Redis ${name} connection/authentication failed (${REDIS_HOST}:${port})."
    failed=1
  done

  return $failed
}

check_mariadb() {
  if MYSQL_PWD="${DB_ROOT_PASS}" \
     mysql -h "${DB_HOST}" -P "${DB_PORT}" -u "${DB_ROOT_USER}" \
     -e "SELECT 1;" >/dev/null 2>&1; then
    return 0
  else
    log "ERROR: Database connection/authentication failed (${DB_HOST}:${DB_PORT})."
    return 1
  fi
}

check_postgres() {
  if PGPASSWORD="${DB_ROOT_PASS}" \
     psql "host=${DB_HOST} port=${DB_PORT} user=${DB_ROOT_USER} dbname=postgres" \
     -c "SELECT 1;" >/dev/null 2>&1; then
    return 0
  else
    log "ERROR: Database connection/authentication failed (${DB_HOST}:${DB_PORT})."
    return 1
  fi
}

check_db() {
  case "${DB_TYPE,,}" in
    mariadb) check_mariadb ;;
    postgres) check_postgres ;;
    *) log "ERROR: Unsupported DB_TYPE: ${DB_TYPE}."; return 2 ;;
  esac
}

log "Starting preflight checks for Redis and database readiness."

if ! check_redis; then
  rc=$?
  log "One or more Redis checks failed (rc=${rc}). Exiting."
  exit "$rc"
fi

if ! check_db; then
  rc=$?
  log "Database checks failed (rc=${rc}). Exiting."
  exit "$rc"
fi

log "Preflight checks for Redis and database done."

###################################
#     REDIS LOCKS + HEARTBEAT     #
###################################
LOCK_HB_DIR="/tmp/lock-heartbeats"
mkdir -p "$LOCK_HB_DIR"
start_heartbeat() {
  local key="$1" token="$2"
  local interval="${3:-$LOCK_HEARTBEAT_SECS}"
  local ttl="${4:-$LOCK_RENEW_TTL_SECS}"
  local pidfile
  pidfile="${LOCK_HB_DIR}/$(echo -n "$key" | tr ':/' '__').pid"

  if [[ -f "$pidfile" ]]; then
    local existing_pid
    existing_pid=$(cat "$pidfile" 2>/dev/null || echo "")
    if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
      return 0
    else
      rm -f "$pidfile" || true
    fi
  fi

  (
    set -eu
    while true; do
      local base="$interval"
      local jitter=$(( (RANDOM % ( (base/5) + 1 )) ))
      local sleep_for=$(( base - jitter ))
      sleep "$sleep_for"
      if ! redis_lock_renew "$key" "$token" "$ttl"; then
        echo "Heartbeat: Lost lock '${key}', owner mismatch or expired."; exit 1
      fi
    done
  ) &

  echo $! > "$pidfile"
  chmod 644 "$pidfile" || true
}

stop_heartbeat() {
  local key="$1"
  local pidfile
  pidfile="${LOCK_HB_DIR}/$(echo -n "$key" | tr ':/' '__').pid"
  if [[ -f "$pidfile" ]]; then
    local pid
    pid=$(cat "$pidfile" 2>/dev/null || echo "")
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      for _ in {1..5}; do
        sleep 0.2
        if ! kill -0 "$pid" 2>/dev/null; then break; fi
      done
    fi
    rm -f "$pidfile" || true
  fi
}

redis_lock_acquire() {
  local key="$1" wait_secs="${2:-10}" ttl_secs="${3:-$LOCK_RENEW_TTL_SECS}"
  local token
  token="$(uuid)"
  local start now init_ttl
  init_ttl="$ttl_secs"
  (( init_ttl < LOCK_RENEW_TTL_SECS )) && init_ttl="$LOCK_RENEW_TTL_SECS"
  (( init_ttl < wait_secs )) && init_ttl="$wait_secs"
  start=$(date +%s)
  while true; do
    if [[ -n "${LOCK_REDIS_PASS:-}" ]]; then
      resp=$(redis_cli "${LOCK_REDIS_HOST}" "${LOCK_REDIS_PORT}" -a "${LOCK_REDIS_PASS}" SET "$key" "$token" NX EX "$init_ttl" 2>/dev/null || true)
    else
      resp=$(redis_cli "${LOCK_REDIS_HOST}" "${LOCK_REDIS_PORT}" SET "$key" "$token" NX EX "$init_ttl" 2>/dev/null || true)
    fi
    if [[ "$resp" == "OK" ]]; then
      echo "$token"; return 0
    fi
    now=$(date +%s)
    (( now - start >= wait_secs )) && { echo ""; return 1; }
    sleep 0.2
  done
}

redis_lock_release() {
  local key="$1" token="$2"; [[ -z "$token" ]] && return 0
  local lua='if redis.call("GET", KEYS[1]) == ARGV[1] then return redis.call("DEL", KEYS[1]) else return 0 end'
  if [[ -n "${LOCK_REDIS_PASS:-}" ]]; then
    redis_cli "${LOCK_REDIS_HOST}" "${LOCK_REDIS_PORT}" -a "${LOCK_REDIS_PASS}" EVAL "$lua" 1 "$key" "$token" >/dev/null 2>&1 || true
  else
    redis_cli "${LOCK_REDIS_HOST}" "${LOCK_REDIS_PORT}" EVAL "$lua" 1 "$key" "$token" >/dev/null 2>&1 || true
  fi
}

redis_lock_renew() {
  local key="$1" token="$2" ttl="$3"
  local lua='if redis.call("GET", KEYS[1]) == ARGV[1] then return redis.call("EXPIRE", KEYS[1], ARGV[2]) else return 0 end'
  if [[ -n "${LOCK_REDIS_PASS:-}" ]]; then
    redis_cli "${LOCK_REDIS_HOST}" "${LOCK_REDIS_PORT}" -a "${LOCK_REDIS_PASS}" EVAL "$lua" 1 "$key" "$token" "$ttl" 2>/dev/null | grep -q '^1$'
  else
    redis_cli "${LOCK_REDIS_HOST}" "${LOCK_REDIS_PORT}" EVAL "$lua" 1 "$key" "$token" "$ttl" 2>/dev/null | grep -q '^1$'
  fi
}

trap cleanup_on_exit EXIT INT TERM

###########################
#     FILESYSTEM PREP     #
###########################
log "Ensuring permissions on sites/ and logs/."
mkdir -p "${SITES_DIR}" "${BENCH_DIR}/logs"
chown -R frappe:frappe "${SITES_DIR}" "${BENCH_DIR}/logs"

mkdir -p /var/log/supervisor /var/run/supervisor
chown -R root:root /var/log/supervisor /var/run/supervisor
chmod 755 /var/log/supervisor /var/run/supervisor

mkdir -p /var/log/nginx /var/lib/nginx
chown -R frappe:frappe /var/log/nginx /var/lib/nginx
if [[ -f /etc/nginx/nginx.conf ]]; then
  grep -qE '^\s*user\s+frappe\s*;' /etc/nginx/nginx.conf || sed -i '1i user frappe;' /etc/nginx/nginx.conf
  if grep -qE '^\s*error_log\s+' /etc/nginx/nginx.conf; then
    sed -ri 's@^\s*error_log\s+[^;]*;@error_log stderr info;@' /etc/nginx/nginx.conf
  else
    sed -i '1i error_log stderr info;' /etc/nginx/nginx.conf
  fi
fi

###########################
#     LEADER ELECTION     #
###########################
ROLE="follower"

log "Electing leader....."
if token=$(redis_lock_acquire "${LOCK_LEADER}" "${LEADER_ELECTION_TIMEOUT}" "${LOCK_RENEW_TTL_SECS}"); then
  ROLE="leader"
  LEADER_LOCK_TOKEN="$token"
  register_lock_for_cleanup "${LOCK_LEADER}"
  log "This instance is LEADER."
  start_heartbeat "${LOCK_LEADER}" "${LEADER_LOCK_TOKEN}" "${LOCK_HEARTBEAT_SECS}" "${LOCK_RENEW_TTL_SECS}"
else
  ROLE="follower"
  log "This instance is a FOLLOWER."
fi

###############################
#     GLOBAL BENCH CONFIG     #
###############################
gosu frappe bash -lc '
  set -euo pipefail
  cd "'"${BENCH_DIR}"'"
  bench set-config -g redis_cache    "'"${REDIS_CACHE_URL}"'"
  bench set-config -g redis_queue    "'"${REDIS_QUEUE_URL}"'"
  bench set-config -g redis_socketio "'"${REDIS_SOCKETIO_URL}"'"
  bench set-config -g db_host "'"${DB_HOST}"'"
  bench set-config -g db_port "'"${DB_PORT}"'"
'

###########################
#     SITE INIT & APPS    #
###########################
if [[ "${ROLE}" == "leader" ]]; then
  if [[ "${SKIP_INIT}" != "1" ]]; then
    if [[ ! -d "${SITE_DIR}" || ! -f "${MIGRATION_MARKER}" ]]; then
      ( set -o noclobber; echo "host=${HOSTNAME} pid=$$ ts=$(date -u +%FT%TZ)" > "${INIT_FS_LOCK}" ) 2>/dev/null || true

      cleanup_and_remove_init_lock() {
        cleanup_on_exit || true
        rm -f "${INIT_FS_LOCK}" >/dev/null 2>&1 || true
      }
      trap cleanup_and_remove_init_lock EXIT INT TERM

      if [[ ! -d "${SITE_DIR}" ]]; then
        log "Creating site: ${SITE} (DB_TYPE=${DB_TYPE})."

        DB_ENGINE_FLAGS=()
        if [[ "${DB_TYPE,,}" == "mariadb" || "${DB_TYPE,,}" == "mysql" ]]; then
          DB_ENGINE_FLAGS+=( --no-mariadb-socket )
        fi

        DB_ROOT_PW_FLAG=( --db-root-password "${DB_ROOT_PASS}" )

        DB_NAME_FLAG=()
        if [[ -n "${DB_NAME}" ]]; then
          DB_NAME_FLAG+=( --db-name "${DB_NAME}" )
        fi
        DB_PASS_FLAG=()
        if [[ -n "${DB_PASS}" ]]; then
          DB_PASS_FLAG+=( --db-password "${DB_PASS}" )
        fi

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

        gosu frappe bash -lc "cd '${BENCH_DIR}'; bench use '${SITE}'"

        NEW_SITE_CREATED=1
        date -u +"%FT%TZ" > "${APPS_MARKER}"
        echo "Created by ${HOSTNAME}" >> "${APPS_MARKER}" || true
        chown frappe:frappe "${APPS_MARKER}" || true
        log "Updated apps marker ${APPS_MARKER}."

      else
        gosu frappe bash -lc "cd '${BENCH_DIR}'; bench use '${SITE}'"
      fi

      if [[ -n "${APPS}" ]]; then
        log "Installing apps: ${APPS}."
        for app in ${APPS}; do
          gosu frappe bash -lc "cd '${BENCH_DIR}'; bench --site '${SITE}' install-app \"${app}\""
        done
      fi
    fi
  else
    log "Site already exists. Skipping site creation."
  fi
fi

######################
#     MIGRATIONS     #
######################
if [[ "${ROLE}" == "leader" ]]; then
  if [[ -f "${MIGRATION_MARKER}" ]]; then
    log "Migration marker ${MIGRATION_MARKER} exists; skipping migrations for IMAGE_REV=${IMAGE_REV}."
  else
    log "Running migrations for IMAGE_REV=${IMAGE_REV}."
    if token=$(redis_lock_acquire "${LOCK_MIGRATE}" "${MIGRATION_LOCK_TIMEOUT}" "${LOCK_RENEW_TTL_SECS}"); then
      MIGRATE_LOCK_TOKEN="$token"
      register_lock_for_cleanup "${LOCK_MIGRATE}"
      start_heartbeat "${LOCK_MIGRATE}" "${MIGRATE_LOCK_TOKEN}" "${LOCK_HEARTBEAT_SECS}" "${LOCK_RENEW_TTL_SECS}"
      set +e
      gosu frappe bash -lc "cd '${BENCH_DIR}'; bench --site '${SITE}' migrate"
      rc=$?
      set -e
      stop_heartbeat "${LOCK_MIGRATE}" || true
      redis_lock_release "${LOCK_MIGRATE}" "${MIGRATE_LOCK_TOKEN}" || true
      MIGRATE_LOCK_TOKEN=""

      if [[ $rc -ne 0 ]]; then
        log "bench migrate failed with code ${rc}."
        exit $rc
      fi

      echo "$(date -u +"%FT%TZ") by ${HOSTNAME}" > "${MIGRATION_MARKER}"
      chown frappe:frappe "${MIGRATION_MARKER}" || true
      log "Migration completed; wrote marker ${MIGRATION_MARKER}."
    else
      log "Could not acquire migrate lock (unexpected); skipping migration."
    fi
  fi
else
  if [[ ! -f "${MIGRATION_MARKER}" ]]; then
    if [[ "${FOLLOWER_WAIT_SECS}" -gt 0 ]]; then
      sleep "${FOLLOWER_WAIT_SECS}"
    fi
    wait_for_marker_forever "${MIGRATION_MARKER}" "migration"
  fi
fi

#############################
#     AUTO-INSTALL APPS     #
#############################
if [[ "${ROLE}" == "leader" && -n "${APPS}" && "${NEW_SITE_CREATED:-0}" -eq 0 ]]; then
  if [[ -f "${APPS_MARKER}" ]]; then
    log "Apps marker ${APPS_MARKER} exists; skipping app installations for IMAGE_REV=${IMAGE_REV}."
  else
    log "Ensuring all apps from .env: ${APPS} are installed."
    installed_apps=$(gosu frappe bash -lc "cd '${BENCH_DIR}'; bench --site '${SITE}' list-apps --format json" | jq -r '.[]? // empty')
    did_install_any=0
    for app in ${APPS}; do
      if ! echo "${installed_apps}" | grep -qx "${app}"; then
        log "Installing missing app: ${app}."
        gosu frappe bash -lc "cd '${BENCH_DIR}'; bench --site '${SITE}' install-app '${app}'"
        did_install_any=1
      fi
    done

    if [[ "${did_install_any}" == "1" ]]; then
      log "Running migration after new app installation."
      gosu frappe bash -lc "cd '${BENCH_DIR}'; bench --site '${SITE}' migrate"
      echo "$(date -u +"%FT%TZ") by ${HOSTNAME}" > "${MIGRATION_MARKER}"
      chown frappe:frappe "${MIGRATION_MARKER}"
    fi
    echo "$(date -u +"%FT%TZ") by ${HOSTNAME}" > "${APPS_MARKER}"
    chown frappe:frappe "${APPS_MARKER}" || true
    log "Missing apps installed; wrote marker ${APPS_MARKER}."
  fi
else
  if [[ "${ROLE}" == "follower" && -n "${APPS}" ]]; then
    if [[ ! -f "${APPS_MARKER}" ]]; then
      if [[ "${FOLLOWER_WAIT_SECS}" -gt 0 ]]; then
        sleep "${FOLLOWER_WAIT_SECS}"
      fi
      wait_for_marker_forever "${APPS_MARKER}" "apps installation"
    fi
  fi
fi

##########################
#     ASSETS REFRESH     #
##########################
if [[ "${ROLE}" == "leader" ]]; then
  if [[ -f "${ASSETS_MARKER}" ]]; then
    log "Assets marker ${ASSETS_MARKER} exists; skipping assets build for IMAGE_REV=${IMAGE_REV}."
  else
    log "Rebuilding assets for IMAGE_REV=${IMAGE_REV}."
    rm -rf "${SITES_DIR}/assets/.webassets-cache" 2>/dev/null || true
    gosu frappe bash -lc "set -e; cd '${BENCH_DIR}'; bench build --production"
    echo "$(date -u +"%FT%TZ") by ${HOSTNAME}" > "${ASSETS_MARKER}"
    chown frappe:frappe "${ASSETS_MARKER}" || true
    log "Assets rebuilt; wrote marker ${ASSETS_MARKER}."
  fi
else
  if [[ ! -f "${ASSETS_MARKER}" ]]; then
    if [[ "${FOLLOWER_WAIT_SECS}" -gt 0 ]]; then
      sleep "${FOLLOWER_WAIT_SECS}"
    fi
    wait_for_marker_forever "${ASSETS_MARKER}" "assets"
  fi
fi

###############################
#     RELEASE LEADER LOCK     #
###############################
if [[ -n "${LEADER_LOCK_TOKEN}" ]]; then
  stop_heartbeat "${LOCK_LEADER}"
  redis_lock_release "${LOCK_LEADER}" "${LEADER_LOCK_TOKEN}"
  LEADER_LOCK_TOKEN=""
fi

####################
#     HAND-OFF     #
####################
log "Starting main process (supervisord) as root: $*."
exec "$@"
