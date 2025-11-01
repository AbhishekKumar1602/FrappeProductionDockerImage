docker buildx build \
  --no-cache-filter=builder \
  --build-arg APPS_JSON_BASE64="$(base64 -w0 apps.json)" \
  -t frappe-prod-image:latest .


docker volume create frappe_sites
docker volume create frappe_logs

docker rm -f frappe-a >/dev/null 2>&1 || true

docker run -d \
  --name frappe-a \
  --env-file .env \
  -p 8081:80 \
  -v frappe_sites:/home/frappe/frappe-bench/sites \
  -v frappe_logs:/home/frappe/frappe-bench/logs \
  --restart unless-stopped \
  frappe-prod-image:latest

docker logs -f frappe-a

docker rm -f frappe-b >/dev/null 2>&1 || true

docker run -d \
  --name frappe-b \
  --env-file .env \
  -p 8082:80 \
  -v frappe_sites:/home/frappe/frappe-bench/sites \
  -v frappe_logs:/home/frappe/frappe-bench/logs \
  --restart unless-stopped \
  frappe-prod-image:latest

docker logs -f frappe-b