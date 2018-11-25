#!/bin/bash -x

# This script will be execute in docker container base/archlinux

set -e

mkdir /run/shm
sed -ie "0,/^Server.*/ s|^Server\\(.*\\)|#Server\\1|" /etc/pacman.d/mirrorlist
pacman -Sy
pacman -S --noconfirm --needed archiso
cp -r /usr/share/archiso/configs/releng/ /archlive

# Enable ssh
echo "sed -i 's|#\\(PermitEmptyPasswords \\).\\+|\\1yes|' /etc/ssh/sshd_config" >> /archlive/airootfs/root/customize_airootfs.sh
echo "systemctl enable sshd" >> /archlive/airootfs/root/customize_airootfs.sh

# delete archiso remove the splash pic
sed -i '1d' /archlive/syslinux/archiso_sys.cfg

# enable autoboot
sed -i '1iPROMPT 0' /archlive/syslinux/archiso_sys.cfg
sed -i '2iTIMEOUT 20' /archlive/syslinux/archiso_sys.cfg
sed -i '3iDEFAULT arch64' /archlive/syslinux/archiso_sys.cfg

# build iso image
cd /archlive && time ./build.sh -v
cp /archlive/out/archlinux-*.iso /tmp/archlive.iso
