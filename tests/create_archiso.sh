#!/bin/bash -x

set -e

docker rm -f iso_builder || true
docker pull base/archlinux
docker run --detach -it -v /tmp:/tmp --privileged --name iso_builder base/archlinux bash

docker exec iso_builder sh -c "mkdir /run/shm"
docker exec iso_builder sh -c "sed -ie \"0,/^Server.*/ s|^Server\\(.*\\)|#Server\\1|\" /etc/pacman.d/mirrorlist"
docker exec iso_builder sh -c "pacman -Sy"
docker exec iso_builder sh -c "pacman -S --noconfirm --needed archiso"
docker exec iso_builder sh -c "cp -r /usr/share/archiso/configs/releng/ /archlive"

# Enable ssh
docker exec iso_builder sh -c "echo \"sed -i 's|#\\(PermitEmptyPasswords \\).\\+|\\1yes|' /etc/ssh/sshd_config\" >> /archlive/airootfs/root/customize_airootfs.sh"
docker exec iso_builder sh -c "echo \"systemctl enable sshd\" >> /archlive/airootfs/root/customize_airootfs.sh"

# delete archiso remove the splash pic
docker exec iso_builder sh -c "sed -i '1d' /archlive/syslinux/archiso_sys.cfg"

# enable autoboot
docker exec iso_builder sh -c "sed -i '1iPROMPT 0' /archlive/syslinux/archiso_sys.cfg"
docker exec iso_builder sh -c "sed -i '2iTIMEOUT 20' /archlive/syslinux/archiso_sys.cfg"
docker exec iso_builder sh -c "sed -i '3iDEFAULT arch64' /archlive/syslinux/archiso_sys.cfg"

# build iso image
docker exec iso_builder sh -c "cd /archlive && time ./build.sh -v"
docker exec iso_builder sh -c "cp /archlive/out/archlinux-*.iso /tmp/archlive.iso"

# remove build docker container
docker rm -f iso_builder || true
