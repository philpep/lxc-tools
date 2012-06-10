DESTDIR=/usr/local/bin

install: lxc-debian.sh lxc-philpep.sh
	@mkdir -p ${DESTDIR}
	install -m root -g root -m 755 $^ ${DESTDIR}
