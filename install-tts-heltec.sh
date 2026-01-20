#!/usr/bin/env bash
set -e

### =========================
### 0. VARIABLES (DEFAULTS)
### =========================
INSTALL_DIR="/root/tts"
STACK_VERSION="3.22.2"
REDIS_VERSION="6.2"
POSTGRES_VERSION="15"

POSTGRES_USER="root"
POSTGRES_PASSWORD="root"
POSTGRES_DB="ttn_lorawan_dev"

CONSOLE_SECRET="console"

### =========================
### 1. ENVIRONMENT PREP
### =========================
echo "== Installing dependencies =="
apt update
# apt install -y golang-cfssl docker.io wget openssl net-tools

### =========================
### 2. GET LAN IP
### =========================
LAN_IP=$(ip route get 1 | awk '{print $7; exit}')
echo "Detected LAN IP: ${LAN_IP}"

### =========================
### 3. DIRECTORY STRUCTURE
### =========================
mkdir -p ${INSTALL_DIR}/{config/stack,data/postgres,data/redis}
cd ${INSTALL_DIR}

### =========================
### 4. docker-compose.yml
### =========================
cat > docker-compose.yml <<EOF
version: "3.7"

services:
  postgres:
    image: postgres:${POSTGRES_VERSION}
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
    volumes:
      - ./data/postgres:/var/lib/postgresql/data
    ports:
      - "127.0.0.1:5432:5432"

  redis:
    image: redis:${REDIS_VERSION}
    command: redis-server --appendonly yes
    restart: unless-stopped
    volumes:
      - ./data/redis:/data
    ports:
      - "127.0.0.1:6379:6379"

  stack:
    image: thethingsnetwork/lorawan-stack:${STACK_VERSION}
    entrypoint: ttn-lw-stack -c /config/ttn-lw-stack-docker.yml
    command: start
    restart: unless-stopped
    depends_on:
      - postgres
      - redis
    volumes:
      - ./config/stack:/config:ro
      - ./ca.pem:/run/secrets/ca.pem
      - ./cert.pem:/run/secrets/cert.pem
      - ./key.pem:/run/secrets/key.pem
    environment:
      TTN_LW_REDIS_ADDRESS: redis:6379
      TTN_LW_IS_DATABASE_URI: postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB}?sslmode=disable
    ports:
      - "1881:1881"
      - "8881:8881"
      - "1882:1882"
      - "8882:8882"
      - "1883:1883"
      - "8883:8883"
      - "1885:1885"
      - "8885:8885"
      - "1700:1700/udp"
EOF

### =========================
### 5. COOKIE KEYS
### =========================
BLOCK_KEY=$(openssl rand -hex 32)
HASH_KEY=$(openssl rand -hex 64)

### =========================
### 6. ttn-lw-stack-docker.yml
### =========================
cat > config/stack/ttn-lw-stack-docker.yml <<EOF
is:
  email:
    sender-name: "The Things Stack"
    sender-address: "noreply@${LAN_IP}"
    network:
      name: "The Things Stack"
      console-url: "https://${LAN_IP}/console"
      identity-server-url: "https://${LAN_IP}/oauth"

http:
  cookie:
    block-key: "${BLOCK_KEY}"
    hash-key: "${HASH_KEY}"
  metrics:
    password: "metrics"
  pprof:
    password: "pprof"

tls:
  source: file
  root-ca: /run/secrets/ca.pem
  certificate: /run/secrets/cert.pem
  key: /run/secrets/key.pem

console:
  ui:
    canonical-url: "https://${LAN_IP}/console"
    account-url: "https://${LAN_IP}/oauth"
    is:
      base-url: "https://${LAN_IP}/api/v3"
    dcs:
      base-url: "https://${LAN_IP}/api/v3"
  oauth:
    authorize-url: "https://${LAN_IP}/oauth/authorize"
    token-url: "https://${LAN_IP}/oauth/token"
    logout-url: "https://${LAN_IP}/oauth/logout"
    client-id: "console"
    client-secret: "${CONSOLE_SECRET}"
EOF

### =========================
### 7. CERTIFICATE GENERATION
### =========================
cat > ca.json <<EOF
{
  "names": [
    {"C":"NL","ST":"Noord-Holland","L":"Amsterdam","O":"The Things Demo"}
  ]
}
EOF

cfssl genkey -initca ca.json | cfssljson -bare ca

cat > cert.json <<EOF
{
  "hosts": ["${LAN_IP}"],
  "names": [
    {"C":"NL","ST":"Noord-Holland","L":"Amsterdam","O":"The Things Demo"}
  ]
}
EOF

cfssl gencert -ca ca.pem -ca-key ca-key.pem cert.json | cfssljson -bare cert
cp -f cert-key.pem key.pem
