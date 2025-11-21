#!/bin/sh

nat_outport=$2
# echo "nat_outport"$nat_outport
nat_mask=$3
nat_mask6=$4
# echo "nat_mask"$nat_mask


start()
{
    accel-pppd -d -c /etc/accel-ppp.conf -p /var/run/accel-ppp.pid
    iptables -t nat -A POSTROUTING -s $nat_mask -o $nat_outport -j MASQUERADE
    if [ -n "$nat_mask6" ]; then
        ip6tables -t nat -A POSTROUTING -s "$nat_mask6" -o "$nat_outport" -j MASQUERADE
    fi
}

stop()
{
    killall accel-pppd
    iptables -t nat -D POSTROUTING -s $nat_mask -o $nat_outport -j MASQUERADE
    if [ -n "$nat_mask6" ]; then
        ip6tables -t nat -D POSTROUTING -s "$nat_mask6" -o "$nat_outport" -j MASQUERADE
    fi
}

case "$1" in
    start)
        start
        ;;
    stop)
        stop
        ;;
    restart)
        stop
        start
        ;;
    *)
        echo "Usage: $0 {start|stop|restart} <out_interface> <pppoe_source_network>"
        exit 1
        ;;
esac

