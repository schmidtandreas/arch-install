#!/usr/bin/env bash

START_PATH=$(pwd)
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_FILE="$(basename "${BASH_SOURCE[0]}")"
SCRIPT_NAME="${SCRIPT_FILE%.*}"

AUR_PACKAGE_QUERY_URL="https://aur.archlinux.org/package-query.git"
AUR_YAOURT_URL="https://aur.archlinux.org/yaourt.git"

TESTRUN=false
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
	if isTestRun; then
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

installYaourtPackages() {
	local _USER="$1"
	shift
	isUserExists "$_USER"
	local PACKAGES=()
	IFS=" " read -ra PACKAGES <<< "$@"

	for PACKAGE in "${PACKAGES[@]}"; do
		if ! execAsUser "$_USER" yaourt -Qi "$PACKAGE" 1>/dev/null 2>&1; then
			execAsUser "$_USER" yaourt -S --noconfirm --needed "$PACKAGE" || \
				errorExit "Install yaourt package '%s' failed" "$PACKAGE"
		fi
	done
}

installYaourt() {
	local _USER="$1"

	[ -z "$AUR_PACKAGE_QUERY_URL" ] && errorExit "Empty package query URL"
	[ -z "$AUR_YAOURT_URL" ] && errorExit "Empty yaourt URL"

	isUserExists "$_USER"

	installPackages git

	pushd /tmp || errorExit "Change directory to '/tmp' failed"

	git clone "$AUR_PACKAGE_QUERY_URL" package-query || \
		errorExit "Clone package-query failed"
	[ ! -d ./package-query ] && errorExit "Clone package-query failed"
	chown -R "$_USER":users ./package-query || \
		errorExit "Change owner of package-query failed"
	cd package-query || \
		errorExit "Change directory to 'package-query' failed"
	execAsUser "$_USER" makepkg -si --noconfirm --needed || \
		errorExit "Install package-query failed"
	cd ..

	git clone "$AUR_YAOURT_URL" yaourt || errorExit "Clone yaourt failed"
	[ ! -d ./yaourt ] && errorExit "Clone yaourt failed"
	chown -R "$_USER":users ./yaourt || \
		errorExit "Change owner of /tmp/yaourt failed"
	cd yaourt || errorExit "Change directory to 'yaourt' failed"
	execAsUser "$_USER" makepkg -si --noconfirm --needed || \
		errorExit "Install yaourt failed"
	cd ..
	
	popd || errorExit "Change back directory failed"

	if grep -q "\\[archlinuxfr\\]" </etc/pacman.conf; then
		cat >>/etc/pacman.conf <<__END__

[archlinuxfr]
SigLevel = Never
Server = http://repo.archlinux.fr/\$arch
__END__
	fi

	syncPacmanDb
}

enableServices() {
	for SERVICE in "$@"; do
		systemctl enable "$SERVICE" || \
			errorExit "Enable systemd service '%s' failed" "$SERVICE"
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

	INSTALL_DEVICE_FILE="$(basename "$INSTALL_DEVICE")"

	lsblk -l -n -o NAME -x NAME "$INSTALL_DEVICE" | \
		grep "^$INSTALL_DEVICE_FILE" | grep -v "^$INSTALL_DEVICE_FILE$"
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
	local PW_USER="root"

	[ -n "$1" ] && PW_USER="$1"

	printLine "Setting password for user '$PW_USER'"
	local TRIES=0
	while [ $TRIES -lt 3 ]; do
		passwd "$PW_USER"
		local RET=$?
		if [ $RET -eq 0 ]; then
			TRIES=3
		else
			printLine "Set password failed, try again"
		fi
		TRIES=$((TRIES + 1))
	done

	return $RET
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

isTestRun() {
	[ "$TESTRUN" = true ]
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
		[ ! -z "$EFI_STARTUP_NSH" ] && createEfiStartupNsh
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
}

loadCvsDataConfig() {
	while IFS=, read -r tag val1 val2; do
		case "$tag" in
		"C") setConfVariable "$val1" "$val2";;
		"CA") setConfArray "$val1" "$val2";;
		esac
	done < "$CONF_FILE"
}

checkInstallDevice() {
	[ ! -b "$INSTALL_DEVICE" ] && \
		errorExit "INSTALL_DEVICE is not a block device ('%s')" "$INSTALL_DEVICE"
}

confirmInstall() {
	isTestRun && return
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
	parted -s -a optimal "$INSTALL_DEVICE" mklabel "$PARTITION_TABLE_TYPE"
}

createNewPartitions() {
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

	isTestRun && IN_CHROOT_PARAM+=" -d"

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
	AUR_PACKAGES=()
	USERGROUPS=()
	GIT_PROJECTS=()

	while IFS=, read -r tag val1 val2; do
		case "$tag" in
		"C") setConfVariable "$val1" "$val2";;
		"CA") setConfArray "$val1" "$val2";;
		"P") PACKAGES+=("$val1");;
		"S") SERVICES+=("$val1");;
		"A") AUR_PACKAGES+=("$val1");;
		"UG") USERGROUPS+=("$val1");;
		"G") GIT_PROJECTS+=("$val1|$val2");;
		esac
	done < "$CONF_FILE"
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
	mv /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.dist
	rankmirrors -n "$RANKMIRRORS_TOP" /etc/pacman.d/mirrorlist.dist | \
		tee /etc/pacman.d/mirrorlist
}

setRootUserEnvironment() {
	isTestRun || setPassword root
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

	# set no passwd only in TESTRUN mode. Otherwise we cant put our skript
	# to ci tools.

	isTestRun && sed -i -e 's|^#\s*\(%wheel ALL=(ALL) NOPASSWD: ALL\)$|\1|' /etc/sudoers

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
	useradd -g "$USER_GROUP" -G "$USER_GROUPS_EXTRA" -s /bin/bash \
		-c "$USER_REALNAME" -m "$USER_NAME"

	if [ "$USER_SET_PASSWORD" == "yes" ] && ! isTestRun; then
		setPassword "$USER_NAME"
	else
		passwd -l "$USER_NAME"
	fi

	if [ -n "$USER_LOCALE" ] && [ -n "$USER_LOCALE_LANG" ]; then
		setLocaleLangAsUser "$USER_NAME" "$USER_LOCALE_LANG"
	fi
}

installAurPackages () {
	local PACKAGES=("$@")
	[ ${#PACKAGES[@]} -gt 0 ] || return

	installYaourt "$USER_NAME"

	installYaourtPackages "$USER_NAME" "${PACKAGES[@]}"
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
	[ "$CUSTOMIZE" == "yes" ] || return
	[ -z "$CUSTOMIZE_GIT_URL" ] && errorExit "Empty customize git URL"
	[ -n "$CUSTOMIZE_TARGET_DIR" ] && \
		cloneGitRepoAsUser "$USER_NAME" "$CUSTOMIZE_GIT_URL" "$CUSTOMIZE_TARGET_DIR"

	if [ -n "$CUSTOMIZE_RUN_SCRIPT" ]; then
		pushd "$CUSTOMIZE_TARGET_DIR" || \
			errorExit "Change directory to '%s' failed" "$CUSTOMIZE_TARGET_DIR"
		# shellcheck disable=SC1090 # source file will be set from configuration file
		source "$CUSTOMIZE_RUN_SCRIPT" || errorExit "Customizing script failed"
		popd || errorExit "Change back directory failed"
	fi
}

addUserGroups() {
	local GROUPS=("$@")
	[ ${#GROUPS[@]} -gt 0 ] || return

	isUserExists "$USER_NAME"

	for GROUP in "${GROUPS[@]}"; do
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
		execAsUser "$USER_NAME" git clone "$GIT_URL" ${GIT_NAME:+"$GIT_NAME"} || \
			warnOnTestOrErrorExit "Clone git repository '%s' failed" "$GIT_URL"
	done
	popd || errorExit "Change back directory failed"
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
		TESTRUN=true
		# in case of a testrun we also want to get some
		# debug information
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

		enableServices "${SERVICES[@]}"

		addUserGroups "${USERGROUPS[@]}"

		cloneGitProjects "${GIT_PROJECTS[@]}"

		exit 0
		;;
	*)
		errorExit "Unknown target ('%s')" "$INSTALL_TARGET"
		;;
esac

#vim syntax=bash
