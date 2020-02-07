#!/usr/bin/env bash

START_PATH=$(pwd)
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_FILE="$(basename "${BASH_SOURCE[0]}")"
SCRIPT_NAME="${SCRIPT_FILE%.*}"

AUR_HELPER="yay"
AUR_HELPER_URL="https://aur.archlinux.org/$AUR_HELPER.git"

DEBUG=false
MOUNTED_DEVICES=false

# ==============================================================================
#    C O M M O N   F U N C T I O N S
# ==============================================================================

trimSpace() {
	local TRIMMED="$1"
	TRIMMED="${TRIMMED# }"
	TRIMMED="${TRIMMED% }"
	echo "$TRIMMED"
}

trimQuotes() {
	local TRIMMED="$1"
	TRIMMED="${TRIMMED#\"}"
	TRIMMED="${TRIMMED%\"}"
	echo "$TRIMMED"
}

trim() {
	local TRIMMED=""
	TRIMMED="$(trimQuotes "$1")"
	TRIMMED="$(trimSpace "$TRIMMED")"
	echo "$TRIMMED"
}

printPrompt() {
	printf "[%s] $*" "$SCRIPT_NAME"
}

printLine() {
	printPrompt "$*\\n"
}

printHelpMessage() {
	printf "Usage: ./%s [-h] [-c config] [target]\\n" "$SCRIPT_FILE"
}

errorExit() {
	if [ $# -gt 0 ]; then
		FMT="ERROR: $1\\n"
		shift
		# shellcheck disable=SC2059 # FMT is a format string
		printf "$FMT" "$@"
	else
		printf "ERROR: Unknown error\\n"
	fi

	cd "$START_PATH" || \
		errorExit "Change directory to '%s' failed" "$START_PATH"

	isMountedDevices && unmountDevices

	exit 1
}

printWarning() {
	if [ $# -gt 0 ]; then
		FMT="WARNING: $1\\n"
		shift
		# shellcheck disable=SC2059 # FMT is a format string
		printf "$FMT" "$@"
	else
		printf "WARNING: Unknown warning\\n"
	fi
}

warnOnTestOrErrorExit() {
	if isDebugMode; then
		printWarning "$*"
	else
		errorExit "$*"
	fi
}

isUserExists() {
	getent passwd "$1" 1>/dev/null 2>&1 || \
		errorExit "User '%s' not exists (called by: %s line: %d)" \
			"$1" "${FUNCNAME[1]}" "${BASH_LINENO[1]}"
}

execAsUser() {
	local _USER="$1"
	shift
	isUserExists "$_USER"

	sudo -u "$_USER" "$@"
}

syncPacmanDb() {
	pacman -Sy --noconfirm --needed || exitError "Pacman syncronization failed"
}

installPackages() {
	local PACKAGES=()

	IFS=" " read -ra PACKAGES <<< "$@"
	for PACKAGE in "${PACKAGES[@]}"; do
		if ! pacman -Qi "$PACKAGE" 1>/dev/null 2>&1; then
			pacman -S --noconfirm --needed "$PACKAGE" || \
				errorExit "Install package '%s' failed" "$PACKAGE"
		fi
	done
}

installAurHelper() {
	local _USER="$1"

	[ -z "$AUR_PACKAGE_QUERY_URL" ] && errorExit "Empty package query URL"
	[ -z "$AUR_HELPER_URL" ] && errorExit "Empty $AUR_HELPER URL"

	isUserExists "$_USER"

	installPackages git

	pushd /tmp || errorExit "Change directory to '/tmp' failed"

	git clone "$AUR_HELPER_URL" "$AUR_HELPER" || errorExit "Clone $AUR_HELPER failed"
	[ ! -d ./"$AUR_HELPER" ] && errorExit "Clone $AUR_HELPER failed"
	chown -R "$_USER":users ./"$AUR_HELPER" || \
		errorExit "Change owner of /tmp/$AUR_HELPER failed"
	cd "$AUR_HELPER" || errorExit "Change directory to '$AUR_HELPER' failed"
	execAsUser "$_USER" makepkg -si --noconfirm --needed || \
		errorExit "Install $AUR_HELPER failed"
	cd ..

	popd || errorExit "Change back directory failed"

	syncPacmanDb
}

enableServices() {
	for SERVICE in "$@"; do
		systemctl enable "$SERVICE" || \
			errorExit "Enable systemd service '%s' failed" "$SERVICE"
	done
}

enableUserServices() {
	local _USER="$1"
	shift

	for SERVICE in "$@"; do
		execAsUser "$_USER" SYSTEMD_OFFLINE="true" systemctl --user enable "$SERVICE" || \
			errorExit "Enable systemd user service '%s' failed" "$SERVICE"
	done
}

setConfVariable() {
	local VAR_NAME=""
	local TRIMMED_VAL=""

	VAR_NAME="$(trimSpace "$1")"
	[ -z "$VAR_NAME" ] && errorExit "Invalid variable name"
	shift
	TRIMMED_VAL="$(trim "$*")"
	declare -g "$VAR_NAME=$TRIMMED_VAL"
}

setConfArray() {
	local VAR_NAME=""
	local TRIMMED_VAL=""

	VAR_NAME="$(trimSpace "$1")"
	[ -z "$VAR_NAME" ] && errorExit "Invalid array variable name"
	shift
	declare -g -a "$VAR_NAME"

	local IFS=\;
	local I=0
	for VAL in "$@"; do
		TRIMMED_VAL="$(trim "$VAL")"
		declare -g "${VAR_NAME[$I]}=$TRIMMED_VAL"
		I=$((I + 1))
	done
}

createFileSystem() {
	case "$1" in
	fat32)
		mkfs -t fat -F 32 -n "$2" "$3" || \
			errorExit "Create FAT32 filesystem on %s failed" "$3"
		;;

	*)
		mkfs -t "$1" -L "$2" "$3" || \
			errorExit "Create %s filesystem on %s failed" "$1" "$3"
		;;
	esac
}

getAllPartitions() {
	local INSTALL_DEVICE_FILE=""
	local BLK=""
	local attempts=3

	INSTALL_DEVICE_FILE="$(basename "$INSTALL_DEVICE")"

	while [ "$(wc -w <<<$BLK)" -ne 3 ]; do
		BLK="$(lsblk -l -n -o NAME -x NAME "$INSTALL_DEVICE" | \
			grep "^$INSTALL_DEVICE_FILE" | grep -v "^$INSTALL_DEVICE_FILE$" )"

		attempts=$((attempts - 1))
		[ $attempts -le 0 ] && break
	done

	# it seems lsblk output partions earlier as device file are appeared
	# this loop wait for device files of found block devices
	attempts=3
	local device_files_ready=false
	until [ "$device_files_ready" = true ]; do
		device_files_ready=true
		for device_file in $BLK; do
			[ -b "/dev/$device_file" ] || device_files_ready=false
		done

		attempts=$((attempts - 1))
		if [ $attempts -le 0 ]; then
			BLK=""
			break
		fi

		[ "$device_files_ready" = true ] || sleep 1
	done

	echo "$BLK"
}

flush() {
	sync
	sync
	sync
}

partProbe() {
	local attempts=3

	while ! partprobe "$INSTALL_DEVICE"; do
		attempts=$((attempts - 1))
		[ $attempts -le 0 ] && errorExit "partprobe failed"
	done
}

detectRootUuid() {
	ROOT_UUID="$(blkid -o value -s UUID "$ROOT_DEVICE")"
}

setPassword() {
	local _USER="$1"
	local PW_DEFAULT="$2"
	isUserExists "$_USER"

	if [ "$PW_DEFAULT" = "default" ]; then
		printLine "Setting default password for user '%s'" "$_USER"
		echo -e "password\npassword" | passwd "$_USER" || \
			errorExit "Set default password for '%s' user failed" "$_USER"
	else
		local attempts=3

		printLine "Setting password for user '%s'" "$_USER"
		while ! passwd "$_USER"; do
			[ $attempts -le 0 ] && \
				errorExit "Set password for '%s' user failed" "$_USER"
			printLine "Set password failed, try again"
			attempts=$((attempts - 1))
		done
	fi
}

setUserHomeDir() {
	isUserExists "$1"
	USER_HOME="$(getent passwd "$1" | cut -d : -f6)"
	[ ! -d "$USER_HOME" ] && errorExit "Home directory for user '%s' not found" "$1"
}

mkdirAsUser() {
	[ -z "$USER_HOME" ] && setUserHomeDir "$1"
	[ ! -d "$USER_HOME/$2" ] && (execAsUser "$1" mkdir -p "$USER_HOME/$2" || \
		exitError "Create directory '%s' failed" "$USER_HOME/$2")
}

setLocaleLangAsUser() {
	local _USER=$1
	shift
	isUserExists "$_USER"

	mkdirAsUser "$_USER" .config
	execAsUser "$_USER" echo "LANG=$*" >"$USER_HOME/.config/locale.conf"
}

cloneGitRepoAsUser() {
	local _USER=$1
	local _GIT_URL=$2
	local _TARGET_DIR=$3

	isUserExists "$_USER"

	execAsUser "$_USER" git clone "$_GIT_URL" "$_TARGET_DIR" || \
		errorExit "Clone customizing git repository failed"
}

optimizeMkinitcpioHookBefore() {
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

isDebugMode() {
	[ "$DEBUG" = true ]
}

isMountedDevices() {
	[ "$MOUNTED_DEVICES" = true ]
}

# ==============================================================================
#    B O O T L O A D E R   I N S T A L L   F U N C T I O N S
# ==============================================================================

installGrub() {
	installPackages grub

	grub-install --target=i386-pc --recheck "$INSTALL_DEVICE"
}

editGrubConfig() {
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

generateGrubConfig() {
	grub-mkconfig -o /boot/grub/grub.cfg
}

installGrubEfi() {
	installPackages dosfstools efibootmgr grub

	grub-install --target=x86_64-efi --efi-directory=/boot --recheck
}

createEfiStartupNsh() {
	echo "$EFI_STARTUP_NSH" > /boot/startup.nsh
}

installSystemDBoot() {
	bootctl --path=/boot install
}

createSystemDBootEntry() {
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

installLegacyBootloader() {
	installGrub

	detectDevices
	detectRootUuid
	editGrubConfig

	generateGrubConfig
}

installEfiBootloader() {
	detectDevices
	detectRootUuid

	case "$EFI_BOOT_LOADER" in
	grub)
		installGrubEfi
		[ -n "$EFI_STARTUP_NSH" ] && createEfiStartupNsh
		editGrubConfig
		generateGrubConfig
		;;

	systemd-boot)
		installSystemDBoot
		createSystemDBootEntry
		;;
	esac
}

# ==============================================================================
#    S T E P   F U N C T I O N S   B A S E
# ==============================================================================

setPacmanMirrorList() {
	sed -ie "s|^Server\\(.*\\)|#Server\\1|" /etc/pacman.d/mirrorlist || \
		errorExit "Disable all pacman servers failed"

	sed -ie "/## Germany/{n;s|^#Server\\(.*\\)|Server\\1|}" /etc/pacman.d/mirrorlist || \
		errorExit "Enable pacman server failed"

	syncPacmanDb

	installPackages pacman-contrib
	
	mv /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.dist
	rankmirrors -n 5 /etc/pacman.d/mirrorlist.dist | \
		tee /etc/pacman.d/mirrorlist

	syncPacmanDb
}

loadCvsDataConfig() {
	while IFS=, read -r tag val1 val2; do
		case "$tag" in
		"C") setConfVariable "$val1" "$val2";;
		"CA") setConfArray "$val1" "$val2";;
		esac
	done < "$CONF_FILE"

	isDebugMode && INSTALL_DEVICE="/dev/sda"
}

checkInstallDevice() {
	[ ! -b "$INSTALL_DEVICE" ] && \
		errorExit "INSTALL_DEVICE is not a block device ('%s')" "$INSTALL_DEVICE"
}

confirmInstall() {
	isDebugMode && return
	lsblk
	printLine "Installing to '$INSTALL_DEVICE' - ALL DATA ON IT WILL BE LOST!"
	printLine "Enter 'YES' (in capitals) to confirm and start the installation."

	printPrompt "> "
	read -r i
	if [ "$i" != "YES" ]; then
		printLine "Aborted."
		exit 0
	fi

	for i in {10..1}; do
		printf "Starting in %d - Press CTRL-C to abort...\\r" $i
		sleep 1
	done
	printf "\\n"
}

deactivateAllSwaps() {
	swapoff -a
}

wipeAllPartitions() {
	local INSTALL_DEVICE_PATH=""

	INSTALL_DEVICE_PATH="$(dirname "$INSTALL_DEVICE")"

	for i in $(getAllPartitions | sort -r); do
		if mount -l | grep -q "$INSTALL_DEVICE_PATH/$i"; then
			local MOUNT_POINT=""

			MOUNT_POINT="$(mount -l | grep "$INSTALL_DEVICE_PATH/$i" | \
				cut -d ' ' -f 3)"
			umount -R "$MOUNT_POINT" 2>/dev/null
		fi
		dd if=/dev/zero of="$INSTALL_DEVICE_PATH/$i" bs=1M count=1
	done

	flush
}

wipeDevice() {
	dd if=/dev/zero of="$INSTALL_DEVICE" bs=1M count=1

	flush
	partProbe
}

createNewPartitionTable() {
	parted -s -a optimal "$INSTALL_DEVICE" mklabel "$PARTITION_TABLE_TYPE" || \
		errorExit "Create new partition table of type '%s' failed" \
		"$PARTITION_TABLE_TYPE"
}

createNewPartitions() {
	local START="1";
	local END="$BOOT_SIZE"

	case "$BOOT_FILESYSTEM" in
	fat32)
		parted -s -a optimal "$INSTALL_DEVICE" mkpart primary \
			"$BOOT_FILESYSTEM" "${START}MiB" "${END}MiB" || \
			errorExit "Create boot partition for filesystem 'fat32' failed"
		;;
	*)
		parted -s -a optimal "$INSTALL_DEVICE" mkpart primary \
			"${START}MiB" "${END}MiB" || \
			errorExit "Create boot partition for filesystem '%s' failed" \
			"$BOOT_FILESYSTEM"
		;;
	esac

	START="$END"
	END=$((END + SWAP_SIZE))
	parted -s -a optimal "$INSTALL_DEVICE" mkpart primary linux-swap \
		"${START}MiB" "${END}MiB" || \
		errorExit "Create swap partition failed"

	START="$END"; END="100%"
	parted -s -a optimal "$INSTALL_DEVICE" mkpart primary \
		"${START}MiB" "${END}MiB" || \
		errorExit "Create root partition failed"

	parted -s -a optimal "$INSTALL_DEVICE" set 1 boot on || \
		errorExit "Set boot flag on '%s' failed" "$INSTALL_DEVICE"

	flush
	partProbe
}

detectDevices() {
	local INSTALL_DEVICE_PATH=""
	local ALL_PARTITIONS=()

	mapfile -t ALL_PARTITIONS < <(getAllPartitions)

	[ "${#ALL_PARTITIONS[@]}" -eq 3 ] || \
		errorExit "Invalid amount of partitions"

	INSTALL_DEVICE_PATH="$(dirname "$INSTALL_DEVICE")"

	BOOT_DEVICE="$INSTALL_DEVICE_PATH/${ALL_PARTITIONS[0]}"
	SWAP_DEVICE="$INSTALL_DEVICE_PATH/${ALL_PARTITIONS[1]}"
	ROOT_DEVICE="$INSTALL_DEVICE_PATH/${ALL_PARTITIONS[2]}"
}

formatDevices() {
	createFileSystem "$BOOT_FILESYSTEM" "$BOOT_LABEL" "$BOOT_DEVICE"
	mkswap -L "$SWAP_LABEL" "$SWAP_DEVICE"
	createFileSystem "$ROOT_FILESYSTEM" "$ROOT_LABEL" "$ROOT_DEVICE"
}

mountDevices() {
	mount "$ROOT_DEVICE" /mnt || \
		errorExit "Mount '%s' to '/mnt' failed" "$ROOT_DEVICE"

	MOUNTED_DEVICES=true

	[ ! -d /mnt/boot ] && mkdir /mnt/boot
	mount "$BOOT_DEVICE" /mnt/boot || \
		errorExit "Mount '%s' to '/mnt/boot' failed" "$BOOT_DEVICE"

	swapon "$SWAP_DEVICE" || \
		errorExit "Swap enable failed"
}

installStrapPackages() {
	BASE_DEVEL=""
	[ "$INSTALL_BASE_DEVEL" == "yes" ] && BASE_DEVEL="base-devel"
	pacstrap /mnt base $BASE_DEVEL || \
		errorExit "Installation of Arch Linux base failed"

	flush
}

generateFstab() {
	genfstab -p -U /mnt >> /mnt/etc/fstab || \
		errorExit "Create fstab failed"

	if [ "$OPTIMIZE_FSTAB_NOATIME" == "yes" ]; then
		sed -i -e "s|relatime|noatime|" /mnt/etc/fstab
	fi
}

bindToChroot() {
	local CHROOT_SCRIPT_PATH="$SCRIPT_PATH"

	mkdir -p "/mnt/$CHROOT_SCRIPT_PATH"
	mount --bind "$CHROOT_SCRIPT_PATH" "/mnt/$CHROOT_SCRIPT_PATH" ||\
		errorExit "Bind %s to /mnt/$CHROOT_SCRIPT_PATH failed" "$CHROOT_SCRIPT_PATH"
}

archChroot() {
	local IN_CHROOT_SCRIPT_PATH="$SCRIPT_PATH"
	local IN_CHROOT_CONF_FILE="$START_PATH/$CONF_FILE"
	local IN_CHROOT_PARAM="$IN_CHROOT_SCRIPT_PATH/$SCRIPT_FILE -c $IN_CHROOT_CONF_FILE"

	isDebugMode && IN_CHROOT_PARAM+=" -d"

	arch-chroot /mnt /usr/bin/bash -c "$IN_CHROOT_PARAM $1" || \
		errorExit "Installation failed and aborted"
}

unmountDevices() {
	flush
	umount -R /mnt
	swapoff "$SWAP_DEVICE"
}

# ==============================================================================
#    S T E P   F U N C T I O N S   C H R O O T
# ==============================================================================

loadCvsDataAll() {
	PACKAGES=()
	SERVICES=()
	USER_SERVICES=()
	AUR_PACKAGES=()
	USER_GROUPS=()
	GIT_PROJECTS=()

	while IFS=, read -r tag val1 val2; do
		case "$tag" in
		"C") setConfVariable "$val1" "$val2";;
		"CA") setConfArray "$val1" "$val2";;
		"P") PACKAGES+=("$val1");;
		"S") SERVICES+=("$val1");;
		"US") USER_SERVICES+=("$val1");;
		"A") AUR_PACKAGES+=("$val1");;
		"UG") USER_GROUPS+=("$val1");;
		"G") GIT_PROJECTS+=("$val1|$val2");;
		esac
	done < "$CONF_FILE"

	isDebugMode && INSTALL_DEVICE="/dev/sda"
}

setHostname() {
	echo "$HOSTNAME" > /etc/hostname
}

setTimezone() {
	[ -L /etc/localtime ] && rm -rf /etc/localtime
	ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime || \
		errorExit "Create timezone link failed"
}

enableLocales() {
	IFS=';' read -r -a LOCALES_ARRAY <<< "$GENERATE_LOCALES"
	for L in "${LOCALES_ARRAY[@]}"; do
		sed -i -e 's|^#\('"$L"'\)\s*$|\1|' /etc/locale.gen
	done
}

generateLocales() {
	locale-gen
}

setLocaleLang() {
	echo "LANG=$LOCALE_LANG" > /etc/locale.conf
}

setLocaleConf() {
	IFS=';' read -r -a LOCALE_CONF_ARRAY <<< "$LOCALE_CONF"
	for L in "${LOCALE_CONF_ARRAY[@]}"; do
		echo "$L" > /etc/locale.conf
	done
}

setHwclock() {
	printLine "Set RTC time to \"%s\"" "$(date)"
	hwclock --systohc --utc
}

setConsole() {
	cat > /etc/vconsole.conf << __END__
KEYMAP=$CONSOLE_KEYMAP
FONT=$CONSOLE_FONT
__END__
}

createInitCpio() {

	[ "$OPTIMIZE_MKINITCPIO_HOOK_KEYBOARD_BEFORE_AUTODETECT" == "yes" ] && \
		optimizeMkinitcpioHookBefore "keyboard" "autodetect"

	[ "$OPTIMIZE_MKINITCPIO_HOOK_BLOCK_BEFORE_AUTODETECT" == "yes" ] && \
		optimizeMkinitcpioHookBefore "block" "autodetect"

	mkinitcpio -p linux
}

rankingMirrorList() {
	installPackages pacman-contrib

	mv /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.dist
	rankmirrors -n "$RANKMIRRORS_TOP" /etc/pacman.d/mirrorlist.dist | \
		tee /etc/pacman.d/mirrorlist
}

setRootUserEnvironment() {
	setPassword root default
}

setOptimizeIoSchedulerKernel() {
	IO_SCHEDULER_KERNEL=""
	if [ "$OPTIMIZE_IO_SCHEDULER_KERNEL" == "yes" ]; then
		IO_SCHEDULER_KERNEL=" elevator=$OPTIMIZE_IO_SCHEDULER_KERNEL_VALUE"
	fi
}

setOptimizeFsckMode() {
	FSCK_MODE=""
	if [ "$OPTIMIZE_FSCK_MODE" == "yes" ]; then
		FSCK_MODE=" fsck.mode=$OPTIMIZE_FSCK_MODE_VALUE"
	fi
}

installBootloader() {
	case "$BOOT_METHOD" in
	legacy)
		installLegacyBootloader
		;;
	efi)
		installEfiBootloader
		;;
	esac
}

installSudo() {
	installPackages sudo

	chmod u+w /etc/sudoers
	sed -i -e 's|^#\s*\(%wheel ALL=(ALL) ALL\)$|\1|' /etc/sudoers

	# set no passwd to run the installation without asking
	# the user all the time about the password. If no debug
	# mode is set, revert this config in the last step of the
	# installation.
	sed -i -e 's|^#\s*\(%wheel ALL=(ALL) NOPASSWD: ALL\)$|\1|' /etc/sudoers

	cat >>/etc/sudoers <<__END__

# Root password for root access is required
Defaults rootpw
__END__
	chmod u-w /etc/sudoers
}

enableMultilib() {
	if grep -q "#\\[multilib\\]" < /etc/pacman.conf; then
		sed -i "s|^#\\(\\[multilib\\]\\)$|\\1|" /etc/pacman.conf
		sed -i "|^\\[multilib\\]$|{n;s|^#\\(.*\\)$|\\1|}" /etc/pacman.conf
	fi

	syncPacmanDb

	[ "$ENABLE_MULTILIB" == "yes" ] && \
		installPackages "$(pacman -Sqg multilib-devel)"
}

addUser() {
	# shellcheck disable=SC2153 # USER_NAME is not missspelling
	[ -z "$USER_NAME" ] && return

	# shellcheck disable=SC2153 # USER_GROUP is not missspelling
	useradd -g "$USER_GROUP" -G "$USER_GROUPS_EXTRA" -s "$USER_SHELL" \
		-c "$USER_REALNAME" -m "$USER_NAME"

	if [ "$USER_SET_PASSWORD" == "yes" ]; then
		setPassword "$USER_NAME" default
	else
		passwd -l "$USER_NAME"
	fi

	if [ -n "$USER_LOCALE" ] && [ -n "$USER_LOCALE_LANG" ]; then
		setLocaleLangAsUser "$USER_NAME" "$USER_LOCALE_LANG"
	fi
}

installAurPackages () {
	local PACKAGES=()

	installAurHelper "$USER_NAME"

	IFS=" " read -ra PACKAGES <<< "$@"
	[ ${#PACKAGES[@]} -gt 0 ] || return

	for PACKAGE in "${PACKAGES[@]}"; do
		if ! execAsUser "$USER_NAME" "$AUR_HELPER" -Qi "$PACKAGE" 1>/dev/null 2>&1; then
			execAsUser "$USER_NAME" "$AUR_HELPER" -S --noconfirm --needed "$PACKAGE" || \
				errorExit "Install $AUR_HELPER package '%s' failed" "$PACKAGE"
		fi
	done
}

setX11KeyMaps() {
	[ -z "$X11_KEYMAP_LAYOUT" ] && return

	cat > /etc/X11/xorg.conf.d/00-keyboard.conf <<__END__
# Written by systemd-localed(8), read by systemd-localed and Xorg. It's
# probably wise not to edit this file manually. Use localectl(1) to
# instruct systemd-localed to update it.
Section "InputClass"
        Identifier "system-keyboard"
        MatchIsKeyboard "on"
        Option "XkbLayout" "$X11_KEYMAP_LAYOUT"
        Option "XkbModel" "$X11_KEYMAP_MODEL"
        Option "XkbVariant" "$X11_KEYMAP_VARIANT"
        Option "XkbOptions" "$X11_KEYMAP_OPTIONS"
EndSection
__END__
}

customize() {
	local CLONE_AS_USER=""

	[ "$CUSTOMIZE" == "yes" ] || return
	[ -n "$CUSTOMIZE_GIT_URL" ] || errorExit "Empty customize git URL"
	[ -n "$CUSTOMIZE_TARGET_DIR" ] || errorExit "Empty cusomize target directory"
	[ ! -d "$CUSTOMIZE_TARGET_DIR" ] || \
		errorExit "Customize target directory already exists"
	[ -n "$CUSTOMIZE_RUN_SCRIPT" ] || errorExit "Empty customize script"

	if [ "${CUSTOMIZE_TARGET_DIR:0:1}" != "/" ]; then
		[ -z "$USER_HOME" ] && setUserHomeDir "$USER_HOME"
		CUSTOMIZE_TARGET_DIR="$USER_HOME/$CUSTOMIZE_TARGET_DIR"
		CLONE_AS_USER="yes"
	fi

	[ ! -d "$(dirname "$CUSTOMIZE_TARGET_DIR")" ] && \
		mkdir -p "$(dirname "$CUSTOMIZE_TARGET_DIR")"

	if [ "$CLONE_AS_USER" == "yes" ]; then
		execAsUser "$USER_NAME" git clone "$CUSTOMIZE_GIT_URL" \
			"$CUSTOMIZE_TARGET_DIR" || \
			errorExit "Clone customize git repo failed"
	else
		git clone "$CUSTOMIZE_GIT_URL" "$CUSTOMIZE_TARGET_DIR" || \
			errorExit "Clone customize git repo failed"
	fi

	pushd "$CUSTOMIZE_TARGET_DIR" || \
		errorExit "Change directory to '%s' failed" "$CUSTOMIZE_TARGET_DIR"

	# shellcheck disable=SC1090 # source file will be set from configuration file
	source "$CUSTOMIZE_RUN_SCRIPT" || errorExit "Run customizing script failed"
	
	popd || errorExit "Change back directory failed"
}

dotbot() {
	[ "$DOTBOT" == "yes" ] || return
	[ -z "$USER_HOME" ] && setUserHomeDir "$USER_HOME"

	installPackages python

	if [ "$DOTBOT_USE_CUSTOMIZE_GIT" == "yes" ]; then
		DOTBOT_TARGET_DIR="$CUSTOMIZE_TARGET_DIR"
	else
		[ -z "$DOTBOT_GIT_URL" ] && errorExit "Empty dotbot git URL"
		[ -z "$DOTBOT_TARGET_DIR" ] && errorExit "Empty dotbot target dir"
		
		DOTBOT_TARGET_DIR="$USER_HOME/$DOTBOT_TARGET_DIR"

		execAsUser "$USER_NAME" git clone "$DOTBOT_GIT_URL" \
			"$DOTBOT_TARGET_DIR" || \
			errorExit "Clone '%s' failed" "$DOTBOT_GIT_URL"
	fi

	pushd "$DOTBOT_TARGET_DIR" || \
		errorExit "Change directory to '%s' failed" "$DOTBOT_TARGET_DIR"

	if [ -z "$DOTBOT_INSTALL_CMD" ] && [ -z "$DOTBOT_INSTALL_ROOT_CMD" ]; then
		errorExit "Empty dotbot installation commands"
	fi

	if [ -n "$DOTBOT_INSTALL_CMD" ]; then
		if isDebugMode; then
			DOTBOT_INSTALL_CMD="$DOTBOT_INSTALL_CMD $DOTBOT_VERBOSE"
		fi

		# shellcheck disable=SC2086 # eval not working and double quots either
		execAsUser "$USER_NAME" $DOTBOT_INSTALL_CMD || \
			errorExit "$DOTBOT_INSTALL_CMD installation script failed"
	fi

	if [ -n "$DOTBOT_INSTALL_ROOT_CMD" ]; then
		if isDebugMode; then
			DOTBOT_INSTALL_ROOT_CMD="$DOTBOT_INSTALL_ROOT_CMD $DOTBOT_VERBOSE"
		fi

		$DOTBOT_INSTALL_ROOT_CMD || \
			errorExit "$DOTBOT_INSTALL_ROOT_CMD installation script failed"
	fi

	popd || errorExit "Change back directory failed"
}

addUserGroups() {
	local _GROUPS=("$@")
	[ ${#_GROUPS[@]} -gt 0 ] || return

	isUserExists "$USER_NAME"

	for GROUP in "${_GROUPS[@]}"; do
		usermod -aG "$GROUP" "$USER_NAME"
	done
}

cloneGitProjects() {
	local PROJECTS=("$@")
	[ ${#PROJECTS[@]} -gt 0 ] || return

	[ -z "$GIT_PROJECTS_DIR" ] && \
		errorExit "Project directory name for git repositories is empty"
	[ ! -d "$GIT_PROJECTS_DIR" ] && mkdirAsUser "$USER_NAME" "$GIT_PROJECTS_DIR"


	pushd "$USER_HOME/$GIT_PROJECTS_DIR" || \
		errorExit "Change directory to '%s' failed" "$USER_HOME/$GIT_PROJECTS_DIR"
	for PROJECT in "${PROJECTS[@]}"; do
		GIT_URL=${PROJECT%%|*}
		GIT_NAME=${PROJECT##*|}
		GIT_SSH_COMMAND="ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
		execAsUser "$USER_NAME" GIT_SSH_COMMAND="$GIT_SSH_COMMAND" git clone "$GIT_URL" ${GIT_NAME:+"$GIT_NAME"} || \
			warnOnTestOrErrorExit "Clone git repository '%s' failed" "$GIT_URL"
	done
	popd || errorExit "Change back directory failed"
}

setPasswords() {
	# if not installed in debug mode, revert NOPASSWD and ask the user for
	# root and user password. Otherwise leave the debug default password.
	if ! isDebugMode; then
		sed -i -e 's|^\s*\(%wheel ALL=(ALL) NOPASSWD: ALL\)$|# &|' /etc/sudoers
		setPassword root
		setPassword "$USER_NAME"
	fi
}

# ==============================================================================
#    G E T O P T S
# ==============================================================================

while getopts :hc:d opt; do
	case "$opt" in
	h)
		printHelpMessage
		exit 0
		;;
	c)
		CONF_FILE="$OPTARG"
		;;
	d)
		DEBUG=true
		set -x
		;;
	:)
		case "$OPTARG" in
		c)
			errorExit "Missing config file"
			;;
		esac
		errorExit
		;;
	\?)
		errorExit "Invalid option ('-%s')" "$OPTARG"
		;;
	esac
done
shift $((OPTIND - 1))

# ==============================================================================
#    M A I N
# ==============================================================================

INSTALL_TARGET="$1"

[ -z "$CONF_FILE" ] && CONF_FILE="$SCRIPT_PATH/$SCRIPT_NAME.csv"

[ ! -f "$CONF_FILE" ] && errorExit "Config file not found ('%s')" "$CONF_FILE"

[ -z "$INSTALL_TARGET" ] && INSTALL_TARGET="base"

case "$INSTALL_TARGET" in
	base)
		setPacmanMirrorList
		loadCvsDataConfig
		checkInstallDevice
		confirmInstall
		deactivateAllSwaps
		wipeAllPartitions
		wipeDevice
		createNewPartitionTable

		createNewPartitions
		detectDevices

		formatDevices
		mountDevices
		installStrapPackages
		generateFstab
		bindToChroot
		archChroot chroot

		printLine "Flushing - this might take a while..."

		unmountDevices

		printLine "Wake up, Neo... The installation is done!"

		exit 0
		;;

	chroot)
		loadCvsDataAll

		setHostname
		setTimezone

		enableLocales
		generateLocales
		setLocaleLang
		setLocaleConf

		setHwclock

		setConsole

		createInitCpio

		[ "$RANKMIRRORS" == "yes" ] && rankingMirrorList

		setRootUserEnvironment

		setOptimizeIoSchedulerKernel
		setOptimizeFsckMode

		installBootloader

		installSudo

		[ "$ENABLE_MULTILIB" == "yes" ] && enableMultilib

		addUser

		installPackages "${PACKAGES[@]}"

		installAurPackages "${AUR_PACKAGES[@]}"

		setX11KeyMaps

		customize

		dotbot

		enableServices "${SERVICES[@]}"

		enableUserServices "$USER_NAME" "${USER_SERVICES[@]}"

		addUserGroups "${USER_GROUPS[@]}"

		cloneGitProjects "${GIT_PROJECTS[@]}"

		setPasswords

		exit 0
		;;
	*)
		errorExit "Unknown target ('%s')" "$INSTALL_TARGET"
		;;
esac

#vim syntax=bash
