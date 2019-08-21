#!/bin/bash

CFG_FILE_NAME="$1"
shift
ARCH_BRANCH="$1"
shift

ISO_NAMESPACE="alegsan"
ISO_PROJECT="ssh-archiso"
ISO_BRANCH="master"
ISO_JOB="build-archiso"
ISO_URL="https://gitlab.com/$ISO_NAMESPACE/$ISO_PROJECT/-/jobs/artifacts/$ISO_BRANCH/download?job=$ISO_JOB"

MD5_FILE="https://gitlab.com/$ISO_NAMESPACE/$ISO_PROJECT/-/jobs/artifacts/$ISO_BRANCH/file/md5.txt?job=build-archiso"

[ -z "$ARCH_BRANCH" ] && ARCH_BRANCH="master"
ARCH_INSTALL_PROJ="arch-install-$ARCH_BRANCH"
ARCH_INSTALL_URL="https://gitlab.com/schmidtandreas/arch-install/-/archive/$ARCH_BRANCH/$ARCH_INSTALL_PROJ.tar.gz"

CFG_FILE_PATH="$ARCH_INSTALL_PROJ/configs/$CFG_FILE_NAME"

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
	local step=10
	local timeout=240
	local ret=255

	echo "try to connect to vm..."

	while [ $timeout -ne 0 ]; do
		if $SSH_COMMAND "echo \"hello archlinux\"" 2> /dev/null; then
			ret=$?
			break
		fi

		echo "trying again in $timeout seconds..."
		timeout=$((timeout - step))
		sleep $step
	done

	return $ret
}

wait_for_vm_down() {
	local step=10
	local timeout=60
	local ret=255

	echo "waiting until vm is down..."

	while [ $timeout -gt 0 ]; do
		if ! pidof qemu-system-x86_64 >/dev/null; then
			ret=0
			break
		fi
		timeout=$((timeout - step))
		sleep $step
	done

	return $ret
}

# main
[ ! -f "configs/$CFG_FILE_NAME" ] && exit 1

if ! get_archiso /tmp; then
	echo "ERROR: could not get archiso image"
	exit 1
fi

# create raw qemu image. Use /tmp because in some runners this
# directory is binded to the host /tmp directory to analyze the
# finished installation on the host maschine.
[ -f /tmp/arch-linux.img ] && rm /tmp/arch-linux.img
qemu-img create /tmp/arch-linux.img 15G

# start iso image
if ! qemu-system-x86_64 -enable-kvm \
		   -drive file=/tmp/arch-linux.img,index=0,media=disk,format=raw \
		   -cdrom /tmp/archlinux-*.iso \
		   -boot d \
		   -m 2048 \
		   -netdev user,hostfwd=tcp::10022-:22,id=nic1 \
		   -device e1000,netdev=nic1 \
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
$SSH_COMMAND "$ARCH_INSTALL_PROJ/arch-install.sh -d -c $CFG_FILE_PATH"
$SSH_COMMAND "shutdown -h now"

if ! wait_for_vm_down; then
	echo "Timeout for qemu shutdown is expired"
	exit 1
fi

# TODO maybe it's better to remove just the key?
rm ~/.ssh/known_hosts
