#!/usr/bin/env bash
set -e

### =========================
### 0. VARIABLES
### =========================
INSTALL_DIR="/root/tts"
STACK_VERSION="3.22.2"
REDIS_VERSION="6.2"
POSTGRES_VERSION="15"

POSTGRES_USER="root"
POSTGRES_PASSWORD="root"
POSTGRES_DB="ttn_lorawan"

CONSOLE_SECRET="console"
ADMIN_EMAIL="admin@example.com"
METRICS_PASSWORD="metrics"

### =========================
### 1. ENVIRONMENT PREP
### =========================
echo "== Installing dependencies =="
apt update
apt install -y golang-cfssl docker.io wget openssl net-tools docker-compose

### =========================
### 2. GET LAN IP
### =========================
LAN_IP=$(ip route get 1 | awk '{print $7; exit}')
echo "Detected LAN IP: ${LAN_IP}"

### =========================
### 3. DIRECTORY STRUCTURE
### =========================
mkdir -p ${INSTALL_DIR}/{config/stack,data/postgres,data/redis,blob}
cd ${INSTALL_DIR}

### =========================
### 4. COOKIE KEYS (generate early)
### =========================
BLOCK_KEY=$(openssl rand -hex 32)
HASH_KEY=$(openssl rand -hex 64)

### =========================
### 5. docker-compose.yml
### =========================
cat > docker-compose.yml <<EOF
version: "3.7"

services:
  postgres:
    image: postgres:${POSTGRES_VERSION}
    restart: unless-stopped
    environment:
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - POSTGRES_USER=${POSTGRES_USER}
      - POSTGRES_DB=${POSTGRES_DB}
    volumes:
      - ./data/postgres:/var/lib/postgresql/data
    ports:
      - "127.0.0.1:5432:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER}"]
      interval: 5s
      timeout: 5s
      retries: 10

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
      postgres:
        condition: service_healthy
      redis:
        condition: service_started
    volumes:
      - ./blob:/srv/ttn-lorawan/public/blob
      - ./config/stack:/config:ro
    environment:
      TTN_LW_REDIS_ADDRESS: redis:6379
      TTN_LW_IS_DATABASE_URI: postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB}?sslmode=disable
    ports:
      # HTTP/HTTPS
      - "80:1885"
      - "443:8885"
      # gRPC
      - "1881:1881"
      - "8881:8881"
      # gRPC Web
      - "1882:1882"
      - "8882:8882"
      # MQTT
      - "1883:1883"
      - "8883:8883"
      # MQTT Web
      - "1884:1884"
      - "8884:8884"
      # HTTP
      - "1885:1885"
      - "8885:8885"
      # Interop
      - "1886:1886"
      - "8886:8886"
      # LNS
      - "1887:1887"
      - "8887:8887"
      # Gateway Configuration Server
      - "1888:1888"
      - "8888:8888"
      # Tabs Hub
      - "8889:8889"
      # Gateway UDP
      - "1700:1700/udp"
    secrets:
      - ca.pem
      - cert.pem
      - key.pem

secrets:
  ca.pem:
    file: ./ca.pem
  cert.pem:
    file: ./cert.pem
  key.pem:
    file: ./key.pem
EOF

### =========================
### 6. ttn-lw-stack-docker.yml
### =========================
cat > config/stack/ttn-lw-stack-docker.yml <<EOF
# Identity Server configuration
is:
  database-uri: "postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB}?sslmode=disable"
  email:
    sender-name: "The Things Stack"
    sender-address: "noreply@${LAN_IP}"
    network:
      name: "The Things Stack"
      console-url: "https://${LAN_IP}/console"
      identity-server-url: "https://${LAN_IP}/oauth"

# HTTP server configuration
http:
  cookie:
    block-key: "${BLOCK_KEY}"
    hash-key: "${HASH_KEY}"
  metrics:
    password: "${METRICS_PASSWORD}"

# TLS configuration - using custom certificates
tls:
  source: file
  root-ca: /run/secrets/ca.pem
  certificate: /run/secrets/cert.pem
  key: /run/secrets/key.pem

# OAuth UI configuration
oauth:
  ui:
    canonical-url: "https://${LAN_IP}/oauth"
    is:
      base-url: "https://${LAN_IP}/api/v3"

# Console UI configuration
console:
  ui:
    canonical-url: "https://${LAN_IP}/console"
    account-url: "https://${LAN_IP}/oauth"
    is:
      base-url: "https://${LAN_IP}/api/v3"
    gs:
      base-url: "https://${LAN_IP}/api/v3"
    ns:
      base-url: "https://${LAN_IP}/api/v3"
    as:
      base-url: "https://${LAN_IP}/api/v3"
    js:
      base-url: "https://${LAN_IP}/api/v3"
    gcs:
      base-url: "https://${LAN_IP}/api/v3"
    qrg:
      base-url: "https://${LAN_IP}/api/v3"
    edtc:
      base-url: "https://${LAN_IP}/api/v3"
    dcs:
      base-url: "https://${LAN_IP}/api/v3"
  oauth:
    authorize-url: "https://${LAN_IP}/oauth/authorize"
    token-url: "https://${LAN_IP}/oauth/token"
    logout-url: "https://${LAN_IP}/oauth/logout"
    client-id: "console"
    client-secret: "${CONSOLE_SECRET}"

# Gateway Server configuration
gs:
  require-registered-gateways: false
  mqtt:
    public-address: "${LAN_IP}:1883"
    public-tls-address: "${LAN_IP}:8883"
  mqtt-v2:
    public-address: "${LAN_IP}:1881"
    public-tls-address: "${LAN_IP}:8881"

# Gateway Configuration Server
gcs:
  basic-station:
    default:
      lns-uri: "wss://${LAN_IP}:8887"

# Packet Broker Agent - disabled for local deployment
pba:
  enabled: false
EOF

### =========================
### 7. CERTIFICATE GENERATION
### =========================
echo "== Generating certificates =="

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

### =========================
### 8. PULL DOCKER IMAGES
### =========================
echo "== Pulling Docker images =="
docker-compose pull

### =========================
### 9. INITIALIZE DATABASE
### =========================
echo "== Initializing database =="
docker-compose run --rm stack is-db migrate

### =========================
### 10. CREATE ADMIN USER
### =========================
echo "== Creating admin user =="
docker-compose run --rm stack is-db create-admin-user \
    --id admin \
    --email ${ADMIN_EMAIL}

### =========================
### 11. CREATE CLI OAUTH CLIENT
### =========================
echo "== Creating CLI OAuth client =="
docker-compose run --rm stack is-db create-oauth-client \
    --id cli \
    --name "Command Line Interface" \
    --owner admin \
    --no-secret \
    --redirect-uri "local-callback" \
    --redirect-uri "code"

### =========================
### 12. CREATE CONSOLE OAUTH CLIENT
### =========================
echo "== Creating Console OAuth client =="
docker-compose run --rm stack is-db create-oauth-client \
    --id console \
    --name "Console" \
    --owner admin \
    --secret "${CONSOLE_SECRET}" \
    --redirect-uri "https://${LAN_IP}/console/oauth/callback" \
    --redirect-uri "/console/oauth/callback" \
    --logout-redirect-uri "https://${LAN_IP}/console" \
    --logout-redirect-uri "/console"

### =========================
### 13. START THE THINGS STACK
### =========================
echo "== Starting The Things Stack =="
docker-compose up -d

echo ""
echo "========================================"
echo "The Things Stack installation complete!"
echo "========================================"
echo ""
echo "Access the console at: https://${LAN_IP}/console"
echo "Admin user: admin"
echo "Admin email: ${ADMIN_EMAIL}"
echo ""
echo "MQTT (plain):    ${LAN_IP}:1883"
echo "MQTT (TLS):      ${LAN_IP}:8883"
echo "Gateway UDP:     ${LAN_IP}:1700"
echo ""
echo "Note: You will need to set your admin password on first login."
echo "Note: Your browser will warn about the self-signed certificate."
echo "      You can import ca.pem to trust it, located at: ${INSTALL_DIR}/ca.pem"
echo ""
