#!/bin/bash

MIRROR=${MIRROR:-"http://192.168.42.2:3142/ftp.fr.debian.org/debian"}
TEMPLATE=$(dirname $0)/lxc-debian.sh

# lvm
VGNAME=rootvg
FSTYPE=ext4

# network
GATEWAY="192.168.42.1"
NETMASK="24"
MACBASE="00:FF"
BRIDGE="brlxc0"

test -e /etc/default/lxc-philpep && . /etc/default/lxc-philpep

if [ ! -x "$TEMPLATE" ]; then
    echo "$TEMPLATE doesn't exist or isn't executable"
    exit 1
fi

arch=$(dpkg --print-architecture)

usage() {
	echo "$0 -h|--help -n <name> -i <ip> -s <fssize (default 2G)> -a <arch (default $arch)>"
    exit 64
}

options=$(getopt hn:i:s: "$@")

eval set -- "$options"

while true
do
    case "$1" in
        -h) usage && exit 0;;
        -n) name=$2; shift 2;;
        -i) ip=$2; shift 2;;
        -s) fssize=$2; shift 2;;
        -a) arch=$2; shift 2;;
        *) break;;
    esac
done

test -z "$name" && usage
test -z "$ip" && usage
test -z "$fssize" && fssize=2G

mac=$MACBASE$(printf ':%02X' ${ip//./ }; echo)
lxc_path=/var/lib/lxc/$name
rootdev=/dev/$VGNAME/$name
rootfs=$lxc_path/rootfs

cleanup() {
    umount $rootfs
    lvremove -f $rootdev
}

trap cleanup HUP INT TERM

lvcreate -L $fssize -n $name $VGNAME || exit 1
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
lxc.network.ipv4.gateway = $GATEWAY

# drop capabilities
lxc.cap.drop = audit_control audit_write fsetid ipc_lock ipc_owner lease linux_immutable mac_admin mac_override mac_admin mknod setfcap setpcap sys_admin sys_boot sys_module sys_nice sys_pacct sys_ptrace sys_rawio sys_resource sys_time sys_tty_config net_admin syslog
EOF

cat <<EOF > $rootfs/etc/network/interfaces
auto lo
iface lo inet loopback
EOF

# random password
root_password="$(dd if=/dev/urandom bs=32 count=1 2> /dev/null | base64)"
echo "root:$root_password" | chroot $rootfs chpasswd

# put your ssh keys here, otherwise leave mines :)
mkdir -p $rootfs/root/.ssh
cat > $rootfs/root/.ssh/authorized_keys << EOF
ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEAuV9mpjaE2wAA+MqrkxNrSM93Lfw2n/wTHICi6YQpVv9A+d4MSWPO2uw8I0j6jf7PdXiwSirPYtZS59+7rzPbS/l6t0fftBdYE0nR5kMtPOWn0Gt6Me4gLHJAAW5ZGZOkJuFVFjkOEA16zXjGG8X6KWe3Uv7KdFhEpcNokNZVk6uzqBSVemBKVpmDPjBOUQbR/xICdHqvNy4OYyXBxGb9UxlR9142O2yqXHR7gJtRJEKbR5lkiqZiWNtAhxTqUcgODe6EIA9fSyrAqOzGG4okMyt/4IXRgkRYkpu/VV9ZZ4x6DuHTt6XOwTv0rJiLWJe0HoIEfHhjLKnRrYvhLUZ0Iw==
ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEA44/kafwOzHQDN8hsVqxsdoo24z9aGTsBWdiqPj8cDlIC49DusBowZEcd+f2GVy8Op0KSy7ETEvazTfwWHi4KgcHmZRJplUoO5jfZ1BwbCQTrABkOAdX/5PYRepG9dQam4DnHKs7EDb1Fz/ggs6aZCamFvFu6P3hJ74/BsT0Pew2phevRRSieJQM0ORSgATCeNi62uYXnham/A3eODv/h5D/vDsZDJIcs5QzhWZYUY4iIIk63wimOje5pZX4MaGdvyRZfPPXCKnn29Y+ZdNJQbhYga5FFooqURX6CXrr6CQjOpZpeG/0YJWupNd6QX/CIC0MEuVpI/gjhHoZvzVnoUQ==
EOF

#http://www.mail-archive.com/lxc-users@lists.sourceforge.net/msg01266.html
sed -i 's/$ModLoad imklog/#$ModLoad imklog/' $rootfs/etc/rsyslog.conf

# Configure timezone
echo "Europe/Paris" > $rootfs/etc/timezone
chroot $rootfs dpkg-reconfigure -f noninteractive tzdata

# TODO lxc can mount the fs when starting container
echo "$rootdev $rootfs $FSTYPE defaults 0 0" >> /etc/fstab

echo "$name" created
