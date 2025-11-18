# **Server Setup Guide (MariaDB/PostgreSQL, Redis Multi-Instance, NFS)**

## **Install and Configure MariaDB**

### Update Package List
```bash
sudo apt update
```

### Install MariaDB Server
```bash
sudo apt install mariadb-server
```

### Start and Enable MariaDB
```bash
sudo systemctl start mariadb
sudo systemctl enable mariadb
```

### Check MariaDB Status
```bash
sudo systemctl status mariadb
```

### Run Secure Installation
```bash
sudo mysql_secure_installation
```

- Follow the Prompts:

```
Enter current root password: (press Enter)
Set root password? Y
Remove anonymous users? Y
Disallow root login remotely? N
Remove test database? Y
Reload privilege tables? Y
```

### Login to MariaDB
```bash
sudo mysql -u root -p
```

- Enter: `<DB_PASSWORD>`

### **Enable Remote Root Access**

### Allow MariaDB to Listen on All Interfaces

- Edit Config:
```bash
sudo nano /etc/mysql/mariadb.conf.d/50-server.cnf
```

- Change:
```
bind-address = 127.0.0.1
```

- To:
```
bind-address = 0.0.0.0
```

- Restart:
```bash
sudo systemctl restart mariadb
```

### Allow Firewall Access
- Allow Specific IP (IP of Machine Running the Container):
```bash
sudo ufw allow from <ALLOWED_IP> to any port 3306 proto tcp
```

### Test Remote Connection
```bash
mysql -h <SERVER_IP> -u root -p
```
Enter: `<DB_PASSWORD>`

## **Install and Configure PostgreSQL**

### Update Package List
```bash
sudo apt update
```

### Install PostgreSQL
```bash
sudo apt install postgresql postgresql-contrib
```

### Start and Enable Service
```bash
sudo systemctl start postgresql
sudo systemctl enable postgresql
```

### Check Service Status
```bash
sudo systemctl status postgresql
```

### **Enable Remote Access**

### Allow Listening on All Interfaces
- Edit Config:
```bash
sudo nano /etc/postgresql/<VERSION>/main/postgresql.conf
```

- Change:
```
#listen_addresses = 'localhost'
```

- To:
```
listen_addresses = '*'
```

### Update pg_hba.conf
- Edit Config:
```bash
sudo nano /etc/postgresql/<VERSION>/main/pg_hba.conf
```

- Add:
```
host    all    all    0.0.0.0/0    md5
```

- Restart:
```bash
sudo systemctl restart postgresql
```

### Set Password for postgres User
```bash
sudo -u postgres psql
```

Run:
```sql
ALTER USER postgres WITH PASSWORD '<POSTGRES_PASSWORD>';
\q
```

### Firewall Access
- Allow Specific IP (IP of Machine Running the Container):
```bash
sudo ufw allow from <ALLOWED_IP> to any port 5432 proto tcp
```

### Test Remote Connection
```bash
psql -h <SERVER_IP> -U postgres -d postgres
```

Enter: `<POSTGRES_PASSWORD>`

## **Setup Redis (Multi-Instance: Cache, Queue, SocketIO)**

### Install Redis
```bash
sudo apt update
sudo apt install -y redis-server redis-tools
```

- Disable Default Instance:
```bash
sudo systemctl disable --now redis-server
```

### **Create Config Files for 3 Redis Instances**
- Base Config: `/etc/redis/redis.conf`

- Create Copies:
```bash
sudo cp /etc/redis/redis.conf /etc/redis/redis-cache.conf
sudo cp /etc/redis/redis.conf /etc/redis/redis-queue.conf
sudo cp /etc/redis/redis.conf /etc/redis/redis-socketio.conf
```

### **Create Data Directories**
```bash
sudo mkdir -p /var/lib/redis-cache /var/lib/redis-queue /var/lib/redis-socketio
sudo chown redis:redis /var/lib/redis-cache /var/lib/redis-queue /var/lib/redis-socketio
```

### **Edit Each Redis Config**
Ports:
* Cache: `6379`
* Queue: `6380`
* SocketIO: `6381`

Password: `<REDIS_PASSWORD>`

**Cache Instance**
```bash
sudo nano /etc/redis/redis-cache.conf
```

- Set:

```
port 6379
bind 0.0.0.0
requirepass <REDIS_PASSWORD>
supervised systemd

pidfile /run/redis-cache.pid
logfile /var/log/redis/redis-cache.log
dir /var/lib/redis-cache
```

**Queue Instance**
```bash
sudo nano /etc/redis/redis-queue.conf
```

- Set:
```
port 6380
bind 0.0.0.0
requirepass <REDIS_PASSWORD>
supervised systemd

pidfile /run/redis-queue.pid
logfile /var/log/redis/redis-queue.log
dir /var/lib/redis-queue
```

**SocketIO Instance**
```bash
sudo nano /etc/redis/redis-socketio.conf
```

- Set:
```
port 6381
bind 0.0.0.0
requirepass <REDIS_PASSWORD>
supervised systemd

pidfile /run/redis-socketio.pid
logfile /var/log/redis/redis-socketio.log
dir /var/lib/redis-socketio
```

### **Create systemd Services**

**Cache Service**
```bash
sudo nano /etc/systemd/system/redis-cache.service
```

```
[Unit]
Description=Redis Instance (Cache)
After=network.target

[Service]
User=redis
Group=redis
ExecStart=/usr/bin/redis-server /etc/redis/redis-cache.conf
ExecStop=/usr/bin/redis-cli -a <REDIS_PASSWORD> -p 6379 shutdown
Restart=always

[Install]
WantedBy=multi-user.target
```

**Queue Service**
```bash
sudo nano /etc/systemd/system/redis-queue.service
```

```
[Unit]
Description=Redis Instance (Queue)
After=network.target

[Service]
User=redis
Group=redis
ExecStart=/usr/bin/redis-server /etc/redis/redis-queue.conf
ExecStop=/usr/bin/redis-cli -a <REDIS_PASSWORD> -p 6380 shutdown
Restart=always

[Install]
WantedBy=multi-user.target
```

**SocketIO Service**
```bash
sudo nano /etc/systemd/system/redis-socketio.service
```

```
[Unit]
Description=Redis Instance (SocketIO)
After=network.target

[Service]
User=redis
Group=redis
ExecStart=/usr/bin/redis-server /etc/redis/redis-socketio.conf
ExecStop=/usr/bin/redis-cli -a <REDIS_PASSWORD> -p 6381 shutdown
Restart=always

[Install]
WantedBy=multi-user.target
```

### **Start All Redis Instances**
```bash
sudo systemctl daemon-reload

sudo systemctl enable --now redis-cache
sudo systemctl enable --now redis-queue
sudo systemctl enable --now redis-socketio
```

- Check Status:

```bash
systemctl status redis-cache
systemctl status redis-queue
systemctl status redis-socketio
```

### **Firewall Rules**
```bash
sudo ufw allow from <NETWORK_CIDR> to any port 6379
sudo ufw allow from <NETWORK_CIDR> to any port 6380
sudo ufw allow from <NETWORK_CIDR> to any port 6381
```

### **Test Redis Connectivity**
- From Client Machine:
```bash
sudo apt install -y redis-tools

redis-cli -h <SERVER_IP> -p 6379 -a '<REDIS_PASSWORD>' ping
redis-cli -h <SERVER_IP> -p 6380 -a '<REDIS_PASSWORD>' ping
redis-cli -h <SERVER_IP> -p 6381 -a '<REDIS_PASSWORD>' ping
```

- Expected Output:
```
PONG
PONG
PONG
```

## **Setup NFS Server**

### Install NFS Server
```bash
sudo apt update
sudo apt install -y nfs-kernel-server
```

### Create Export Directory
```bash
sudo mkdir -p /srv/nfs/project/frappe-bench
sudo chown nobody:nogroup /srv/nfs/project/frappe-bench
sudo chmod 0777 /srv/nfs/project/frappe-bench
```

### Configure Exports
```bash
sudo nano /etc/exports
```

- Add:
```
/srv/nfs/project/frappe-bench <NETWORK_CIDR>(rw,sync,no_subtree_check,no_root_squash)
```

- Apply Configuration:
```bash
sudo exportfs -ra
sudo systemctl restart nfs-kernel-server
```

### Firewall
```bash
sudo ufw allow from <NETWORK_CIDR> to any port nfs
```

# Frappe Container Setup Guide (init, Web, Worker and Scheduler)

## Create copies of .env and apps.json
```bash
cp example.env .env
cp apps.json.example apps.json
```

## Update `.env` and `app.json` Accordingly.

## Build Image for `init` Container
```bash
docker buildx build \
  --no-cache-filter=builder \
  --build-arg APPS_JSON_BASE64="$(base64 -w0 apps.json)"  \
  -t frappe-init:latest -f Dockerfile-InitContainer .
```

## Build Image for Web, Worker and Scheduler Container
```bash
docker buildx build \
  -t frappe-runtime:latest \
  -f Dockerfile-RuntimeContainer .
```

## Update `docker-compose.yml` Accordingly

## Start All Containers
```bash
docker compose up -d --build
```