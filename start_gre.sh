#!/bin/bash

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

SCRIPT_PATH="$SCRIPT_DIR/eogre_v4_pppoe.sh"
SCRIPT_PATH_V6="$SCRIPT_DIR/eogre_v6_pppoe.sh"
WORKER_BIN="$SCRIPT_DIR/gre_nfqueue_worker"
WORKER_BIN_V6="$SCRIPT_DIR/gre_nfqueue_worker_ipv6"
PPPoE_SCRIPT_PATH="$SCRIPT_DIR/start_pppoe_server.sh"

QUEUE_NUM=${1:-4}
TIMEOUT=${2:-50}
INTERFACE=${3:-eth0}
brgre_iface=${4:-brEoGREPPPoE}
pppoe_netmask=${5:-192.168.8.0/24}

# IPv6 可选参数
ENABLE_IPV6=${6:-0}              # 0=不启用, 1=启用
pppoe_netmask6=${7:-fd00:1::/64} # IPv6 PPPoE 地址池

LOCK_DIR="/run/eogrelocks"
log_file="/var/log/start_gre.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$log_file"
}

log "[INFO] Start GRE NFQUEUE Processor, Queue=${QUEUE_NUM} ttl=${TIMEOUT}, iface=$INTERFACE"

# 检查依赖
if [ ! -x "$WORKER_BIN" ]; then
  log "[ERR ] Cannot find $WORKER_BIN"
  exit 1
fi

if [ "$ENABLE_IPV6" -eq 1 ] && [ ! -x "$WORKER_BIN_V6" ]; then
  log "[ERR ] Cannot find $WORKER_BIN_V6"
  exit 1
fi

if [ ! -f "$SCRIPT_PATH" ]; then
  log "[ERR ] Cannot find $SCRIPT_PATH"
  exit 1
fi

if [ "$ENABLE_IPV6" -eq 1 ] && [ ! -f "$SCRIPT_PATH_V6" ]; then
  log "[ERR ] Cannot find $SCRIPT_PATH_V6"
  exit 1
fi

mkdir -p "$LOCK_DIR"

# 初始化 IPv4 GRE/PPPoE
log "[INFO] Init GRE IPv4..."
bash "$SCRIPT_PATH" destory null null $brgre_iface $INTERFACE || true
bash "$SCRIPT_PATH" init null null $brgre_iface $INTERFACE || true

if [ "$ENABLE_IPV6" -eq 1 ]; then
    log "[INFO] Init GRE IPv6..."
    bash "$SCRIPT_PATH_V6" destory null null $brgre_iface $INTERFACE || true
    bash "$SCRIPT_PATH_V6" init null null $brgre_iface $INTERFACE || true

    # IPv6 启用时，restart 一次性带 IPv4/IPv6 两个网段
    bash "$PPPoE_SCRIPT_PATH" restart $INTERFACE $pppoe_netmask $pppoe_netmask6 || true
else
    # 默认只启用 IPv4
    bash "$PPPoE_SCRIPT_PATH" restart $INTERFACE $pppoe_netmask || true
fi

# 清理旧 iptables 规则
log "[INFO] Clean NFQUEUE rules existed..."
iptables -t filter -D INPUT -i $INTERFACE -p gre -j NFQUEUE --queue-balance 0:$((QUEUE_NUM-1)) 2>/dev/null || true
iptables -t filter -D INPUT -i $INTERFACE -p gre -j NFQUEUE --queue-num 0 2>/dev/null || true

# IPv6 的 nfqueue 清理 (ip6tables)
if [ "$ENABLE_IPV6" -eq 1 ]; then
    ip6tables -t filter -D INPUT -i $INTERFACE -p gre -j NFQUEUE --queue-balance $QUEUE_NUM:$((2*QUEUE_NUM-1)) 2>/dev/null || true
    ip6tables -t filter -D INPUT -i $INTERFACE -p gre -j NFQUEUE --queue-num $QUEUE_NUM 2>/dev/null || true
fi

# 设置 IPv4 NFQUEUE
log "[INFO] Setup NFQUEUE rules: 0..$((QUEUE_NUM-1))"
iptables -t filter -I INPUT -i $INTERFACE -p gre -j NFQUEUE --queue-balance 0:$((QUEUE_NUM-1)) --queue-bypass

# 设置 IPv6 NFQUEUE
if [ "$ENABLE_IPV6" -eq 1 ]; then
    log "[INFO] Setup IPv6 NFQUEUE rules: $QUEUE_NUM..$((2*QUEUE_NUM-1))"
    ip6tables -t filter -I INPUT -i $INTERFACE -p gre -j NFQUEUE --queue-balance $QUEUE_NUM:$((2*QUEUE_NUM-1)) --queue-bypass
fi

# 启动 IPv4 worker
log "[INFO] Start $QUEUE_NUM IPv4 worker..."
for ((i=0; i<QUEUE_NUM; i++)); do
  LOGFILE="/var/log/gre_nfqueue_worker_q${i}.log"
  CPU_CORE=$i
  if [ "$CPU_CORE" -ge "$(nproc)" ]; then
    CPU_CORE=$((i % $(nproc)))
  fi

  log "[INFO] Start IPv4 worker q=${i} BIND=${CPU_CORE} LOG=${LOGFILE}"
  nohup taskset -c $CPU_CORE "$WORKER_BIN" -q $i -t $TIMEOUT -s "$SCRIPT_PATH" -w "$INTERFACE" -b "$brgre_iface" >"$LOGFILE" 2>&1 &
done

# 启动 IPv6 worker（如果启用）
if [ "$ENABLE_IPV6" -eq 1 ]; then
  log "[INFO] Start $QUEUE_NUM IPv6 worker..."
  for ((i=0; i<QUEUE_NUM; i++)); do
    V6_QUEUE=$((i + QUEUE_NUM))
    LOGFILE="/var/log/gre_nfqueue_worker_ipv6_q${V6_QUEUE}.log"
    # 为了尽量均匀分布到 CPU core，我们给 IPv6 worker 一个 offset
    if [ "$(nproc)" -gt 0 ]; then
      CPU_CORE=$(((i + QUEUE_NUM) % $(nproc)))
    else
      CPU_CORE=$((i + QUEUE_NUM))
    fi
    
    log "[INFO] Start IPv6 worker q=${i} BIND=${CPU_CORE} LOG=${LOGFILE}"
    nohup taskset -c $CPU_CORE "$WORKER_BIN_V6" -q $V6_QUEUE -t $TIMEOUT -s "$SCRIPT_PATH_V6" -w "$INTERFACE" -b "$brgre_iface" >"$LOGFILE" 2>&1 &
  done
fi

log "[INFO] ALL worker started."
