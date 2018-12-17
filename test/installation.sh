#!/bin/bash

ISO_NAMESPACE="alegsan"
ISO_PROJECT="ssh-archiso"
ISO_BRANCH="master"
ISO_JOB="build-archiso"
ISO_URL="https://gitlab.com/$ISO_NAMESPACE/$ISO_PROJECT/-/jobs/artifacts/$ISO_BRANCH/download?job=$ISO_JOB"

MD5_FILE="https://gitlab.com/$ISO_NAMESPACE/$ISO_PROJECT/-/jobs/artifacts/$ISO_BRANCH/file/md5.txt?job=build-archiso"

ARCH_BRANCH="master"
ARCH_INSTALL_PROJ="arch-install-$ARCH_BRANCH"
ARCH_INSTALL_URL="curl -L https://gitlab.com/schmidtandreas/arch-install/-/archive/$ARCH_BRANCH/$ARCH_INSTALL_PROJ.tar.gz"

SSH_COMMAND="ssh root@localhost -o StrictHostKeyChecking=no -p 10022"

get_archiso() {
	local extract_dir="$1"

	[ ! -d "$extract_dir" ] && return 1

	wget "$MD5_FILE" -O "$extract_dir/current_md5.txt"

	sed -i "s|out/|$extract_dir/|" "$extract_dir/current_md5.txt"

	if ! md5sum -c "$extract_dir/current_md5.txt"; then
		# clean up previous images
		rm /tmp/archlinux-*.iso
		wget "$ISO_URL" -O "$extract_dir/archiso.zip"
		unzip -o "$extract_dir/archiso.zip" -d "$extract_dir"
		rm -rf "$extract_dir/archiso.zip"
		rm -rf "$extract_dir/md5.txt"
	fi
}

wait_for_vm() {
	local timeout=10
	local max_timeout=240
	local ret=255

	echo "try to connect to vm..."

	while [ $max_timeout -ne 0 ]; do

		if $SSH_COMMAND "echo \"hello archlinux\"" 2> /dev/null; then
			ret=$?
			break
		fi

		echo "trying again in $timeout seconds..."
		max_timeout=$((max_timeout - timeout))
		sleep $timeout
	done

	return $ret
}

# main
[ ! -f "configs/$1" ] && exit 1

if ! get_archiso /tmp; then
	echo "ERROR: could not get archiso image"
	exit 1
fi

# create raw qemu image. Use /tmp because in some runners this
# directory is binded to the host /tmp directory to analyze the
# finished installation on the host maschine.
[ -f /tmp/arch-linux.img ] && rm /tmp/arch-linux.img
qemu-img create /tmp/arch-linux.img 10G

# start iso image
if ! qemu-system-x86_64 -enable-kvm \
		   -hda /tmp/arch-linux.img \
		   -cdrom /tmp/archlinux-*.iso \
		   -boot d \
		   -m 512 \
		   -net user,hostfwd=tcp::10022-:22 \
		   -net nic \
		   -daemonize \
		   -display none \
		   -bios /usr/share/ovmf/bios.bin; then
	echo "ERROR: could not start vm"
	exit 1
fi

if ! wait_for_vm; then
	echo "ERROR: could not connect to vm"
	exit 1
fi

$SSH_COMMAND "curl -L $ARCH_INSTALL_URL | tar zxvf -"
$SSH_COMMAND "$ARCH_INSTALL_PROJ/arch-install.sh -d -c $ARCH_INSTALL_PROJ/configs/$1"
