#!/bin/bash -x

(
echo "pre qemu setup"
# XXX: do this in vm network setup
ip link set lo up
ip a
echo "pre qemu setup done"

cat /proc/$$/status
id
cat /etc/libvirt/qemu.conf
ls -l /var/lib
ls -l /var/lib/libvirt
ls -l /var/lib/libvirt/qemu/
) >& /tmp/xxx.txt

# tcpdump -i br0 >& /tmp/tcpdump.log&
