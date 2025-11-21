# EthernetGREoverPPPoE
A simple eogre over pppoe server

Simple guide:

Use accel-ppp as pppoe server. Should install accel-ppp first.

Make the main gre_worker easily by following command:

gcc -O3 -pthread gre_nfqueue_worker.c -o gre_nfqueue_worker -lnetfilter_queue

gcc -O2 -Wall gre_ipv6.c -o gre_nfqueue_worker_ipv6 -lnetfilter_queue -lpthread

start by:

if enable ipv6:
  start_gre.sh thread_num timeout iface brgre_iface pppoe_net '1' pppoe_netv6

if not enable ipv6:
  start_gre.sh thread_num timeout iface brgre_iface pppoe_net


