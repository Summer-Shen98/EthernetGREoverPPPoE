brgre_iface=$4
# echo "brgre_iface"$brgre_iface
wan_dev=$5
# echo "wan_dev"$wan_dev

wan_ip=$(ip -4 addr show "$wan_dev" | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

add_br()
{
	ip link add $brgre_iface type bridge
	# ifconfig $brgre_iface $brgre_ip netmask 255.255.255.0
	ip link set $brgre_iface up
	# ip addr add $brgre_ipv6/48 dev $brgre_iface
	#modprobe br_netfilter
	#ebtables -A FORWARD --dst ff:ff:ff:ff:ff:ff -j DROP
}

del_all()
{
	# ip link delete $br_iface
	ip link delete $brgre_iface
}

auto_addbr()
{
    ip link show $brgre_iface 2>/dev/null 1>/dev/null
    if [ "$?" -ne 0 ]; then
	add_br
    fi
}

add_gre_internal_nw()
{
	remote_ip=$1
	gre_iface=gre$(echo $remote_ip | awk -F. '{print $3$4}')	
	
	auto_addbr

	ip link delete $gre_iface 2>/dev/null
	ip link add $gre_iface type gretap local $wan_ip remote $remote_ip dev $wan_dev
	ip link set $gre_iface up
	#ip link add link $gre_iface name $gre_iface.$vlan type vlan id $vlan
	#ip link set $gre_iface.$vlan up
	#ip link set $gre_iface.$vlan master $brgre_iface
	ip link set $gre_iface master $brgre_iface

}

destory()
{
	grelist=$(ifconfig | grep gre | cut -d':' -f1)
	for i in $grelist
	do
		ip link delete $i
	done
	del_all
}

remove_gre()
{
	remote_ip=$1
	gre_iface=gre$(echo $remote_ip | awk -F. '{print $3$4}')	
	
	#ip link delete $gre_iface.$vlan
	ip link delete $gre_iface
}

usage()
{
	echo "init|destory"
	echo "gre ext <remote>"
	echo "gre int <remote>"
	echo "gre del <remote>"
}

case $1 in
	init)
		add_br
		;;
	gre)
		case $2 in 
			ext)
				add_gre_external_nw $3
				;;
			int)
				add_gre_internal_nw $3
				;;
			del)
				remove_gre $3
				;;
			*)
				usage
				;;
		esac
		;;
	destory)
		destory
		;;
	*)
		usage
		;;
esac


