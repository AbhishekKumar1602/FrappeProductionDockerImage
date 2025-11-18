#!/bin/bash
set -euo pipefail

#########################
#     CONFIGURATION     #
#########################
: "${REDIS_PASSWORD:?REDIS_PASSWORD Environment Variable Not Set}"

REDIS_USER="redis"
REDIS_GROUP="redis"

declare -A INSTANCES=(
  ["cache"]="6379"
  ["queue"]="6380"
  ["socketio"]="6381"
)

REDIS_BIN="/usr/bin/redis-server"
REDIS_CLI="/usr/bin/redis-cli"
BASE_CONF="/etc/redis/redis.conf"

LOG_DIR="/var/log/redis"
RUN_DIR="/run/redis"

#####################
#     FUNCTIONS     #
#####################
set_redis_conf() {
  local key="$1"
  local value="$2"
  local file="$3"

  # Remove ALL existing occurrences of the key (idempotent)
  sed -i "/^[[:space:]]*${key}\b/d" "$file"

  # Append clean directive
  echo "${key} ${value}" >> "$file"
}

######################
#     PRE-CHECKS     #
######################
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Run this script as root"
  exit 1
fi

echo "Pre-flight checks..."

###########################################
#     DETECT EXISTING REDIS INSTANCES     #
###########################################
if ss -lntp | grep -q redis-server; then
  echo ""
  echo "Existing Redis instances detected:"
  ss -lntp | grep redis-server || true
  echo ""
  read -rp "Do you want to REMOVE ALL existing Redis instances and continue? (Yes/No): " CONFIRM

  if [[ "$CONFIRM" != "Yes" ]]; then
    echo "Aborting as requested."
    exit 1
  fi

  echo ""
  echo "Removing all existing Redis instances..."

  systemctl stop redis-server || true
  systemctl disable redis-server || true
  systemctl mask redis-server || true

  for svc in /etc/systemd/system/redis-*.service; do
    [[ -e "$svc" ]] || continue
    systemctl stop "$(basename "$svc")" || true
    systemctl disable "$(basename "$svc")" || true
    rm -f "$svc"
  done

  systemctl daemon-reload
  systemctl daemon-reexec

  pkill -9 redis-server || true

  apt purge -y redis-server redis-tools || true
  apt autoremove -y || true

  rm -rf /etc/redis /var/lib/redis* /var/log/redis /run/redis

  echo "Existing Redis completely removed"
  echo ""
fi

#########################
#     INSTALL REDIS     #
#########################
echo "Installing Redis..."
apt update
apt install -y redis-server redis-toolsexpadmin@EXP-D-0253:~/Public/FrappeProductionDockerImage$ 

################################################
#     DISABLE DEFAULT UBUNTU REDIS SERVICE     #
################################################
systemctl stop redis-server || true
systemctl disable redis-server || true
systemctl mask redis-server || true

#######################################
#     CREATE REQUIRED DIRECTORIES     #
#######################################
mkdir -p "$LOG_DIR" "$RUN_DIR"
chown -R ${REDIS_USER}:${REDIS_GROUP} "$LOG_DIR" "$RUN_DIR"
chmod 750 "$LOG_DIR"

#####################################
#     CONFIGURE REDIS INSTANCES     #
#####################################
for NAME in "${!INSTANCES[@]}"; do
  PORT="${INSTANCES[$NAME]}"

  CONF="/etc/redis/redis-${NAME}.conf"
  DATA_DIR="/var/lib/redis-${NAME}"
  LOG_FILE="${LOG_DIR}/redis-${NAME}.log"
  PID_FILE="${RUN_DIR}/redis-${NAME}.pid"
  SERVICE="/etc/systemd/system/redis-${NAME}.service"

  echo "Configuring Redis instance '${NAME}' on port ${PORT}"

  cp "$BASE_CONF" "$CONF"

  ###############################
  #     REDIS CONFIGURATION     #
  ###############################
  set_redis_conf bind "0.0.0.0" "$CONF"
  set_redis_conf port "${PORT}" "$CONF"
  set_redis_conf protected-mode "no" "$CONF"

  set_redis_conf daemonize "no" "$CONF"
  set_redis_conf supervised "systemd" "$CONF"

  set_redis_conf pidfile "${PID_FILE}" "$CONF"
  set_redis_conf logfile "${LOG_FILE}" "$CONF"
  set_redis_conf dir "${DATA_DIR}" "$CONF"

  ###################################
  #     INSTANCE DATA DIRECTORY     #
  ###################################
  mkdir -p "$DATA_DIR"
  chown -R ${REDIS_USER}:${REDIS_GROUP} "$DATA_DIR"
  chmod 750 "$DATA_DIR"

  ################################
  #     SYSTEMD SERVICE FILE     #
  ################################
  cat > "$SERVICE" <<EOF
[Unit]
Description=Redis Instance (${NAME})
After=network.target
Conflicts=redis-server.service

[Service]
Type=notify
User=${REDIS_USER}
Group=${REDIS_GROUP}

ExecStart=${REDIS_BIN} ${CONF} --requirepass ${REDIS_PASSWORD}
ExecStop=${REDIS_CLI} -a ${REDIS_PASSWORD} -p ${PORT} shutdown

Restart=always
RestartSec=2
LimitNOFILE=100000

[Install]
WantedBy=multi-user.target
EOF

done

################################
#     START REDIS SERVICES     #
################################
systemctl daemon-reload
systemctl daemon-reexec

for NAME in "${!INSTANCES[@]}"; do
  systemctl enable --now redis-${NAME}
done

sleep 2

########################
#     VERIFICATION     #
########################
echo ""
echo "Verifying Redis instances..."

for NAME in "${!INSTANCES[@]}"; do
  PORT="${INSTANCES[$NAME]}"
  echo -n "Redis ${NAME} (${PORT}): "
  ${REDIS_CLI} -h 127.0.0.1 -p "${PORT}" -a "${REDIS_PASSWORD}" ping
done

echo ""
echo "Redis multi-instance setup completed successfully."
