#!/bin/bash

#
# lxc: linux Container library

# Authors:
# Daniel Lezcano <daniel.lezcano@free.fr>

# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; either
# version 2.1 of the License, or (at your option) any later version.

# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
 # MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.

# You should have received a copy of the GNU Lesser General Public
# License along with this library; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307 USA

SUITE=${SUITE:-squeeze}
MIRROR=${MIRROR:-"http://cdn.debian.net/debian"}

configure_debian()
{
    rootfs=$1
    hostname=$2

    # squeeze only has /dev/tty and /dev/tty0 by default,
    # therefore creating missing device nodes for tty1-4.
    for tty in $(seq 1 1); do
    if [ ! -e $rootfs/dev/tty$tty ]; then
        mknod $rootfs/dev/tty$tty c 4 $tty
    fi
    done

    # configure the inittab
    cat <<EOF > $rootfs/etc/inittab
id:3:initdefault:
si::sysinit:/etc/init.d/rcS
l0:0:wait:/etc/init.d/rc 0
l1:1:wait:/etc/init.d/rc 1
l2:2:wait:/etc/init.d/rc 2
l3:3:wait:/etc/init.d/rc 3
l4:4:wait:/etc/init.d/rc 4
l5:5:wait:/etc/init.d/rc 5
l6:6:wait:/etc/init.d/rc 6
# Normally not reached, but fallthrough in case of emergency.
z6:6:respawn:/sbin/sulogin
1:2345:respawn:/sbin/getty 38400 console
c1:12345:respawn:/sbin/getty 38400 tty1 linux
EOF

    # disable selinux in debian
    mkdir -p $rootfs/selinux
    echo 0 > $rootfs/selinux/enforce

    # configure the network using the dhcp
    cat <<EOF > $rootfs/etc/network/interfaces
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF

    # set the hostname
    cat <<EOF > $rootfs/etc/hostname
$hostname
EOF

    # reconfigure some services
    echo "en_US.UTF-8 UTF-8" > $rootfs/etc/locale.gen
    chroot $rootfs locale-gen en_US.UTF-8 UTF-8
    chroot $rootfs update-locale LANG=en_US.UTF-8

    # remove pointless services in a container
    chroot $rootfs /usr/sbin/update-rc.d -f checkroot.sh remove
    chroot $rootfs /usr/sbin/update-rc.d -f umountfs remove
    chroot $rootfs /usr/sbin/update-rc.d -f hwclock.sh remove
    chroot $rootfs /usr/sbin/update-rc.d -f hwclockfirst.sh remove
    chroot $rootfs /usr/sbin/update-rc.d -f hostname.sh remove

    return 0
}

download_debian()
{
    packages=\
ifupdown,\
locales,\
libui-dialog-perl,\
dialog,\
dhcp3-client,\
netbase,\
net-tools,\
iproute,\
openssh-server

    cache=$1
    arch=$2

    # check the mini debian was not already downloaded
    mkdir -p "$cache/partial-$SUITE-$arch"
    if [ $? -ne 0 ]; then
        echo "Failed to create '$cache/partial-$SUITE-$arch' directory"
        return 1
    fi

    # download a mini debian into a cache
    echo "Downloading debian minimal ..."
    debootstrap --verbose --variant=minbase --arch=$arch \
    --include=$packages \
    "$SUITE" "$cache/partial-$SUITE-$arch" $MIRROR
    if [ $? -ne 0 ]; then
        echo "Failed to download the rootfs, aborting."
        return 1
    fi

    mv "$1/partial-$SUITE-$arch" "$1/rootfs-$SUITE-$arch"
    echo "Download complete."

    return 0
}

copy_debian()
{
    cache=$1
    arch=$2
    rootfs=$3

    # make a local copy of the minidebian
    echo -n "Copying rootfs to $rootfs..."
    mkdir -p $rootfs
    rsync -a "$cache/rootfs-$SUITE-$arch"/ $rootfs/ || return 1
    return 0
}

install_debian()
{
    cache="/var/cache/lxc/debian"
    rootfs=$1
    mkdir -p /var/lock/subsys/
    (
    flock -n -x 200
    if [ $? -ne 0 ]; then
        echo "Cache repository is busy."
        return 1
    fi

    arch=$(dpkg --print-architecture)

    echo "Checking cache download in $cache/rootfs-$SUITE-$arch ... "
    if [ ! -e "$cache/rootfs-$SUITE-$arch" ]; then
        download_debian $cache $arch
        if [ $? -ne 0 ]; then
        echo "Failed to download 'debian base'"
        return 1
        fi
    fi

    copy_debian $cache $arch $rootfs
    if [ $? -ne 0 ]; then
        echo "Failed to copy rootfs"
        return 1
    fi

    return 0

    ) 200>/var/lock/subsys/lxc

    return $?
}

copy_configuration()
{
    path=$1
    rootfs=$2
    hostname=$3

    cat <<EOF >> $path/config
lxc.tty = 1
lxc.pts = 1024
lxc.rootfs = $rootfs
lxc.utsname = $hostname
lxc.cgroup.devices.deny = a
# /dev/null and zero
lxc.cgroup.devices.allow = c 1:3 rwm
lxc.cgroup.devices.allow = c 1:5 rwm
# consoles
lxc.cgroup.devices.allow = c 5:1 rwm
lxc.cgroup.devices.allow = c 5:0 rwm
lxc.cgroup.devices.allow = c 4:0 rwm
lxc.cgroup.devices.allow = c 4:1 rwm
# /dev/{,u}random
lxc.cgroup.devices.allow = c 1:9 rwm
lxc.cgroup.devices.allow = c 1:8 rwm
lxc.cgroup.devices.allow = c 136:* rwm
lxc.cgroup.devices.allow = c 5:2 rwm
# rtc
lxc.cgroup.devices.allow = c 254:0 rwm

# mounts point
lxc.mount.entry=proc $rootfs/proc proc nodev,noexec,nosuid 0 0
lxc.mount.entry=sysfs $rootfs/sys sysfs defaults  0 0
lxc.mount.entry=none $rootfs/dev/shm tmpfs defaults 0 0
EOF

    if [ $? -ne 0 ]; then
        echo "Failed to add configuration"
        return 1
    fi

    return 0
}

clean()
{
    cache="/var/cache/lxc/debian"

    if [ ! -e $cache ]; then
        exit 0
    fi

    # lock, so we won't purge while someone is creating a repository
    (
    flock -n -x 200
    if [ $? != 0 ]; then
        echo "Cache repository is busy."
        exit 1
    fi

    echo -n "Purging the download cache..."
    rm --preserve-root --one-file-system -rf $cache && echo "Done." || exit 1
    exit 0

    ) 200>/var/lock/subsys/lxc
}

usage()
{
    cat <<EOF
$1 -h|--help -p|--path=<path> -n|--name=<name> --clean
EOF
    return 0
}

options=$(getopt -o hp:n:c -l help,path:,name:,clean -- "$@")
if [ $? -ne 0 ]; then
        usage $(basename $0)
    exit 1
fi
eval set -- "$options"

while true
do
    case "$1" in
        -h|--help)      usage $0 && exit 0;;
        -p|--path)      path=$2; shift 2;;
        -n|--name)      name=$2; shift 2;;
        -c|--clean)     clean=$2; shift 2;;
        --)             shift 1; break ;;
        *)              break ;;
    esac
done

if [ ! -z "$path" ]; then
    mkdir $path;
fi

if [ ! -z "$clean" -a -z "$path" ]; then
    clean || exit 1
    exit 0
fi

type debootstrap
if [ $? -ne 0 ]; then
    echo "'debootstrap' command is missing"
    exit 1
fi

if [ -z "$path" ]; then
    echo "'path' parameter is required"
    exit 1
fi

if [ "$(id -u)" != "0" ]; then
    echo "This script should be run as 'root'"
    exit 1
fi

rootfs=$path/rootfs

install_debian $rootfs
if [ $? -ne 0 ]; then
    echo "failed to install debian"
    exit 1
fi

configure_debian $rootfs $name
if [ $? -ne 0 ]; then
    echo "failed to configure debian for a container"
    exit 1
fi

copy_configuration $path $rootfs $name
if [ $? -ne 0 ]; then
    echo "failed write configuration file"
    exit 1
fi

if [ ! -z $clean ]; then
    clean || exit 1
    exit 0
fi
