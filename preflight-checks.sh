#!/usr/bin/env bash
set -euo pipefail

DB_TYPE=${DB_TYPE:-mariadb}
DB_HOST=${DB_HOST:-192.168.10.164}
DB_PORT=${DB_PORT:-3306}
DB_ROOT_USER=${DB_ROOT_USER:-root}
DB_ROOT_PASS=${DB_ROOT_PASS:-"Root@9223#"}

REDIS_HOST=${REDIS_HOST:-192.168.10.164}
REDIS_PASS=${REDIS_PASS:-RedisPass9223}
REDIS_CACHE_PORT=${REDIS_CACHE_PORT:-6379}
REDIS_QUEUE_PORT=${REDIS_QUEUE_PORT:-6380}
REDIS_SOCKETIO_PORT=${REDIS_SOCKETIO_PORT:-6381}

#############################
#     Pre-Flight Checks     #
#############################



REDIS_CACHE_URL="redis://:${REDIS_PASS}@${REDIS_HOST}:${REDIS_CACHE_PORT}"
REDIS_QUEUE_URL="redis://:${REDIS_PASS}@${REDIS_HOST}:${REDIS_QUEUE_PORT}"
REDIS_SOCKETIO_URL="redis://:${REDIS_PASS}@${REDIS_HOST}:${REDIS_SOCKETIO_PORT}"

LOCK_REDIS_HOST="${LOCK_REDIS_HOST:-${REDIS_HOST}}"
LOCK_REDIS_PORT="${LOCK_REDIS_PORT:-${REDIS_QUEUE_PORT}}"
LOCK_REDIS_PASS="${LOCK_REDIS_PASS:-${REDIS_PASS}}"

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

LEADER_LOCK_TOKEN=""
MIGRATE_LOCK_TOKEN=""
LOCKS_TO_CLEAN=()

register_lock_for_cleanup() {
  local lock="$1"
  for k in "${LOCKS_TO_CLEAN[@]:-}"; do
    [ "$k" = "$lock" ] && return
  done
  LOCKS_TO_CLEAN+=("$lock")
}

cleanup_on_exit() {
  set +e
  echo "Entrypoint: running cleanup_on_exit()"

  for lock in "${LOCKS_TO_CLEAN[@]:-}"; do
    stop_heartbeat "$lock" || true
  done

  if [[ -n "${LEADER_LOCK_TOKEN:-}" ]]; then
    echo "Releasing leader lock (${LOCK_LEADER})"
    redis_lock_release "${LOCK_LEADER}" "${LEADER_LOCK_TOKEN}" || true
    LEADER_LOCK_TOKEN=""
  fi

  if [[ -n "${MIGRATE_LOCK_TOKEN:-}" ]]; then
    echo "Releasing migrate lock (${LOCK_MIGRATE})"
    redis_lock_release "${LOCK_MIGRATE}" "${MIGRATE_LOCK_TOKEN}" || true
    MIGRATE_LOCK_TOKEN=""
  fi
}
trap cleanup_on_exit EXIT INT TERM

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

    log "ERROR: Redis ${name} connection or authentication failed (${REDIS_HOST}:${port})"
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
    log "ERROR: Database connection or authentication failed (${DB_HOST}:${DB_PORT})"
    return 1
  fi
}

check_postgres() {
  if PGPASSWORD="${DB_ROOT_PASS}" \
     psql "host=${DB_HOST} port=${DB_PORT} user=${DB_ROOT_USER} dbname=postgres" \
     -c "SELECT 1;" >/dev/null 2>&1; then
    return 0
  else
    log "ERROR: Database connection or authentication failed (${DB_HOST}:${DB_PORT})"
    return 1
  fi
}

check_db() {
  case "${DB_TYPE,,}" in
    mariadb) check_mariadb ;;
    postgres) check_postgres ;;
    *) log "ERROR: Unsupported DB_TYPE: ${DB_TYPE}"; return 2 ;;
  esac
}

log "Starting pre-flight checks for redis server and database readiness..."

if ! check_redis; then
  rc=$?
  log "One or more redis checks failed (rc=${rc}). Exiting."
  exit "$rc"
fi

if ! check_db; then
  rc=$?
  log "Database checks failed (rc=${rc}). Exiting."
  exit "$rc"
fi

log "Pre-flight checks for redis server and database done."
