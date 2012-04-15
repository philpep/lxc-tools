#!/bin/bash

MIRROR=${MIRROR:-"http://mirror.ovh.net/debian/"}
TEMPLATE=$(dirname $0)/lxc-debian.sh

# lvm
VGNAME=rootvg
FSTYPE=ext4
FSSIZE=2G

# network
GATEWAY="192.168.42.1"
NETMASK="24"
MACBASE="00:FF"
BRIDGE="brlxc0"

if [ ! -x "$TEMPLATE" ]; then
    echo "$TEMPLATE doesn't exist or isn't executable"
    exit 1
fi

usage() {
    echo "$0 -h|--help -n|--name=<name> -i|--ip=<ip>"
    exit 64
}

options=$(getopt hn:i: "$@")

eval set -- "$options"

while true
do
    case "$1" in
        -h) usage && exit 0;;
        -n) name=$2; shift 2;;
        -i) ip=$2; shift 2;;
        *) break;;
    esac
done

test -z "$name" && usage
test -z "$ip" && usage


echo $ip

mac=$MACBASE$(printf ':%02X' ${ip//./ }; echo)
lxc_path=/var/lib/lxc/$name
rootdev=/dev/$VGNAME/$name
rootfs=$lxc_path/rootfs

cleanup() {
    umount $rootfs
    lvremove -f $rootdev
}

trap cleanup HUP INT TERM

lvcreate -L $FSSIZE -n $name $VGNAME || exit 1
udevadm settle
mkfs -t $FSTYPE $rootdev || exit 1
mkdir -p $rootfs
mount -t $FSTYPE $rootdev $rootfs

MIRROR=$MIRROR $TEMPLATE --path=$lxc_path --name=$name

if [ $? -ne 0 ]; then
    echo "$0: failed to execute template"
    cleanup
fi

cat >> $lxc_path/config << EOF
lxc.network.type = veth
lxc.network.flags = up
lxc.network.link = $BRIDGE
lxc.network.hwaddr = $mac
lxc.network.ipv4 = $ip/$NETMASK
lxc.network.veth.pair = lxc-$name

# drop capabilities
lxc.cap.drop = audit_control audit_write fsetid ipc_lock ipc_owner lease linux_immutable mac_admin mac_override mac_admin mknod setfcap setpcap sys_admin sys_boot sys_module sys_nice sys_pacct sys_ptrace sys_rawio sys_resource sys_time sys_tty_config
EOF

cat <<EOF > $rootfs/etc/network/interfaces
auto lo
iface lo inet loopback
EOF
cat << EOF > $rootfs/etc/rc.local
#!/bin/sh
ip route add default via $GATEWAY dev eth0
EOF

echo "$rootdev $rootfs $FSTYPE defaults 0 0" >> /etc/fstab

echo "$name" created
