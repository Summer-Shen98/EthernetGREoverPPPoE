brgre_iface=$4
# echo "brgre_iface"$brgre_iface
wan_dev=$5
# echo "wan_dev"$wan_dev

wan_ip=$(ip -6 addr show "$wan_dev" scope global | grep -oP '(?<=inet6\s)[0-9a-f:]+' | head -n1)

add_br()
{
	ip link add $brgre_iface type bridge
	ip link set $brgre_iface up
}

del_all()
{
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
	gre_iface=gre$(echo $remote_ip | awk -F: '{print $8}')	
	
	auto_addbr

	ip link delete $gre_iface 2>/dev/null
	ip link add $gre_iface type ip6gretap local $wan_ip remote $remote_ip dev $wan_dev
	ip link set $gre_iface up
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
	gre_iface=gre$(echo $remote_ip | awk -F: '{print $8}')	
	ip link delete $gre_iface
}

usage()
{
	echo "init|destory"
	echo "gre int <remote>"
	echo "gre del <remote>"
}

case $1 in
	init)
		add_br
		;;
	gre)
		case $2 in 
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


