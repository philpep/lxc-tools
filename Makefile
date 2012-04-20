DESTDIR=/usr/local/bin

install: lxc-debian.sh lxc-philpep.sh lxc-halt
	@mkdir -p ${DESTDIR}
	install -m root -g root -m 755 $^ ${DESTDIR}
	install -m root -g root -m 755 lxc /etc/init.d/lxc
	update-rc.d -f lxc defaults
