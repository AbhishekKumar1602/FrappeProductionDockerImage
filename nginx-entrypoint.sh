#!/bin/bash
set -e

####################
#     DEFAULTS     #
####################
: "${BACKEND:=127.0.0.1:8000}"
: "${SOCKETIO:=127.0.0.1:9000}"
: "${UPSTREAM_REAL_IP_ADDRESS:=127.0.0.1}"
: "${UPSTREAM_REAL_IP_HEADER:=X-Forwarded-For}"
: "${UPSTREAM_REAL_IP_RECURSIVE:=off}"
: "${PROXY_READ_TIMEOUT:=120}"
: "${CLIENT_MAX_BODY_SIZE:=50m}"

################################
#     SITE HEADER FALLBACK     #
################################
if [ -z "${SITE+x}" ] || [ -z "${SITE}" ]; then
  SITE='$host'
fi

#######################
#     EXPORT VARS     #
#######################
export BACKEND SOCKETIO UPSTREAM_REAL_IP_ADDRESS UPSTREAM_REAL_IP_HEADER \
       UPSTREAM_REAL_IP_RECURSIVE SITE PROXY_READ_TIMEOUT \
       CLIENT_MAX_BODY_SIZE

##############################
#     GENERATE CONF FILE     #
##############################
mkdir -p /etc/nginx/conf.d
envsubst '${BACKEND}
  ${SOCKETIO}
  ${UPSTREAM_REAL_IP_ADDRESS}
  ${UPSTREAM_REAL_IP_HEADER}
  ${UPSTREAM_REAL_IP_RECURSIVE}
  ${SITE}
  ${PROXY_READ_TIMEOUT}
  ${CLIENT_MAX_BODY_SIZE}' \
  </templates/nginx/frappe.conf.template >/etc/nginx/conf.d/frappe.conf

#######################
#     START NGINX     #
#######################
exec /usr/sbin/nginx -g 'daemon off;'
