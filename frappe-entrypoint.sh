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
: "${DB_NAME:=}"
: "${DB_PASS:=}"

############################
#     BEHAVIOR TOGGLES     #
############################
: "${RUN_MIGRATIONS_ON_BOOT:=leader}"
: "${IMAGE_REV:?IMAGE_REV is required}"
: "${APPS:=}"
: "${SKIP_INIT:=0}"
: "${AUTO_INSTALL_NEW_APPS:=0}"
: "${AUTO_APPS_ALLOWLIST:=}"
: "${AUTO_APPS_DENYLIST:=}"
: "${REBUILD_ASSETS_ON_BOOT:=auto}"

#################################
#     LEADER/WATCH SETTINGS     #
#################################
: "${LEADER_ELECTION_TIMEOUT:=2}"
: "${MIGRATION_LOCK_TIMEOUT:=180}"
: "${FOLLOWER_WAIT_SECS:=0}"
: "${LOCK_HEARTBEAT_SECS:=30}"
: "${LOCK_RENEW_TTL_SECS:=300}"

################################
#     MANUAL ROLE OVERRIDE     #
################################
: "${IS_LEADER:=}"

########################
#     REDIS CONFIG     #
########################
: "${REDIS_HOST:?REDIS_HOST is required}"
: "${REDIS_PASS:?REDIS_PASS is required}"
: "${REDIS_CACHE_PORT:?REDIS_CACHE_PORT is required}"
: "${REDIS_QUEUE_PORT:?REDIS_QUEUE_PORT is required}"
: "${REDIS_SOCKETIO_PORT:?REDIS_SOCKETIO_PORT is required}"

REDIS_CACHE_URL="redis://:${REDIS_PASS}@${REDIS_HOST}:${REDIS_CACHE_PORT}"
REDIS_QUEUE_URL="redis://:${REDIS_PASS}@${REDIS_HOST}:${REDIS_QUEUE_PORT}"
REDIS_SOCKETIO_URL="redis://:${REDIS_PASS}@${REDIS_HOST}:${REDIS_SOCKETIO_PORT}"

LOCK_REDIS_HOST="${LOCK_REDIS_HOST:-${REDIS_HOST}}"
LOCK_REDIS_PORT="${LOCK_REDIS_PORT:-${REDIS_QUEUE_PORT}}"
LOCK_REDIS_PASS="${LOCK_REDIS_PASS:-${REDIS_PASS}}"

##################################
#     PATHS, LOCKS & MARKERS     #
##################################
SITE_DIR="${SITES_DIR}/${SITE}"
LOCK_LEADER="frappe:leader:${SITE}:${IMAGE_REV}"
LOCK_MIGRATE="frappe:migrate:${SITE}"
MIGRATION_MARKER="${SITES_DIR}/.migrated_${IMAGE_REV}"
ASSETS_MARKER="${SITES_DIR}/.assets_built_${IMAGE_REV}"
SITE_FILE_LOCK="${SITE_DIR}/locks/bench_migrate.lock"
INIT_FS_LOCK="${SITES_DIR}/.lock.init_${IMAGE_REV}"

###################
#     HELPERS     #
###################
wait_for_tcp() {
  local host="$1" port="$2" tries="${3:-120}"
  for i in $(seq 1 "$tries"); do
    (echo > /dev/tcp/"$host"/"$port") >/dev/null 2>&1 && return 0
    echo "Waiting for $host:$port ($i/$tries)..." ; sleep 2
  done
  echo "ERROR: $host:$port not reachable"; exit 1
}
extract_host() { local u="$1"; u="${u#*://}"; u="${u#*@}"; printf '%s\n' "${u%%:*}"; }
extract_port() { local u="$1"; printf '%s\n' "${u##*:}"; }
wait_for_marker_forever() {
  local marker="$1" what="$2" ; local slept=0
  echo "Waiting indefinitely for ${what} marker: ${marker}"
  while [[ ! -f "${marker}" ]]; do
    sleep 2; slept=$((slept+2))
    if (( slept % 60 == 0 )); then
      echo "…still waiting for ${what} (marker ${marker} not present; ${slept}s elapsed)"
    fi
  done
}
uuid() { (cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || openssl rand -hex 16) | tr -d '\n'; }

###################################
#     REDIS LOCKS + HEARTBEAT     #
###################################
if ! command -v redis-cli >/dev/null 2>&1; then
  echo "ERROR: redis-cli not found; required for leader election."
  exit 1
fi

redis_cli() {
  local args=(-h "${LOCK_REDIS_HOST}" -p "${LOCK_REDIS_PORT}" --no-auth-warning)
  [ -n "${LOCK_REDIS_PASS}" ] && args+=( -a "${LOCK_REDIS_PASS}" )
  redis-cli "${args[@]}" "$@"
}

if ! redis_cli PING >/dev/null 2>&1; then
  echo "ERROR: Cannot AUTH to lock Redis at ${LOCK_REDIS_HOST}:${LOCK_REDIS_PORT}."
  exit 1
fi
echo "Using lock Redis ${LOCK_REDIS_HOST}:${LOCK_REDIS_PORT} (auth OK)"

redis_lock_acquire() {
  local key="$1" wait_secs="${2:-10}" ttl_secs="${3:-$LOCK_RENEW_TTL_SECS}"
  local token; token="$(uuid)"
  local start now init_ttl="$ttl_secs"
  (( init_ttl < LOCK_RENEW_TTL_SECS )) && init_ttl="$LOCK_RENEW_TTL_SECS"
  (( init_ttl < wait_secs )) && init_ttl="$wait_secs"
  start=$(date +%s)
  while true; do
    if [[ "$(redis_cli SET "$key" "$token" NX EX "$init_ttl")" == "OK" ]]; then
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
  redis_cli EVAL "$lua" 1 "$key" "$token" >/dev/null 2>&1 || true
}

redis_lock_renew() {
  local key="$1" token="$2" ttl="$3"
  local lua='if redis.call("GET", KEYS[1]) == ARGV[1] then return redis.call("EXPIRE", KEYS[1], ARGV[2]) else return 0 end'
  redis_cli EVAL "$lua" 1 "$key" "$token" "$ttl" 2>/dev/null | grep -q '^1$'
}

LOCK_HB_DIR="/tmp/lock-heartbeats"
mkdir -p "$LOCK_HB_DIR"
start_heartbeat() {
  local key="$1" token="$2" interval="${3:-$LOCK_HEARTBEAT_SECS}" ttl="${4:-$LOCK_RENEW_TTL_SECS}"
  local pidfile="${LOCK_HB_DIR}/$(echo -n "$key" | tr ':/' '__').pid"
  if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then return 0; fi
  (
    set -eu
    while true; do
      local base="$interval"
      local jitter=$(( (RANDOM % (base/5 + 1)) ))
      local sleep_for=$(( base - jitter ))
      sleep "$sleep_for"
      if ! redis_lock_renew "$key" "$token" "$ttl"; then
        echo "Heartbeat: lost lock '${key}' (owner mismatch or expired)"; exit 1
      fi
    done
  ) & echo $! > "$pidfile"
}
stop_heartbeat() {
  local key="$1"; local pidfile="${LOCK_HB_DIR}/$(echo -n "$key" | tr ':/' '__').pid"
  if [[ -f "$pidfile" ]]; then kill "$(cat "$pidfile")" 2>/dev/null || true; rm -f "$pidfile" || true; fi
}

###########################
#     FILESYSTEM PREP     #
###########################
echo "Ensuring permissions on sites/ and logs/"
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

#############################
#     WAIT DEPENDENCIES     #
#############################
echo "Waiting for DB and Redis..."
wait_for_tcp "$DB_HOST" "$DB_PORT"
for url in "$REDIS_CACHE_URL" "$REDIS_QUEUE_URL" "$REDIS_SOCKETIO_URL"; do
  host=$(extract_host "$url"); port=$(extract_port "$url"); wait_for_tcp "$host" "$port"
done
wait_for_tcp "$LOCK_REDIS_HOST" "$LOCK_REDIS_PORT"

###############################
#     GLOBAL BENCH CONFIG     #
###############################
gosu frappe bash -lc "
  set -euo pipefail
  cd '${BENCH_DIR}'
  bench set-config -g redis_cache    '${REDIS_CACHE_URL}'
  bench set-config -g redis_queue    '${REDIS_QUEUE_URL}'
  bench set-config -g redis_socketio '${REDIS_SOCKETIO_URL}'
  bench set-config -g db_host '${DB_HOST}'
  bench set-config -g db_port '${DB_PORT}'
"

###########################
#     LEADER ELECTION     #
###########################
ROLE="follower"
LEADER_LOCK_TOKEN=""

if [[ -n "${IS_LEADER}" ]]; then
  if [[ "${IS_LEADER}" == "1" ]]; then
    ROLE="leader"
    echo "Manual role override: LEADER"
  else
    ROLE="follower"
    echo "Manual role override: FOLLOWER"
  fi
else
  echo "Electing leader with Redis lock '${LOCK_LEADER}' (timeout ${LEADER_ELECTION_TIMEOUT}s)…"
  if token=$(redis_lock_acquire "${LOCK_LEADER}" "${LEADER_ELECTION_TIMEOUT}" "${LOCK_RENEW_TTL_SECS}"); then
    ROLE="leader"
    LEADER_LOCK_TOKEN="$token"
    echo "This instance is LEADER for ${IMAGE_REV} (token=${LEADER_LOCK_TOKEN})."
    start_heartbeat "${LOCK_LEADER}" "${LEADER_LOCK_TOKEN}" "${LOCK_HEARTBEAT_SECS}" "${LOCK_RENEW_TTL_SECS}"
  else
    ROLE="follower"
    echo "This instance is FOLLOWER (Leader lock held elsewhere)."
  fi
fi

###########################
#     SITE INIT & APPS    #
###########################
if [[ "${ROLE}" == "leader" ]]; then
  if [[ "${SKIP_INIT}" != "1" ]]; then
    if [[ ! -d "${SITE_DIR}" || ! -f "${MIGRATION_MARKER}" ]]; then
      ( set -o noclobber; echo "host=${HOSTNAME} pid=$$ ts=$(date -u +%FT%TZ)" > "${INIT_FS_LOCK}" ) 2>/dev/null || true
      trap 'rm -f "${INIT_FS_LOCK}" >/dev/null 2>&1 || true' EXIT

      if [[ ! -d "${SITE_DIR}" ]]; then
        echo "→ Creating site: ${SITE} (db-type=${DB_TYPE})"

        DB_ENGINE_FLAGS=()
        if [[ "${DB_TYPE,,}" == "mariadb" || "${DB_TYPE,,}" == "mysql" ]]; then
          DB_ENGINE_FLAGS+=( --no-mariadb-socket )
        fi

        DB_ROOT_PW_FLAG=( --db-root-password "${DB_ROOT_PASS}" )

        DB_NAME_FLAG=()
        [[ -n "${DB_NAME}" ]] && DB_NAME_FLAG+=( --db-name "${DB_NAME}" )
        DB_PASS_FLAG=()
        [[ -n "${DB_PASS}" ]] && DB_PASS_FLAG+=( --db-password "${DB_PASS}" )

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
      else
        gosu frappe bash -lc "cd '${BENCH_DIR}'; bench use '${SITE}'"
      fi

      if [[ -n "${APPS}" ]]; then
        echo "Installing apps from APPS env (leader only): ${APPS}"
        for app in ${APPS}; do
          gosu frappe bash -lc "cd '${BENCH_DIR}'; bench --site '${SITE}' install-app \"${app}\""
        done
      fi
    fi
  else
    echo "SKIP_INIT=1 set. Skipping site creation."
  fi
else
  if [[ ! -f "${MIGRATION_MARKER}" ]]; then
    [[ "${FOLLOWER_WAIT_SECS}" -gt 0 ]] && sleep "${FOLLOWER_WAIT_SECS}" || true
    wait_for_marker_forever "${MIGRATION_MARKER}" "migration"
  fi
fi

######################
#     MIGRATIONS     #
######################
if [[ "${RUN_MIGRATIONS_ON_BOOT}" == "leader" ]]; then
  if [[ "${ROLE}" == "leader" ]]; then
    echo "Leader running migrations…"
    if token=$(redis_lock_acquire "${LOCK_MIGRATE}" "${MIGRATION_LOCK_TIMEOUT}" "${LOCK_RENEW_TTL_SECS}"); then
      start_heartbeat "${LOCK_MIGRATE}" "${token}" "${LOCK_HEARTBEAT_SECS}" "${LOCK_RENEW_TTL_SECS}"
      set +e
      gosu frappe bash -lc "cd '${BENCH_DIR}'; bench --site '${SITE}' migrate"
      rc=$?
      set -e
      stop_heartbeat "${LOCK_MIGRATE}"; redis_lock_release "${LOCK_MIGRATE}" "${token}"
      if [[ $rc -ne 0 ]]; then
        echo "bench migrate failed with code $rc"
        exit $rc
      fi
      echo "$(date -u +"%FT%TZ") by ${HOSTNAME}" > "${MIGRATION_MARKER}"
      chown frappe:frappe "${MIGRATION_MARKER}"
      echo "Wrote migration marker ${MIGRATION_MARKER}"
    else
      echo "Could not acquire migrate lock (unexpected); skipping migrate."
    fi
  else
    if [[ ! -f "${MIGRATION_MARKER}" ]]; then
      [[ "${FOLLOWER_WAIT_SECS}" -gt 0 ]] && sleep "${FOLLOWER_WAIT_SECS}" || true
      wait_for_marker_forever "${MIGRATION_MARKER}" "migration"
    fi
  fi
else
  echo "RUN_MIGRATIONS_ON_BOOT != leader; skipping automatic migrate."
fi

#############################
#     AUTO-INSTALL APPS     #
#############################
if [[ "${AUTO_INSTALL_NEW_APPS}" == "1" && "${ROLE}" == "leader" ]]; then
  echo "Leader auto-discovery for baked apps enabled. Checking…"
  baked_apps=$(bash -lc "cd '${BENCH_DIR}/apps' && ls -1d */ 2>/dev/null | sed 's#/##' | grep -v '^frappe$' || true")
  if [[ -n "${AUTO_APPS_ALLOWLIST}" ]]; then baked_apps="${AUTO_APPS_ALLOWLIST}"; fi
  if [[ -n "${AUTO_APPS_DENYLIST}" ]]; then
    for deny in ${AUTO_APPS_DENYLIST}; do
      baked_apps="$(echo "${baked_apps}" | tr ' ' '\n' | grep -vx "${deny}" || true)"
    done
  fi
  installed_apps=$(gosu frappe bash -lc "cd '${BENCH_DIR}'; bench --site '${SITE}' list-apps --json" | jq -r '.[]? // empty')
  did_install_any=0
  for app in ${baked_apps}; do
    if ! echo "${installed_apps}" | grep -qx "${app}"; then
      echo "Leader installing newly baked app: ${app}"
      gosu frappe bash -lc "cd '${BENCH_DIR}'; bench --site '${SITE}' install-app '${app}'"
      did_install_any=1
    fi
  done
  if [[ "${did_install_any}" == "1" ]]; then
    echo "Leader running migrate after new app installs…"
    gosu frappe bash -lc "cd '${BENCH_DIR}'; bench --site '${SITE}' migrate"
    echo "$(date -u +"%FT%TZ") by ${HOSTNAME}" > "${MIGRATION_MARKER}"
    chown frappe:frappe "${MIGRATION_MARKER}"
  fi
fi

##########################
#     ASSETS REFRESH     #
##########################
need_build=0
case "${REBUILD_ASSETS_ON_BOOT}" in
  1|"true"|"yes") need_build=1 ;;
  0|"false"|"no")  need_build=0 ;;
  auto) [[ ! -s "${SITES_DIR}/assets/manifest.json" ]] && need_build=1 || need_build=0 ;;
  *)    [[ ! -s "${SITES_DIR}/assets/manifest.json" ]] && need_build=1 || need_build=0 ;;
esac

if [[ "${ROLE}" == "leader" ]]; then
  if [[ "${need_build}" == "1" || ! -f "${ASSETS_MARKER}" ]]; then
    echo "Leader rebuilding assets…"
    rm -rf "${SITES_DIR}/assets/.webassets-cache" 2>/dev/null || true
    gosu frappe bash -lc "set -e; cd '${BENCH_DIR}'; bench build --production"
    echo "$(date -u +"%FT%TZ") by ${HOSTNAME}" > "${ASSETS_MARKER}"
    chown frappe:frappe "${ASSETS_MARKER}"
    echo "Assets rebuilt and marker written: ${ASSETS_MARKER}"
  else
    echo "Assets up-to-date; skipping build."
  fi
else
  if [[ ! -f "${ASSETS_MARKER}" ]]; then
    [[ "${FOLLOWER_WAIT_SECS}" -gt 0 ]] && sleep "${FOLLOWER_WAIT_SECS}" || true
    wait_for_marker_forever "${ASSETS_MARKER}" "assets"
  fi
fi

###############################
#     RELEASE LEADER LOCK     #
###############################
if [[ -n "${LEADER_LOCK_TOKEN}" ]]; then
  stop_heartbeat "${LOCK_LEADER}"
  redis_lock_release "${LOCK_LEADER}" "${LEADER_LOCK_TOKEN}"
fi

####################
#     HAND-OFF     #
####################
echo "Starting main process (supervisord) as root: $*"
exec "$@"
