#!/bin/bash -x

[ -f arch-linux.img ] && rm -rf arch-linux.img

qemu-img create arch-linux.img 10G

qemu-system-x86_64 -enable-kvm -hda arch-linux.img -cdrom /tmp/archlive.iso -boot d -m 4096 -net user,hostfwd=tcp::10022-:22 -net nic -daemonize -display none

until ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no -p 10022 root@localhost "echo \"hello archlinux\""; do sleep 10; echo "Trying again..."; done


ssh root@localhost -o StrictHostKeyChecking=no -p 10022 "curl -L https://github.com/schmidtandreas/arch-install/archive/master.tar.gz | tar zxvf -"

ssh root@localhost -o StrictHostKeyChecking=no -p 10022 "arch-install-master/arch-install.sh -d -c arch-install-master/configs/andreas_notebook.csv"
