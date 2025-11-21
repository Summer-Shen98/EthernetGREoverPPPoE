#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

SCRIPT_PATH="$SCRIPT_DIR/eogre_v4_pppoe.sh"
SCRIPT_PATH_V6="$SCRIPT_DIR/eogre_v6_pppoe.sh"
PPPoE_SCRIPT_PATH="$SCRIPT_DIR/start_pppoe_server.sh"

INTERFACE=${1:-eth0}
brgre_iface=${2:-brEoGREPPPoE}
pppoe_netmask=${3:-192.168.8.0/24}

# IPv6 可选
ENABLE_IPV6=${4:-0}              # 0=不启用, 1=启用
pppoe_netmask6=${5:-fd00:1::/64} # IPv6 PPPoE 地址池

WORKER_BIN_V4="gre_nfqueue_worker"
WORKER_BIN_V6="gre_nfqueue_worker_ipv6"

log_file="/var/log/stop_gre.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$log_file"
}

log "[INFO] Stop GRE NFQUEUE Processor..."

# 停止 IPv4 worker
PIDS=$(pgrep -f "$WORKER_BIN_V4" || true)
if [ -n "$PIDS" ]; then
  log "[INFO] Stop IPv4 worker PID: $PIDS"
  kill -TERM $PIDS
  sleep 1
  PIDS=$(pgrep -f "$WORKER_BIN_V4" || true)
  if [ -n "$PIDS" ]; then
    log "[WARN] Force Kill IPv4 worker PID: $PIDS"
    kill -9 $PIDS
  fi
else
  log "[INFO] No running $WORKER_BIN_V4 found"
fi

# 停止 IPv6 worker
if [ "$ENABLE_IPV6" -eq 1 ]; then
  PIDS=$(pgrep -f "$WORKER_BIN_V6" || true)
  if [ -n "$PIDS" ]; then
    log "[INFO] Stop IPv6 worker PID: $PIDS"
    kill -TERM $PIDS
    sleep 1
    PIDS=$(pgrep -f "$WORKER_BIN_V6" || true)
    if [ -n "$PIDS" ]; then
      log "[WARN] Force Kill IPv6 worker PID: $PIDS"
      kill -9 $PIDS
    fi
  else
    log "[INFO] No running $WORKER_BIN_V6 found"
  fi
fi

# 清理 IPv4 NFQUEUE
for chain in INPUT FORWARD; do
  log "[INFO] Check $chain chain (IPv4)..."
  RULES=$(iptables -t filter -S $chain | grep "NFQUEUE" | grep "gre" || true)
  if [ -n "$RULES" ]; then
    echo "$RULES" | while read -r rule; do
      DEL_RULE=$(echo "$rule" | sed 's/^-A /-D /')
      log "[INFO] Delete rule: $DEL_RULE"
      iptables -t filter $DEL_RULE
    done
  fi
done

# 清理 IPv6 NFQUEUE（如果启用 IPv6）
if [ "$ENABLE_IPV6" -eq 1 ]; then
  for chain in INPUT FORWARD; do
    log "[INFO] Check $chain chain (IPv6)..."
    RULES=$(ip6tables -t filter -S $chain | grep "NFQUEUE" | grep "gre" || true)
    if [ -n "$RULES" ]; then
      echo "$RULES" | while read -r rule; do
        DEL_RULE=$(echo "$rule" | sed 's/^-A /-D /')
        log "[INFO] Delete IPv6 rule: $DEL_RULE"
        ip6tables -t filter $DEL_RULE
      done
    fi
  done
fi

# 清理 GRE 接口
if [ -x "$SCRIPT_PATH" ]; then
  log "[INFO] EXEC GRE IPv4 Tunnel Destroy..."
  bash "$SCRIPT_PATH" destory null null $brgre_iface $INTERFACE || true
fi

if [ "$ENABLE_IPV6" -eq 1 ] && [ -x "$SCRIPT_PATH_V6" ]; then
  log "[INFO] EXEC GRE IPv6 Tunnel Destroy..."
  bash "$SCRIPT_PATH_V6" destory null null $brgre_iface $INTERFACE || true
fi

# 停止 PPPoE
if [ -x "$PPPoE_SCRIPT_PATH" ]; then
  if [ "$ENABLE_IPV6" -eq 1 ]; then
    log "[INFO] EXEC Stop PPPoE Server (IPv4+IPv6)..."
    bash "$PPPoE_SCRIPT_PATH" stop $INTERFACE $pppoe_netmask $pppoe_netmask6 || true
  else
    log "[INFO] EXEC Stop PPPoE Server (IPv4 only)..."
    bash "$PPPoE_SCRIPT_PATH" stop $INTERFACE $pppoe_netmask || true
  fi
else
  log "[WARN] Can not find $PPPoE_SCRIPT_PATH, exec stop failed"
fi

log "[INFO] GRE NFQUEUE Processor Stopped."
