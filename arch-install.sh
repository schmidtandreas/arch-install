#!/usr/bin/env bash

START_PATH=$(pwd)
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_FILE="$(basename "${BASH_SOURCE[0]}")"
SCRIPT_NAME="${SCRIPT_FILE%.*}"

AUR_PACKAGE_QUERY_URL="https://aur.archlinux.org/package-query.git"
AUR_YAOURT_URL="https://aur.archlinux.org/yaourt.git"

TESTRUN=false

# ==============================================================================
#    C O M M O N   F U N C T I O N S
# ==============================================================================

doTrim() {
	local TRIMMED="$1"
	TRIMMED="${TRIMMED## }"
	TRIMMED="${TRIMMED%% }"
	echo "$TRIMMED"
}

doPrintPrompt() {
	printf "[%s] $*" "$SCRIPT_NAME"
}

doPrint() {
	doPrintPrompt "$*\\n"
}

doPrintHelpMessage() {
	printf "Usage: ./%s [-h] [-c config] [target]\\n" "$SCRIPT_FILE"
}

doErrorExit() {
	if [ $# -gt 0 ]; then
		FMT="ERROR: $1\\n"
		shift
		# shellcheck disable=SC2059 # FMT is a format string
		printf "$FMT" "$@"
	else
		printf "ERROR: Unknown error\\n"
	fi

	cd "$START_PATH" || \
		doErrorExit "Change directory to '%s' failed" "$START_PATH"
	exit 1
}

isUserExists() {
	getent passwd "$1" 1>/dev/null 2>&1 || \
		doErrorExit "User '%s' not exists (called by: %s line: %d)" \
			"$1" "${FUNCNAME[1]}" "${BASH_LINENO[1]}"
}

doAsUser() {
	local _USER="$1"
	shift
	isUserExists "$_USER"

	sudo -u "$_USER" "$@"
}

doInstallPackages() {
	local PACKAGES=()

	IFS=" " read -ra PACKAGES <<< "$@"
	for PACKAGE in "${PACKAGES[@]}"; do
		if ! pacman -Qi "$PACKAGE" 1>/dev/null 2>&1; then
			pacman -S --noconfirm --needed "$PACKAGE" || \
				doErrorExit "Install package '%s' failed" "$PACKAGE"
		fi
	done
}

doInstallYaourtPackages() {
	local _USER="$1"
	shift
	isUserExists "$_USER"
	local PACKAGES=()
	IFS=" " read -ra PACKAGES <<< "$@"

	for PACKAGE in "${PACKAGES[@]}"; do
		if ! doAsUser "$_USER" yaourt -Qi "$PACKAGE" 1>/dev/null 2>&1; then
 			doAsUser "$_USER" yaourt -S --noconfirm --needed "$PACKAGE" || \
				doErrorExit "Install yaourt package '%s' failed" "$PACKAGE"
		fi
	done
}

doInstallYaourt() {
	local _USER="$1"

	[ -z "$AUR_PACKAGE_QUERY_URL" ] && doErrorExit "Empty package query URL"
	[ -z "$AUR_YAOURT_URL" ] && doErrorExit "Empty yaourt URL"

	isUserExists "$_USER"

	doInstallPackges git

	pushd /tmp || doErrorExit "Change directory to '/tmp' failed"

	git clone "$AUR_PACKAGE_QUERY_URL" package-query || \
		doErrorExit "Clone package-query failed"
	[ ! -d ./package-query ] && doErrorExit "Clone package-query failed"
	chown -R "$_USER":users ./package-query || \
		doErrorExit "Change owner of package-query failed"
	cd package-query || \
		doErrorExit "Change directory to 'package-query' failed"
	doAsUser "$_USER" makepkg -si --noconfirm --needed || \
		doErrorExit "Install package-query failed"
	cd ..

	git clone "$AUR_YAOURT_URL" yaourt || doErrorExit "Clone yaourt failed"
	[ ! -d ./yaourt ] && doErrorExit "Clone yaourt failed"
	chown -R "$_USER":users ./yaourt || \
		doErrorExit "Change owner of /tmp/yaourt failed"
	cd yaourt || doErrorExit "Change directory to 'yaourt' failed"
	doAsUser "$_USER" makepkg -si --noconfirm --needed || \
		doErrorExit "Install yaourt failed"
	cd ..
	
	popd || doErrorExit "Change back directory failed"

	if grep -q "\\[archlinuxfr\\]" </etc/pacman.conf; then
		cat >>/etc/pacman.conf <<__END__

[archlinuxfr]
SigLevel = Never
Server = http://repo.archlinux.fr/\$arch
__END__
	fi

	pacman -Sy
}

doEnableServices() {
	for SERVICE in "$@"; do
		systemctl enable "$SERVICE" || \
			doErrorExit "Enable systemd service '%s' failed" "$SERVICE"
	done
}

doSetConfVariable() {
	local VAR_NAME=""

	VAR_NAME="$(doTrim "$1")"
	[ -z "$VAR_NAME" ] && doErrorExit "Invalid variable name"
	shift
	declare -g "$VAR_NAME"="$*"
}

doSetConfArray() {
	local VAR_NAME=""

	VAR_NAME="$(doTrim "$1")"
	[ -z "$VAR_NAME" ] && doErrorExit "Invalid array variable name"
	shift
	declare -g -a "$VAR_NAME"

	local IFS=\;
	local I=0
	for VAL in "$@"; do
		declare -g "${VAR_NAME[$I]}=$VAL"
		I=$((I + 1))
	done
}

doMkfs() {
	case "$1" in
	fat32)
		mkfs -t fat -F 32 -n "$2" "$3" || \
			doErrorExit "Create FAT32 filesystem on %s failed" "$3"
		;;

	*)
		mkfs -t "$1" -L "$2" "$3" || \
			doErrorExit "Create %s filesystem on %s failed" "$1" "$3"
		;;
	esac
}

doGetAllPartitions() {
	local INSTALL_DEVICE_FILE=""

	INSTALL_DEVICE_FILE="$(basename "$INSTALL_DEVICE")"

	lsblk -l -n -o NAME -x NAME "$INSTALL_DEVICE" | \
		grep "^$INSTALL_DEVICE_FILE" | grep -v "^$INSTALL_DEVICE_FILE$"
}

doFlush() {
	sync
	sync
	sync
}

doPartProbe() {
	partprobe "$INSTALL_DEVICE"
}

doDetectRootUuid() {
	ROOT_UUID="$(blkid -o value -s UUID "$ROOT_DEVICE")"
}

doSetPassword() {
	local PW_USER="root"

	[ -n "$1" ] && PW_USER="$1"

	doPrint "Setting password for user '$PW_USER'"
	local TRIES=0
	while [ $TRIES -lt 3 ]; do
		passwd "$PW_USER"
		local RET=$?
		if [ $RET -eq 0 ]; then
			TRIES=3
		else
			doPrint "Set password failed, try again"
		fi
		TRIES=$((TRIES + 1))
	done

	return $RET
}

setUserHomeDir() {
	isUserExists "$1"
	USER_HOME="$(getent passwd "$1" | cut -d : -f6)"
	[ ! -d "$USER_HOME" ] && doErrorExit "Home directory for user '%s' not found" "$1"
}

doUserMkdir() {
	[ -z "$USER_HOME" ] && setUserHomeDir "$1"
	[ ! -d "$USER_HOME/$2" ] && doAsUser "$1" mkdir -p "$USER_HOME/$2"
}

doUserSetLocaleLang() {
	local _USER=$1
	shift
	isUserExists "$_USER"

	doUserMkdir "$_USER" .config
	doAsUser "$_USER" echo "$*" >"$USER_HOME/.config/locale.conf"
}

doUserCloneGitRepo() {
	local _USER=$1
	local _GIT_URL=$2
	local _TARGET_DIR=$3

	isUserExists "$_USER"

	doAsUser "$_USER" git clone "$_GIT_URL" "$_TARGET_DIR" || \
		doErrorExit "Clone customizing git repository failed"
}

# ==============================================================================
#    S T E P   F U N C T I O N S   B A S E
# ==============================================================================

doSetPacmanMirrorList() {
	sed -ie "s|^Server\\(.*\\)|#Server\\1|" /etc/pacman.d/mirrorlist || \
		doErrorExit "Disable all pacman servers failed"

	sed -ie "/## Germany/{n;s|^#Server\\(.*\\)|Server\\1|}" /etc/pacman.d/mirrorlist || \
		doErrorExit "Enable pacman server failed"

	#pacman-key --init
	#pacman-key --populate
	#pacman-key --refresh-keys
	#pacman -Sy archlinux-keyring --noconfirm --needed
	pacman -Sy --noconfirm --needed
}

doLoadCvsDataConfig() {
	while IFS=, read -r tag val1 val2; do
		case "$tag" in
		"C") doSetConfVariable "$val1" "$val2";;
		"CA") doSetConfArray "$val1" "$val2";;
		esac
	done < "$CONF_FILE"
}

doCheckInstallDevice() {
	[ ! -b "$INSTALL_DEVICE" ] && \
		doErrorExit "INSTALL_DEVICE is not a block device ('%s')" "$INSTALL_DEVICE"
}

doConfirmInstall() {
	$TESTRUN && return
	lsblk
	doPrint "Installing to '$INSTALL_DEVICE' - ALL DATA ON IT WILL BE LOST!"
	doPrint "Enter 'YES' (in capitals) to confirm and start the installation."

	doPrintPrompt "> "
	read -r i
	if [ "$i" != "YES" ]; then
		doPrint "Aborted."
		exit 0
	fi

	for i in {10..1}; do
		printf "Starting in %d - Press CTRL-C to abort...\\r" $i
		sleep 1
	done
	printf "\\n"
}

doDeactivateAllSwaps() {
	swapoff -a
}

doWipeAllPartitions() {
	local INSTALL_DEVICE_PATH=""

	INSTALL_DEVICE_PATH="$(dirname "$INSTALL_DEVICE")"

	for i in $(doGetAllPartitions | sort -r); do
		if mount -l | grep -q "$INSTALL_DEVICE_PATH/$i"; then
			local MOUNT_POINT=""

			MOUNT_POINT="$(mount -l | grep "$INSTALL_DEVICE_PATH/$i" | \
				cut -d ' ' -f 3)"
			umount -R "$MOUNT_POINT" 2>/dev/null
		fi
		dd if=/dev/zero of="$INSTALL_DEVICE_PATH/$i" bs=1M count=1
	done

	doFlush
}

doWipeDevice() {
	dd if=/dev/zero of="$INSTALL_DEVICE" bs=1M count=1

	doFlush
	doPartProbe
}

doCreateNewPartitionTable() {
	parted -s -a optimal "$INSTALL_DEVICE" mklabel "$PARTITION_TABLE_TYPE"
}

doCreateNewPartitions() {
	local START="1";
	local END="$BOOT_SIZE"

	case "$BOOT_FILESYSTEM" in
	fat32)
		parted -s -a optimal "$INSTALL_DEVICE" mkpart primary \
			"$BOOT_FILESYSTEM" "${START}MiB" "${END}MiB"
		;;
	*)
		parted -s -a optimal "$INSTALL_DEVICE" mkpart primary \
			"${START}MiB" "${END}MiB"
		;;
	esac

	START="$END"
	END=$((END + SWAP_SIZE))
	parted -s -a optimal "$INSTALL_DEVICE" mkpart primary linux-swap \
		"${START}MiB" "${END}MiB"

	START="$END"; END="100%"
	parted -s -a optimal "$INSTALL_DEVICE" mkpart primary \
		"${START}MiB" "${END}MiB"

	parted -s -a optimal "$INSTALL_DEVICE" set 1 boot on

	doFlush
	doPartProbe
}

doDetectDevices() {
	local INSTALL_DEVICE_PATH=""
	local ALL_PARTITIONS=()

	mapfile -t ALL_PARTITIONS < <(doGetAllPartitions)

	INSTALL_DEVICE_PATH="$(dirname "$INSTALL_DEVICE")"

	BOOT_DEVICE="$INSTALL_DEVICE_PATH/${ALL_PARTITIONS[0]}"
	SWAP_DEVICE="$INSTALL_DEVICE_PATH/${ALL_PARTITIONS[1]}"
	ROOT_DEVICE="$INSTALL_DEVICE_PATH/${ALL_PARTITIONS[2]}"
}

doFormat() {
	doMkfs "$BOOT_FILESYSTEM" "$BOOT_LABEL" "$BOOT_DEVICE"
	mkswap -L "$SWAP_LABEL" "$SWAP_DEVICE"
	doMkfs "$ROOT_FILESYSTEM" "$ROOT_LABEL" "$ROOT_DEVICE"
}

doMount() {
	mount "$ROOT_DEVICE" /mnt
	[ ! -d /mnt/boot ] && mkdir /mnt/boot
	mount "$BOOT_DEVICE" /mnt/boot

	swapon "$SWAP_DEVICE"
}

doPacstrap() {
	BASE_DEVEL=""
	[ "$INSTALL_BASE_DEVEL" == "yes" ] && BASE_DEVEL="base-devel"
	pacstrap /mnt base $BASE_DEVEL || \
		doErrorExit "Installation of Arch Linux base failed"

	doFlush
}

doGenerateFstab() {
	genfstab -p -U /mnt >> /mnt/etc/fstab || \
		doErrorExit "Create fstab failed"

	if [ "$OPTIMIZE_FSTAB_NOATIME" == "yes" ]; then
		sed -i -e "s|relatime|noatime|" /mnt/etc/fstab
	fi
}

doBindToChroot() {
	local CHROOT_SCRIPT_PATH="$SCRIPT_PATH"

	mkdir -p /mnt/$CHROOT_SCRIPT_PATH
	mount --bind "$CHROOT_SCRIPT_PATH" /mnt/$CHROOT_SCRIPT_PATH ||\
		doErrorExit "Bind %s to /mnt/$CHROOT_SCRIPT_PATH failed" "$CHROOT_SCRIPT_PATH"
}

doChroot() {
	local IN_CHROOT_SCRIPT_PATH="$SCRIPT_PATH"
	local IN_CHROOT_CONF_FILE="$START_PATH/$CONF_FILE"
	local IN_CHROOT_TESTRUN_PARAM="$([ "$TESTRUN" = true ] && echo "-d" || echo "")"

	arch-chroot /mnt /usr/bin/bash -c \
		"'$IN_CHROOT_SCRIPT_PATH/$SCRIPT_FILE' -c '$IN_CHROOT_CONF_FILE' \
		'$IN_CHROOT_TESTRUN_PARAM' $1" || doErrorExit "Installation failed and aborted"
}

doUnmount() {
	doFlush
	umount -R /mnt
	swapoff "$SWAP_DEVICE"
}

# ==============================================================================
#    S T E P   F U N C T I O N S   C H R O O T
# ==============================================================================

doLoadCvsDataAll() {
	PACKAGES=()
	SERVICES=()
	AUR_PACKAGES=()
	GIT_PROJECTS=()

	while IFS=, read -r tag val1 val2; do
		case "$tag" in
		"C") doSetConfVariable "$val1" "$val2";;
		"CA") doSetConfArray "$val1" "$val2";;
		"P") PACKAGES+=("$val1");;
		"S") SERVICES+=("$val1");;
		"A") AUR_PACKAGES+=("$val1");;
		"G") GIT_PROJECTS+=("$val1|$val2");;
		esac
	done < "$CONF_FILE"
}

doSetHostname() {
	echo "$HOSTNAME" > /etc/hostname
}

doSetTimezone() {
	[ -L /etc/localtime ] && rm -rf /etc/localtime
	ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime || \
		doErrorExit "Create timezone link failed"
}

doEnableLocales() {
	for L in "${GENERATE_LOCALES[@]}"; do
		sed -i -e 's|^#\('"$L"'\)\s*$|\1|' /etc/locale.gen
	done
}

doGenerateLocales() {
	locale-gen
}

doSetLocaleLang() {
	echo "LANG=$LOCALE_LANG" > /etc/locale.conf
}

doSetHwclock() {
	doPrint "Set RTC time to \"%s\"" "$(date)"
	hwclock --systohc --utc
}

doSetConsole() {
	cat > /etc/vconsole.conf << __END__
KEYMAP=$CONSOLE_KEYMAP
FONT=$CONSOLE_FONT
__END__
}

doOptimizeMkinitcpioHookBefore() {
	# default: HOOKS="base udev autodetect modconf block filesystems keyboard fsck"
	sed -e 's/^\(\(HOOKS=\)\(.*\)\)$/#\1\n\2\3/' < /etc/mkinitcpio.conf > /tmp/mkinitcpio.conf
	awk 'm = $0 ~ /^HOOKS=/ {
			gsub(/'"$1"'/, "", $0);
			gsub(/'"$2"'/, "'"$1"' '"$2"'", $0);
			gsub(/  /, " ", $0);
			print
		} !m { print }' /tmp/mkinitcpio.conf > /etc/mkinitcpio.conf
	rm /tmp/mkinitcpio.conf
}

doMkinitcpio() {

	[ "$OPTIMIZE_MKINITCPIO_HOOK_KEYBOARD_BEFORE_AUTODETECT" == "yes" ] && \
		doOptimizeMkinitcpioHookBefore "keyboard" "autodetect"

	[ "$OPTIMIZE_MKINITCPIO_HOOK_BLOCK_BEFORE_AUTODETECT" == "yes" ] && \
		doOptimizeMkinitcpioHookBefore "block" "autodetect"

	mkinitcpio -p linux
}

doRankmirrors() {
	mv /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.dist
	rankmirrors -n "$RANKMIRRORS_TOP" /etc/pacman.d/mirrorlist.dist | \
		tee /etc/pacman.d/mirrorlist
}

doSetRootUserEnvironment() {
	$TESTRUN || doSetPassword root
}

doSetOptimizeIoSchedulerKernel() {
	IO_SCHEDULER_KERNEL=""
	if [ "$OPTIMIZE_IO_SCHEDULER_KERNEL" == "yes" ]; then
		IO_SCHEDULER_KERNEL=" elevator=$OPTIMIZE_IO_SCHEDULER_KERNEL_VALUE"
	fi
}

doSetOptimizeFsckMode() {
	FSCK_MODE=""
	if [ "$OPTIMIZE_FSCK_MODE" == "yes" ]; then
		FSCK_MODE=" fsck.mode=$OPTIMIZE_FSCK_MODE_VALUE"
	fi
}

doInstallGrub() {
	doInstallPackages grub

	grub-install --target=i386-pc --recheck "$INSTALL_DEVICE"
}

doEditGrubConfig() {
	local OPTIONS=""

	OPTIONS+="root=UUID=$ROOT_UUID "
	OPTIONS+="$KERNEL_CMDLINE "
	OPTIONS+="lang=$CONSOLE_KEYMAP "
	OPTIONS+="locale=$LOCALE_LANG "
	OPTIONS+="$IO_SCHEDULER_KERNEL $FSCK_MODE"

	sed -e 's/^\(\(GRUB_CMDLINE_LINUX_DEFAULT=\)\(.*\)\)$/#\1\n\2\3/' < /etc/default-grub > /tmp/default-grub
	awk 'm = $0 ~ /^GRUB_CMDLINE_LINUX_DEFAULT=/ {
			gsub(/quiet/, "'"$OPTIONS"'", $0);
			print
		} !m { print }' /tmp/default-grub > /etc/default/grub
	rm /tmp/default-grub
}

doGenerateGrubConfig() {
	grub-mkconfig -o /boot/grub/grub.cfg
}

doInstallGrubEfi() {
	doInstallPackages dosfstools efibootmgr grub

	grub-install --target=x86_64-efi --efi-directory=/boot --recheck
}

doCreateEfiStartupNsh() {
	echo "$EFI_STARTUP_NSH" > /boot/startup.nsh
}

doInstallSystemDBoot() {
	bootctl --path=/boot install
}

doCreateSystemDBootEntry() {
	local ENTRY_FILE=""
	local OPTIONS=""

	ENTRY_FILE="/boot/loader/entries/$(cat /etc/machine-id)-$(uname -r).conf"

	OPTIONS+="root=UUID=$ROOT_UUID "
	OPTIONS+="$KERNEL_CMDLINE "
	OPTIONS+="lang=$CONSOLE_KEYMAP "
	OPTIONS+="locale=$LOCALE_LANG "
	OPTIONS+="$IO_SCHEDULER_KERNEL $FSCK_MODE"

	cat > "$ENTRY_FILE" << __END__
title Arch Linux
linux /vmlinuz-linux
__END__

	if [ "$INSTALL_INTEL_UCODE" == "yes" ]; then
		cat >> "$ENTRY_FILE" << __END__
initrd /intel-ucode.img
__END__
	fi

	cat >> "$ENTRY_FILE" << __END__
initrd /initramfs-linux.img
options $OPTIONS
__END__
}

doInstallLegacyBootloader() {
	doInstallGrub

	doDetectDevices
	doDetectRootUuid
	doEditGrubConfig

	doGenerateGrubConfig
}

doInstallEfiBootloader() {
	doDetectDevices
	doDetectRootUuid

	case "$EFI_BOOT_LOADER" in
	grub)
		doInstallGrubEfi
		[ ! -z "$EFI_STARTUP_NSH" ] && doCreateEfiStartupNsh
		doEditGrubConfig
		doGenerateGrubConfig
		;;

	systemd-boot)
		doInstallSystemDBoot
		doCreateSystemDBootEntry
		;;
	esac
}

doInstallBootloader() {
	case "$BOOT_METHOD" in
	legacy)
		doInstallLegacyBootloader
		;;
	efi)
		doInstallEfiBootloader
		;;
	esac
}

doInstallSudo() {
	doInstallPackages sudo

	chmod u+w /etc/sudoers
	sed -i -e 's|^#\s*\(%wheel ALL=(ALL) ALL\)$|\1|' /etc/sudoers
	sed -i -e 's|^#\s*\(%wheel ALL=(ALL) NOPASSWD: ALL\)$|\1|' /etc/sudoers

	cat >>/etc/sudoers <<__END__

# Root password for root access is required
Defaults rootpw
__END__
	chmod u-w /etc/sudoers
}

doEnableMultilib() {
	if grep -q "#\\[multilib\\]" < /etc/pacman.conf; then
		sed -i "s|^#\\(\\[multilib\\]\\)$|\\1|" /etc/pacman.conf
		sed -i "|^\\[multilib\\]$|{n;s|^#\\(.*\\)$|\\1|}" /etc/pacman.conf
	fi

	pacman -Sy --noconfirm --needed

	[ "$ENABLE_MULTILIB" == "yes" ] && \
		doInstallPackages "$(pacman -Sqg multilib-devel)"
}

doAddUser() {
	# shellcheck disable=SC2153 # USER_NAME is not missspelling
	[ -z "$USER_NAME" ] && return

	useradd -g "$USER_GROUP" -G "$USER_GROUPS_EXTRA" -s /bin/bash \
		-c "$USER_REALNAME" -m "$USER_NAME"

	if [ "$USER_SET_PASSWORD" == "yes" ] && [ "$TESTRUN" = false ]; then
		doSetPassword "$USER_NAME"
	else
		passwd -l "$USER_NAME"
	fi

	if [ -n "$USER_LOCALE" ] && [ -n "$USER_LOCALE_LANG" ]; then
		doUserSetLocaleLang "$USER_NAME" "$USER_LOCALE_LANG"
	fi
}

doInstallAurPackages () {
	local PACKAGES=("$@")
	[ ${#PACKAGES[@]} -gt 0 ] || return

	doInstallYaourt "$USER_NAME"

	doInstallYaourtPackages "$USER_NAME" "${PACKAGES[@]}"
}

doCloneGits() {
	local PROJECTS=("$@")
	[ ${#PROJECTS[@]} -gt 0 ] || return

	[ -z "$GIT_PROJECTS_DIR" ] && \
		doErrorExit "Project directory name for git repositories is empty"
	[ ! -d "$GIT_PROJECTS_DIR" ] && doUserMkdir "$USER_NAME" "$GIT_PROJECTS_DIR"


	pushd "$USER_HOME/$GIT_PROJECTS_DIR" || \
		doErrorExit "Change directory to '%s' failed" "$USER_HOME/$GIT_PROJECTS_DIR"
	for PROJECT in "${PROJECTS[@]}"; do
		GIT_URL=${PROJECT%%|*}
		GIT_NAME=${PROJECT##*|}
		doAsUser "$USER_NAME" git clone "$GIT_URL" "$GIT_NAME" || \
			doErrorExit "Clone git repository '%s' failed" "$GIT_URL"
	done
	popd || doErrorExit "Change back directory failed"
}

doCustomize() {
	[ "$CUSTOMIZE" == "yes" ] || return
	[ -z "$CUSTOMIZE_GIT_URL" ] && doErrorExit "Empty customize git URL"
	[ -n "$CUSTOMIZE_TARGET_DIR" ] && \
		doUserCloneGitRepo "$USER_NAME" "$CUSTOMIZE_GIT_URL" "$CUSTOMIZE_TARGET_DIR"

	if [ -n "$CUSTOMIZE_RUN_SCRIPT" ]; then
		pushd "$CUSTOMIZE_TARGET_DIR" || \
			doErrorExit "Change directory to '%s' failed" "$CUSTOMIZE_TARGET_DIR"
		# shellcheck disable=SC1090 # source file will be set from configuration file
		source "$CUSTOMIZE_RUN_SCRIPT" || doErrorExit "Customizing script failed"
		popd || doErrorExit "Change back directory failed"
	fi
}

# ==============================================================================
#    G E T O P T S
# ==============================================================================

while getopts :hc:d opt; do
	case "$opt" in
	h)
		doPrintHelpMessage
		exit 0
		;;
	c)
		CONF_FILE="$OPTARG"
		;;
	d)
		TESTRUN=true
		# in case of a testrun we also want to get some
		# debug information
		set -x
		;;
	:)
		case "$OPTARG" in
		c)
			doErrorExit "Missing config file"
			;;
		esac
		doErrorExit
		;;
	\?)
		doErrorExit "Invalid option ('-%s')" "$OPTARG"
		;;
	esac
done
shift $((OPTIND - 1))

# ==============================================================================
#    M A I N
# ==============================================================================

INSTALL_TARGET="$1"

[ -z "$CONF_FILE" ] && CONF_FILE="$SCRIPT_PATH/$SCRIPT_NAME.csv"

[ ! -f "$CONF_FILE" ] && doErrorExit "Config file not found ('%s')" "$CONF_FILE"

[ -z "$INSTALL_TARGET" ] && INSTALL_TARGET="base"

case "$INSTALL_TARGET" in
	base)
		doSetPacmanMirrorList
		doLoadCvsDataConfig
		doCheckInstallDevice
		doConfirmInstall
		doDeactivateAllSwaps
		doWipeAllPartitions
		doWipeDevice
		doCreateNewPartitionTable

		doCreateNewPartitions
		doDetectDevices

		doFormat
		doMount
		doPacstrap
		doGenerateFstab
		doBindToChroot
		doChroot chroot

		doPrint "Flushing - this might take a while..."

		doUnmount

		doPrint "Wake up, Neo... The installation is done!"

		exit 0
		;;

	chroot)
		doLoadCvsDataAll

		doSetHostname
		doSetTimezone

		doEnableLocales
		doGenerateLocales
		doSetLocaleLang

		doSetHwclock

		doSetConsole

		doMkinitcpio

		[ "$RANKMIRRORS" == "yes" ] && doRankmirrors

		doSetRootUserEnvironment

		doSetOptimizeIoSchedulerKernel
		doSetOptimizeFsckMode

		doInstallBootloader

		doInstallSudo

		[ "$ENABLE_MULTILIB" == "yes" ] && doEnableMultilib

		doAddUser

		doInstallPackages "${PACKAGES[@]}"

		doInstallAurPackages "${AUR_PACKAGES[@]}"

		doEnableServices "${SERVICES[@]}"

		doCustomize

		doCloneGits "${GIT_PROJECTS[@]}"

		exit 0
		;;
	*)
		doErrorExit "Unknown target ('%s')" "$INSTALL_TARGET"
		;;
esac

#vim syntax=bash
