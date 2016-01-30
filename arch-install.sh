#!/usr/bin/env bash

SCRIPT_HOME=$( cd "`dirname "${BASH_SOURCE[0]}"`" && pwd )
SCRIPT_FILENAME="`basename "${BASH_SOURCE[0]}"`"
SCRIPT_NAME="`printf "$SCRIPT_FILENAME" | awk -F '.' '{ print $1 }'`"

doPrintPrompt() {
	printf "[$SCRIPT_NAME] $*"
}

doPrint() {
	doPrintPrompt "$*\n"
}

doPrintHelpMessage() {
	printf "Usage: ./$SCRIPT_FILENAME [-h] [-c config] [target [options...]]\n"
}

while getopts :hc: opt; do
	case "$opt" in
		h)
			doPrintHelpMessage
			exit 0
			;;

		c)
			SCRIPT_CONFIG="$OPTARG"
			;;

		:)
			printf "ERROR: "
			case "$OPTARG" in
				c)
					printf "Missing config file"
					;;
			esac
			printf "\n"
			exit 1
			;;

		\?)
			printf "ERROR: Invalid option ('-$OPTARG')\n"
			exit 1
			;;
	esac
done
shift $((OPTIND - 1))

INSTALL_TARGET="$1"
shift
INSTALL_OPTIONS="$*"

if [ -z "$SCRIPT_CONFIG" ]; then
	SCRIPT_CONFIG="$SCRIPT_HOME/$SCRIPT_NAME.conf"
fi

if [ ! -f "$SCRIPT_CONFIG" ]; then
	printf "ERROR: Config file not found ('$SCRIPT_CONFIG')\n"
	exit 1
fi

if [ -z "$INSTALL_TARGET" ]; then
	INSTALL_TARGET="base"
fi

source "$SCRIPT_CONFIG"

# =================================================================================
#    F U N C T I O N S
# =================================================================================

doCopyToChroot() {
	local CHROOT_SCRIPT_HOME="/mnt/root/`basename "$SCRIPT_HOME"`"
	if [ ! -d "$CHROOT_SCRIPT_HOME" ]; then
		mkdir -p "$CHROOT_SCRIPT_HOME"

		cp -p "${BASH_SOURCE[0]}" "$CHROOT_SCRIPT_HOME"
		cp -p "$SCRIPT_CONFIG" "$CHROOT_SCRIPT_HOME"
	fi
}

doChroot() {
	local IN_CHROOT_SCRIPT_HOME="/root/`basename "$SCRIPT_HOME"`"
	local IN_CHROOT_SCRIPT_CONFIG="$IN_CHROOT_SCRIPT_HOME/`basename "$SCRIPT_CONFIG"`"

	arch-chroot /mnt /usr/bin/bash -c "'$IN_CHROOT_SCRIPT_HOME/$SCRIPT_FILENAME' -c '$IN_CHROOT_SCRIPT_CONFIG' $*"
}

doRemoveFromChroot() {
	local CHROOT_SCRIPT_HOME="/mnt/root/`basename "$SCRIPT_HOME"`"
	if [ -d "$CHROOT_SCRIPT_HOME" ]; then
		rm -r "$CHROOT_SCRIPT_HOME"
	fi
}

doCopyToSu() {
	local SU_USER="$1"

	local SU_USER_HOME="`eval printf "~$SU_USER"`"
	local SU_SCRIPT_HOME="$SU_USER_HOME/`basename "$SCRIPT_HOME"`"
	if [ ! -d "$SU_SCRIPT_HOME" ]; then
		mkdir -p "$SU_SCRIPT_HOME"

		cp -p "${BASH_SOURCE[0]}" "$SU_SCRIPT_HOME"
		cp -p "$SCRIPT_CONFIG" "$SU_SCRIPT_HOME"

		local SU_USER_GROUP="`id -gn "$SU_USER"`"
		chown -R "$SU_USER:$SU_USER_GROUP" "$SU_SCRIPT_HOME"
	fi
}

doSu() {
	local SU_USER="$1"

	local SU_USER_HOME="`eval printf "~$SU_USER"`"
	local IN_SU_SCRIPT_HOME="$SU_USER_HOME/`basename "$SCRIPT_HOME"`"
	local IN_SU_SCRIPT_CONFIG="$IN_SU_SCRIPT_HOME/`basename "$SCRIPT_CONFIG"`"

	shift
	/bin/su "$SU_USER" -c "'$IN_SU_SCRIPT_HOME/$SCRIPT_FILENAME' -c '$IN_SU_SCRIPT_CONFIG' $*"
}

doSuSudo() {
	local SU_USER="$1"

	local SU_USER_SUDO_NOPASSWD="/etc/sudoers.d/$SU_USER"

	cat > "$SU_USER_SUDO_NOPASSWD" << __END__
$SU_USER ALL=(ALL) NOPASSWD: ALL
__END__

	doSu $*

	rm "$SU_USER_SUDO_NOPASSWD"
}

doRemoveFromSu() {
	local SU_USER="$1"

	local SU_USER_HOME="`eval printf "~$SU_USER"`"
	local SU_SCRIPT_HOME="$SU_USER_HOME/`basename "$SCRIPT_HOME"`"
	if [ -d "$SU_SCRIPT_HOME" ]; then
		rm -r "$SU_SCRIPT_HOME"
	fi
}

doConfirmInstall() {
	doPrint "Installing to '$INSTALL_DEVICE' - ALL DATA ON IT WILL BE LOST!"
	doPrint "Enter 'YES' (in capitals) to confirm and start the installation."

	doPrintPrompt "> "
	read i
	if [ "$i" != "YES" ]; then
		doPrint "Aborted."
		exit 0
	fi

	for i in {10..1}; do
		doPrint "Starting in $i - Press CTRL-C to abort..."
		sleep 1
	done
}

doDeactivateAllSwaps() {
	swapoff -a
}

getAllPartitions() {
	lsblk -l -n -o NAME "$INSTALL_DEVICE" | grep -v "^$INSTALL_DEVICE_NAME$"
}

doFlush() {
	sync
	sync
	sync
}

doWipeAllPartitions() {
	for i in $( getAllPartitions | sort -r ); do
		umount "$INSTALL_DEVICE_HOME/$i"
		dd if=/dev/zero of="$INSTALL_DEVICE_HOME/$i" bs=1M count=1
	done

	doFlush
}

doPartProbe() {
	partprobe "$INSTALL_DEVICE"
}

doWipeDevice() {
	dd if=/dev/zero of="$INSTALL_DEVICE" bs=1M count=1

	doFlush
	doPartProbe
}

doCreateNewPartitionTable() {
	parted -s -a optimal "$INSTALL_DEVICE" mklabel "$1"
}

doCreateNewPartitions() {
	local START="1"; local END="$BOOT_SIZE"
	case "$BOOT_FILESYSTEM" in
		fat32)
			parted -s -a optimal "$INSTALL_DEVICE" mkpart primary "$BOOT_FILESYSTEM" "${START}MiB" "${END}MiB"
			;;

		*)
			parted -s -a optimal "$INSTALL_DEVICE" mkpart primary "${START}MiB" "${END}MiB"
			;;
	esac

	START="$END"; let END+=SWAP_SIZE
	parted -s -a optimal "$INSTALL_DEVICE" mkpart primary linux-swap "${START}MiB" "${END}MiB"

	START="$END"; END="100%"
	parted -s -a optimal "$INSTALL_DEVICE" mkpart primary "${START}MiB" "${END}MiB"

	parted -s -a optimal "$INSTALL_DEVICE" set 1 boot on

	doFlush
	doPartProbe
}

doDetectDevices() {
	local ALL_PARTITIONS=($( getAllPartitions ))

	BOOT_DEVICE="$INSTALL_DEVICE_HOME/${ALL_PARTITIONS[0]}"
	SWAP_DEVICE="$INSTALL_DEVICE_HOME/${ALL_PARTITIONS[1]}"
	ROOT_DEVICE="$INSTALL_DEVICE_HOME/${ALL_PARTITIONS[2]}"
}

doCreateNewPartitionsLuks() {
	local START="1"; local END="$BOOT_SIZE"
	case "$BOOT_FILESYSTEM" in
		fat32)
			parted -s -a optimal "$INSTALL_DEVICE" mkpart primary "$BOOT_FILESYSTEM" "${START}MiB" "${END}MiB"
			;;

		*)
			parted -s -a optimal "$INSTALL_DEVICE" mkpart primary "${START}MiB" "${END}MiB"
			;;
	esac

	START="$END"; END="100%"
	parted -s -a optimal "$INSTALL_DEVICE" mkpart primary "${START}MiB" "${END}MiB"

	parted -s -a optimal "$INSTALL_DEVICE" set 1 boot on
	parted -s -a optimal "$INSTALL_DEVICE" set 2 lvm on

	doFlush
	doPartProbe
}

doDetectDevicesLuks() {
	local ALL_PARTITIONS=($( getAllPartitions ))

	BOOT_DEVICE="$INSTALL_DEVICE_HOME/${ALL_PARTITIONS[0]}"
	LUKS_DEVICE="$INSTALL_DEVICE_HOME/${ALL_PARTITIONS[1]}"
}

doCreateLuks() {
	doPrint "Formatting LUKS device"
	cryptsetup -q -y -c aes-xts-plain64 -s 512 -h sha512 luksFormat "$LUKS_DEVICE"

	local SSD_DISCARD=""
	if [ "$INSTALL_DEVICE_IS_SSD" == "yes" ] && [ "$INSTALL_DEVICE_SSD_DISCARD" == "yes" ]; then
		SSD_DISCARD=" --allow-discards"
	fi

	doPrint "Opening LUKS device"
	cryptsetup$SSD_DISCARD luksOpen "$LUKS_DEVICE" "$LUKS_NAME"
}

doCreateLuksLvm() {
	local LUKS_LVM_DEVICE="$LVM_DEVICE_HOME/$LUKS_NAME"

	pvcreate "$LUKS_LVM_DEVICE"
	vgcreate "$LUKS_LVM_NAME" "$LUKS_LVM_DEVICE"
	lvcreate -L "${SWAP_SIZE}M" -n "$SWAP_LABEL" "$LUKS_LVM_NAME"
	lvcreate -l 100%FREE -n "$ROOT_LABEL" "$LUKS_LVM_NAME"
}

doDetectDevicesLuksLvm() {
	SWAP_DEVICE="$LVM_DEVICE_HOME/$LUKS_LVM_NAME-$SWAP_LABEL"
	ROOT_DEVICE="$LVM_DEVICE_HOME/$LUKS_LVM_NAME-$ROOT_LABEL"
}

doMkfs() {
	case "$1" in
		fat32)
			mkfs -t fat -F 32 -n "$2" "$3"
			;;

		*)
			mkfs -t "$1" -L "$2" "$3"
			;;
	esac
}

doFormat() {
	doMkfs "$BOOT_FILESYSTEM" "$BOOT_LABEL" "$BOOT_DEVICE"
	mkswap -L "$SWAP_LABEL" "$SWAP_DEVICE"
	doMkfs "$ROOT_FILESYSTEM" "$ROOT_LABEL" "$ROOT_DEVICE"
}

doMount() {
	local SSD_DISCARD=""
	if [ "$INSTALL_DEVICE_IS_SSD" == "yes" ] && [ "$INSTALL_DEVICE_SSD_DISCARD" == "yes" ]; then
		SSD_DISCARD=" -o discard"
	fi

	mount$SSD_DISCARD "$ROOT_DEVICE" /mnt
	mkdir /mnt/boot
	mount$SSD_DISCARD "$BOOT_DEVICE" /mnt/boot

	SSD_DISCARD=""
	if [ "$INSTALL_DEVICE_IS_SSD" == "yes" ] && [ "$INSTALL_DEVICE_SSD_DISCARD" == "yes" ]; then
		SSD_DISCARD=" --discard"
	fi

	swapon$SSD_DISCARD "$SWAP_DEVICE"
}

doPacstrap() {
	pacstrap /mnt base

	doFlush
}

doGenerateFstab() {
	genfstab -p -U /mnt >> /mnt/etc/fstab

	if [ "$INSTALL_DEVICE_IS_SSD" == "yes" ] && [ "$INSTALL_DEVICE_SSD_DISCARD" == "yes" ]; then
		cat /mnt/etc/fstab | sed -e 's/\(data=ordered\)/\1,discard/' > /tmp/fstab
		cat /tmp/fstab > /mnt/etc/fstab
		rm /tmp/fstab

		cat /mnt/etc/fstab | sed -e 's/\(swap\s*defaults\)/\1,discard/' > /tmp/fstab
		cat /tmp/fstab > /mnt/etc/fstab
		rm /tmp/fstab
	fi
}

doOptimizeFstabNoatime() {
	cat /mnt/etc/fstab | sed -e 's/relatime/noatime/' > /tmp/fstab
	cat /tmp/fstab > /mnt/etc/fstab
	rm /tmp/fstab
}

doSetHostname() {
	cat > /etc/hostname << __END__
$1
__END__
}

doSetTimezone() {
	ln -sf "/usr/share/zoneinfo/$1" /etc/localtime
}

doEnableLocale() {
	cat /etc/locale.gen | sed -e 's/^#\('"$1"'\)\s*$/\1/' > /tmp/locale.gen
	cat /tmp/locale.gen > /etc/locale.gen
	rm /tmp/locale.gen
}

doEnableLocales() {
	for i in "$@"; do
		doEnableLocale "$i"
	done
}

doGenerateLocales() {
	locale-gen
}

doSetLocaleLang() {
	cat > /etc/locale.conf << __END__
LANG=$1
__END__
}

doSetConsole() {
	cat > /etc/vconsole.conf << __END__
KEYMAP=$1
FONT=$2
__END__
}

doEnableServiceDhcpcd() {
	systemctl enable dhcpcd.service
}

doDisableIpv6() {
	cat > /etc/sysctl.d/40-ipv6.conf << __END__
ipv6.disable_ipv6=1
__END__
}

doInstallWirelessUtils() {
	pacman -S --noconfirm --needed \
		crda \
		dialog \
		iw \
		libnl \
		wireless-regdb \
		wpa_supplicant
}

doEditMkinitcpioLuks() {
	# default: HOOKS="base udev autodetect modconf block filesystems keyboard fsck"
	cat /etc/mkinitcpio.conf | sed -e 's/^\(\(HOOKS=\)\(.*\)\)$/#\1\n\2\3/' > /tmp/mkinitcpio.conf
	cat /tmp/mkinitcpio.conf | awk 'm = $0 ~ /^HOOKS=/ {
			gsub(/keyboard/, "", $0);
			gsub(/filesystems/, "keyboard keymap encrypt lvm2 filesystems", $0);
			gsub(/  /, " ", $0);
			print
		} !m { print }' > /etc/mkinitcpio.conf
	rm /tmp/mkinitcpio.conf
}

doOptimizeMkinitcpioHookBefore() {
	# default: HOOKS="base udev autodetect modconf block filesystems keyboard fsck"
	cat /etc/mkinitcpio.conf | sed -e 's/^\(\(HOOKS=\)\(.*\)\)$/#\1\n\2\3/' > /tmp/mkinitcpio.conf
	cat /tmp/mkinitcpio.conf | awk 'm = $0 ~ /^HOOKS=/ {
			gsub(/'"$1"'/, "", $0);
			gsub(/'"$2"'/, "'"$1"' '"$2"'", $0);
			gsub(/  /, " ", $0);
			print
		} !m { print }' > /etc/mkinitcpio.conf
	rm /tmp/mkinitcpio.conf
}

doMkinitcpio() {
	mkinitcpio -p linux
}

doSetRootPassword() {
	doPrint "Setting password for user 'root'"
	passwd root
}

doBashLogoutClear() {
	cat >> ~/.bash_logout << __END__
clear
__END__
}

doRankmirrors() {
	mv /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.dist
	rankmirrors -n "$RANKMIRRORS_TOP" /etc/pacman.d/mirrorlist.dist | tee /etc/pacman.d/mirrorlist
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
	pacman -S --noconfirm --needed grub

	grub-install --target=i386-pc --recheck "$INSTALL_DEVICE"
}

doDetectRootUuid() {
	ROOT_UUID="`blkid -o value -s UUID "$ROOT_DEVICE"`"
}

doEditGrubConfig() {
	cat /etc/default/grub | sed -e 's/^\(\(GRUB_CMDLINE_LINUX_DEFAULT=\)\(.*\)\)$/#\1\n\2\3/' > /tmp/default-grub
	cat /tmp/default-grub | awk 'm = $0 ~ /^GRUB_CMDLINE_LINUX_DEFAULT=/ {
			gsub(/quiet/, "quiet root=UUID='"$ROOT_UUID"''"$IO_SCHEDULER_KERNEL"''"$FSCK_MODE"'", $0);
			print
		} !m { print }' > /etc/default/grub
	rm /tmp/default-grub
}

doDetectLuksUuid() {
	LUKS_UUID="`cryptsetup luksUUID "$LUKS_DEVICE"`"
}

doEditGrubConfigLuks() {
	local SSD_DISCARD
	if [ "$INSTALL_DEVICE_IS_SSD" == "yes" ] && [ "$INSTALL_DEVICE_SSD_DISCARD" == "yes" ]; then
		SSD_DISCARD=":allow-discards"
	fi

	cat /etc/default/grub | sed -e 's/^\(\(GRUB_CMDLINE_LINUX_DEFAULT=\)\(.*\)\)$/#\1\n\2\3/' > /tmp/default-grub
	cat /tmp/default-grub | awk 'm = $0 ~ /^GRUB_CMDLINE_LINUX_DEFAULT=/ {
			gsub(/quiet/, "quiet cryptdevice=UUID='"$LUKS_UUID"':'"$LUKS_LVM_NAME"''"$SSD_DISCARD"' root=UUID='"$ROOT_UUID"' lang='"$CONSOLE_KEYMAP"' locale='"$LOCALE_LANG"''"$IO_SCHEDULER_KERNEL"''"$FSCK_MODE"'", $0);
			print
		} !m { print }' > /etc/default/grub
	rm /tmp/default-grub
}

doGenerateGrubConfig() {
	grub-mkconfig -o /boot/grub/grub.cfg
}

doInstallGrubEfi() {
	pacman -S --noconfirm --needed \
		dosfstools \
		efibootmgr \
		grub

	grub-install --target=x86_64-efi --efi-directory=/boot --recheck
}

doCreateEfiStartupNsh() {
	cat > /boot/startup.nsh << __END__
$EFI_STARTUP_NSH
__END__
}

doInstallGummiboot() {
	pacman -S --noconfirm --needed \
		dosfstools \
		efibootmgr

	bootctl --path=/boot install
}

doCreateGummibootEntry() {
	cat > /boot/loader/entries/default.conf << __END__
title Arch Linux
linux /vmlinuz-linux
initrd /initramfs-linux.img
options quiet root=UUID=$ROOT_UUID rw$IO_SCHEDULER_KERNEL$FSCK_MODE
__END__
}

doCreateGummibootConfig() {
	cat > /boot/loader/loader.conf << __END__
default default
timeout 5
__END__
}

doCreateGummibootEntryLuks() {
	local SSD_DISCARD=""
	if [ "$INSTALL_DEVICE_IS_SSD" == "yes" ] && [ "$INSTALL_DEVICE_SSD_DISCARD" == "yes" ]; then
		SSD_DISCARD=":allow-discards"
	fi

	cat > /boot/loader/entries/default.conf << __END__
title Arch Linux
linux /vmlinuz-linux
initrd /initramfs-linux.img
options quiet cryptdevice=UUID=$LUKS_UUID:$LUKS_LVM_NAME$SSD_DISCARD root=UUID=$ROOT_UUID rw lang=$CONSOLE_KEYMAP locale=$LOCALE_LANG$IO_SCHEDULER_KERNEL$FSCK_MODE
__END__
}

doCreateCrypttabLuks() {
	local SSD_DISCARD=""
	if [ "$INSTALL_DEVICE_IS_SSD" == "yes" ] && [ "$INSTALL_DEVICE_SSD_DISCARD" == "yes" ]; then
		SSD_DISCARD=",discard"
	fi

	cat > /etc/crypttab << __END__
$LUKS_LVM_NAME UUID=$LUKS_UUID none luks$SSD_DISCARD
__END__
}

doAddHostUser() {
	groupadd "$HOST_USER_GROUP"

	useradd -g "$HOST_USER_GROUP" -G "$HOST_USER_GROUPS_EXTRA" -d "/$HOST_USER_USERNAME" -s /bin/bash -c "$HOST_USER_REALNAME" -m "$HOST_USER_USERNAME"
	HOST_USER_HOME="`eval printf "~$HOST_USER_USERNAME"`"
	chmod 0751 "$HOST_USER_HOME"

	doPrint "Setting password for host user '$HOST_USER_USERNAME'"
	if [ "$HOST_USER_SET_PASSWORD" == "yes" ]; then
		passwd "$HOST_USER_USERNAME"
	else
		passwd -l "$HOST_USER_USERNAME"
	fi
}

doSuBashLogoutClear() {
	doSu "$1" suBashLogoutClear
}

doUserSetLocaleLang() {
	mkdir -p ~/.config

	cat > ~/.config/locale.conf << __END__
LANG=$1
__END__
}

doSuUserSetLocaleLang() {
	doSu "$1" suUserSetLocaleLang "$2"
}

doAddMainUser() {
	useradd -g "$MAIN_USER_GROUP" -G "$MAIN_USER_GROUPS_EXTRA" -s /bin/bash -c "$MAIN_USER_REALNAME" -m "$MAIN_USER_USERNAME"
	MAIN_USER_HOME="`eval printf "~$MAIN_USER_USERNAME"`"
	chmod 0751 "$MAIN_USER_HOME"

	doPrint "Setting password for main user '$MAIN_USER_USERNAME'"
	if [ "$MAIN_USER_SET_PASSWORD" == "yes" ]; then
		passwd "$MAIN_USER_USERNAME"
	else
		passwd -l "$MAIN_USER_USERNAME"
	fi
}

doInstallScreen() {
	pacman -S --noconfirm --needed screen

	doSetConf "/etc/screenrc" "startup_message " "off"
}

doUserCreateScreenrc() {
cat > ~/.screenrc << __END__
caption always " %-Lw%{= dd}%n%f* %t%{-}%+Lw"
__END__
}

doSuUserCreateScreenrc() {
	doSu "$1" suUserCreateScreenrc
}

doInstallSsh() {
	pacman -S --noconfirm --needed openssh
}

doEnableServiceSsh() {
	systemctl enable sshd.service
}

doSshAcceptKeyTypeSshDss() {
	cat >> /etc/ssh/ssh_config << __END__
Host *
  PubkeyAcceptedKeyTypes=+ssh-dss
__END__

	cat >> /etc/ssh/sshd_config << __END__
PubkeyAcceptedKeyTypes=+ssh-dss
__END__
}

doInstallSudo() {
	pacman -S --noconfirm --needed sudo

	cat /etc/sudoers | sed -e 's/^#\s*\(%wheel ALL=(ALL) ALL\)$/\1/' > /tmp/sudoers
	cat /tmp/sudoers > /etc/sudoers
	rm /tmp/sudoers
}

doEnableMultilib() {
	cat /etc/pacman.conf | sed -e '/^#\[multilib\]$/ {
			N; /\n#Include/ {
				s/^#//
				s/\n#/\n/
			}
		}' > /tmp/pacman.conf
	cat /tmp/pacman.conf > /etc/pacman.conf
	rm /tmp/pacman.conf

	pacman -Syu --noconfirm --needed
}

doInstallDevel() {
	pacman -S --noconfirm --needed base-devel

	if [ "$ENABLE_MULTILIB" == "yes" ]; then
		yes | pacman -S --needed $(pacman -Sqg multilib-devel)
	fi
}

doCreateSoftwareDirectory() {
	mkdir -p ~/software/aaa.dist
	chmod 0700 ~/software
	chmod 0700 ~/software/aaa.dist
}

doInstallYaourt() {
	doCreateSoftwareDirectory
	cd ~/software/aaa.dist

	curl --retry 999 --retry-delay 0 --retry-max-time 300 --speed-time 10 --speed-limit 0 \
		-LO https://aur.archlinux.org/cgit/aur.git/snapshot/package-query.tar.gz
	tar xvf package-query.tar.gz
	cd package-query
	makepkg -i -s --noconfirm --needed
	cd ..

	curl --retry 999 --retry-delay 0 --retry-max-time 300 --speed-time 10 --speed-limit 0 \
		-LO https://aur.archlinux.org/cgit/aur.git/snapshot/yaourt.tar.gz
	tar xvf yaourt.tar.gz
	cd yaourt
	makepkg -i -s --noconfirm --needed
	cd ..

	cd ../..
}

doSuInstallYaourt() {
	doSuSudo "$YAOURT_USER_USERNAME" suInstallYaourt
}

doYaourt() {
	yaourt -S --noconfirm --needed $*
}

doSuYaourt() {
	doSuSudo "$YAOURT_USER_USERNAME" suYaourt $*
}

doInstallX11() {
	pacman -S --noconfirm --needed \
		xorg-server \
		xorg-server-utils \
		xorg-utils \
		xorg-xinit \
		xorg-fonts-75dpi \
		xorg-fonts-100dpi \
		xorg-twm \
		xorg-xclock \
		xterm \
		$X11_PACKAGES_VIDEO \
		$X11_PACKAGES_EXTRA
}

doX11KeyboardConf() {
	cat > /etc/X11/xorg.conf.d/00-keyboard.conf << __END__
Section "InputClass"
        Identifier "system-keyboard"
        MatchIsKeyboard "on"
        Option "XkbLayout" "$1"
        Option "XkbModel" "$2"
        Option "XkbVariant" "$3"
        Option "XkbOptions" "$4"
EndSection
__END__
}

doX11InstallFonts() {
	pacman -S --noconfirm --needed \
		noto-fonts \
		ttf-dejavu \
		ttf-droid \
		ttf-liberation \
		ttf-symbola

	doSuYaourt ttf-ms-fonts
}

doX11InstallXfce() {
	pacman -S --noconfirm --needed \
		xfce4 \
		xfce4-goodies

	doSuYaourt xfce4-places-plugin
}

doX11InstallUbuntuFontRendering() {
	# 2x
	pacman -Rdd --noconfirm cairo
	doSuYaourt cairo-ubuntu
	pacman -Rdd --noconfirm cairo
	doSuYaourt cairo-ubuntu

	pacman -Rdd --noconfirm freetype2
	doSuYaourt freetype2-ubuntu

	pacman -Rdd --noconfirm fontconfig
	doSuYaourt fontconfig-ubuntu
}

doUpdateIconCache() {
	for i in $( find /usr/share/icons/* -maxdepth 0 -type d ); do
		gtk-update-icon-cache "$i"
	done
}

doX11InstallThemes() {
	pacman -S --noconfirm --needed gtk-engine-murrine

	doSuYaourt \
		numix-themes-git \
		gtk-theme-config \
		elementary-xfce-icons-git

	doUpdateIconCache
}

doSetConf() {
	cat "$1" | sed -e 's/^#\?\(\('"$2"'\)\(.*\)\)$/#\1\n\2'"$3"'/' > "/tmp/`basename "$1"`"
	cat "/tmp/`basename "$1"`" > "$1"
	rm "/tmp/`basename "$1"`"
}

doX11InstallLightdm() {
	pacman -S --noconfirm --needed \
		lightdm \
		lightdm-gtk-greeter

	if [ "$X11_INSTALL_THEMES" == "yes" ]; then
		doSetConf "/etc/lightdm/lightdm-gtk-greeter.conf" "theme-name=" "Numix"
		doSetConf "/etc/lightdm/lightdm-gtk-greeter.conf" "font-name=" "Droid Sans 9"
		doSetConf "/etc/lightdm/lightdm-gtk-greeter.conf" "xft-antialias=" "true"
		doSetConf "/etc/lightdm/lightdm-gtk-greeter.conf" "xft-dpi=" "96"
		doSetConf "/etc/lightdm/lightdm-gtk-greeter.conf" "xft-hintstyle=" "slight"
		doSetConf "/etc/lightdm/lightdm-gtk-greeter.conf" "xft-rgba=" "rgb"
		doSetConf "/etc/lightdm/lightdm-gtk-greeter.conf" "indicators=" "~host;~spacer;~clock;~spacer;~language;~power"
		doSetConf "/etc/lightdm/lightdm-gtk-greeter.conf" "clock-format=" "%a, %d %b %H:%M:%S"
	fi
}

doEnableServiceLightdm() {
	systemctl enable lightdm.service
}

doX11InstallTeamviewer() {
	doSuYaourt teamviewer
}

doEnableServiceTeamviewer() {
	systemctl enable teamviewerd
}

doInstallNetworkManager() {
	pacman -S --noconfirm --needed \
		networkmanager \
		networkmanager-vpnc \
		modemmanager

	if [ "$INSTALL_X11" == "yes" ]; then
		pacman -S --noconfirm --needed network-manager-applet
	fi
}

doEnableServiceNetworkManager() {
	systemctl enable NetworkManager.service
}

doInstallCron() {
	pacman -S --noconfirm --needed cronie
}

doEnableServiceCron() {
	systemctl enable cronie
}

doInstallAt() {
	pacman -S --noconfirm --needed at
}

doEnableServiceAt() {
	systemctl enable atd.service
}

doInstallCups() {
	pacman -S --noconfirm --needed \
		cups \
		libcups \
		ghostscript \
		gsfonts

	if [ "$INSTALL_X11" == "yes" ]; then
		pacman -S --noconfirm --needed system-config-printer
	fi
}

doEnableServiceCups() {
	systemctl enable org.cups.cupsd
}

doInstallTlp() {
	pacman -S --noconfirm --needed tlp
}

doEnableServiceTlp() {
	systemctl enable tlp.service
	systemctl enable tlp-sleep.service
}

doInstallPulseaudio() {
	pacman -S --noconfirm --needed \
		pulseaudio \
		pulseaudio-alsa

	if [ "$INSTALL_X11" == "yes" ]; then
		pacman -S --noconfirm --needed \
			paprefs \
			pavucontrol

		doSuYaourt pulseaudio-ctl
	fi
}

doInstallVirtualboxGuest() {
	pacman -S --noconfirm --needed \
		virtualbox-guest-modules \
		virtualbox-guest-utils
}

doEnableModulesVirtualboxGuest() {
	cat > /etc/modules-load.d/virtualbox-guest.conf << __END__
vboxguest
vboxsf
vboxvideo
__END__
}

doInstallVirtualboxHost() {
	pacman -S --noconfirm --needed \
		virtualbox \
		virtualbox-host-modules \
		virtualbox-guest-iso

	if [ "$ADD_HOST_USER" == "yes" ] && [ "$VIRTUALBOX_VBOXUSERS_ADD_HOST_USER" == "yes" ]; then
		gpasswd -a "$HOST_USER_USERNAME" vboxusers
	fi

	if [ "$ADD_MAIN_USER" == "yes" ] && [ "$VIRTUALBOX_VBOXUSERS_ADD_MAIN_USER" == "yes" ]; then
		gpasswd -a "$MAIN_USER_USERNAME" vboxusers
	fi
}

doEnableModulesVirtualboxHost() {
	cat > /etc/modules-load.d/virtualbox-host.conf << __END__
vboxdrv
vboxnetadp
vboxnetflt
vboxpci
__END__
}

doDisablePcSpeaker() {
	cat >> /etc/modprobe.d/blacklist.conf << __END__
blacklist pcspkr
__END__
}

doSymlinkHashCommands() {
	ln -s /usr/bin/md5sum /usr/local/bin/md5
	ln -s /usr/bin/sha1sum /usr/local/bin/sha1
}

doOptimizeSwappiness() {
	cat > /etc/sysctl.d/99-sysctl.conf << __END__
vm.swappiness=$OPTIMIZE_SWAPPINESS_VALUE
__END__
}

doOptimizeIoSchedulerUdev() {
	cat > /etc/udev/rules.d/60-schedulers.rules << __END__
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="$OPTIMIZE_IO_SCHEDULER_UDEV_ROTATIONAL", ATTR{queue/scheduler}="$OPTIMIZE_IO_SCHEDULER_UDEV_VALUE"
__END__
}

doInstallPackageSets() {
	for i in $INSTALL_PACKAGE_SETS; do
		j="$i":pacmanBefore
		if [ ! -z "${PACKAGE_SET[$j]}" ]; then
			${PACKAGE_SET[$j]}
		fi

			j="$i":pacman
			if [ ! -z "${PACKAGE_SET[$j]}" ]; then
				pacman -S --noconfirm --needed ${PACKAGE_SET[$j]}
			fi

		j="$i":pacmanAfter
		if [ ! -z "${PACKAGE_SET[$j]}" ]; then
			${PACKAGE_SET[$j]}
		fi

		j="$i":yaourtBefore
		if [ ! -z "${PACKAGE_SET[$j]}" ]; then
			${PACKAGE_SET[$j]}
		fi

			j="$i":yaourt
			if [ ! -z "${PACKAGE_SET[$j]}" ]; then
				doSuYaourt ${PACKAGE_SET[$j]}
			fi

		j="$i":yaourtAfter
		if [ ! -z "${PACKAGE_SET[$j]}" ]; then
			${PACKAGE_SET[$j]}
		fi
	done
}

doUnmount() {
	umount "$BOOT_DEVICE"
	umount "$ROOT_DEVICE"
	swapoff "$SWAP_DEVICE"
}

# =================================================================================
#    M A I N
# =================================================================================

case "$INSTALL_TARGET" in
	base)
		doConfirmInstall

		doDeactivateAllSwaps
		doWipeAllPartitions
		doWipeDevice

		doCreateNewPartitionTable "$PARTITION_TABLE_TYPE"

		if [ "$LVM_ON_LUKS" == "yes" ]; then
			doCreateNewPartitionsLuks
			doDetectDevicesLuks
			doCreateLuks
			doCreateLuksLvm
			doDetectDevicesLuksLvm
		else
			doCreateNewPartitions
			doDetectDevices
		fi

		doFormat
		doMount

		doPacstrap

		doGenerateFstab

		[ "$OPTIMIZE_FSTAB_NOATIME" == "yes" ] && doOptimizeFstabNoatime

		doCopyToChroot
		doChroot chroot
		[ "$INSTALL_REMOVE_FROM_CHROOT" == "yes" ] && doRemoveFromChroot

		doPrint "Flushing - this might take a while..."
		doFlush

		doUnmount

		doPrint "Wake up, Neo... The installation is done!"

		exit 0
		;;

	chroot)
		doSetHostname "$HOSTNAME"
		doSetTimezone "$TIMEZONE"

		doEnableLocales "${GENERATE_LOCALES[@]}"
		doGenerateLocales
		doSetLocaleLang "$LOCALE_LANG"

		doSetConsole "$CONSOLE_KEYMAP" "$CONSOLE_FONT"

		[ "$ENABLE_SERVICE_DHCPCD" == "yes" ] && doEnableServiceDhcpcd

		[ "$DISABLE_IPV6" == "yes" ] && doDisableIpv6

		[ "$INSTALL_WIRELESS_UTILS" == "yes" ] && doInstallWirelessUtils

		[ "$LVM_ON_LUKS" == "yes" ] && doEditMkinitcpioLuks

		[ "$OPTIMIZE_MKINITCPIO_HOOK_KEYBOARD_BEFORE_AUTODETECT" == "yes" ] && \
			doOptimizeMkinitcpioHookBefore "keyboard" "autodetect"

		[ "$OPTIMIZE_MKINITCPIO_HOOK_BLOCK_BEFORE_AUTODETECT" == "yes" ] && \
			doOptimizeMkinitcpioHookBefore "block" "autodetect"

		doMkinitcpio

		doSetRootPassword

		[ "$ROOT_USER_BASH_LOGOUT_CLEAR" == "yes" ] && doBashLogoutClear

		[ "$RANKMIRRORS" == "yes" ] && doRankmirrors

		doSetOptimizeIoSchedulerKernel
		doSetOptimizeFsckMode

		case "$BOOT_METHOD" in
			legacy)
				doInstallGrub

				if [ "$LVM_ON_LUKS" = "yes" ]; then
					doDetectDevicesLuks
					doDetectDevicesLuksLvm
					doDetectLuksUuid
					doDetectRootUuid
					doEditGrubConfigLuks
				else
					doDetectDevices
					doDetectRootUuid
					doEditGrubConfig
				fi

				doGenerateGrubConfig
				;;

			efi)
				if [ "$LVM_ON_LUKS" == "yes" ]; then
					doDetectDevicesLuks
					doDetectDevicesLuksLvm
					doDetectLuksUuid
					doDetectRootUuid

					case "$EFI_BOOT_LOADER" in
						grub)
							doInstallGrubEfi
							[ ! -z "$EFI_STARTUP_NSH" ] && doCreateEfiStartupNsh
							doEditGrubConfigLuks
							doGenerateGrubConfig
							;;

						gummiboot)
							doInstallGummiboot
							doCreateGummibootEntryLuks
							doCreateGummibootConfig
							;;
					esac
				else
					doDetectDevices
					doDetectRootUuid

					case "$EFI_BOOT_LOADER" in
						grub)
							doInstallGrubEfi
							[ ! -z "$EFI_STARTUP_NSH" ] && doCreateEfiStartupNsh
							doEditGrubConfig
							doGenerateGrubConfig
							;;

						gummiboot)
							doInstallGummiboot
							doCreateGummibootEntry
							doCreateGummibootConfig
							;;
					esac
				fi
				;;
		esac

		[ "$LVM_ON_LUKS" == "yes" ] && doCreateCrypttabLuks

		if [ "$ADD_HOST_USER" == "yes" ]; then
			doAddHostUser

			if [ "$HOST_USER_BASH_LOGOUT_CLEAR" == "yes" ]; then
				doCopyToSu "$HOST_USER_USERNAME"
				doSuBashLogoutClear "$HOST_USER_USERNAME"
			fi

			if [ ! -z "$HOST_USER_LOCALE" ]; then
				if [ ! -z "$HOST_USER_LOCALE_LANG" ]; then
					doCopyToSu "$HOST_USER_USERNAME"
					doSuUserSetLocaleLang "$HOST_USER_USERNAME" "$HOST_USER_LOCALE_LANG"
				fi
			fi
		fi

		if [ "$ADD_MAIN_USER" == "yes" ]; then
			doAddMainUser

			if [ "$MAIN_USER_BASH_LOGOUT_CLEAR" == "yes" ]; then
				doCopyToSu "$MAIN_USER_USERNAME"
				doSuBashLogoutClear "$MAIN_USER_USERNAME"
			fi

			if [ ! -z "$MAIN_USER_LOCALE" ]; then
				if [ ! -z "$MAIN_USER_LOCALE_LANG" ]; then
					doCopyToSu "$MAIN_USER_USERNAME"
					doSuUserSetLocaleLang "$MAIN_USER_USERNAME" "$MAIN_USER_LOCALE_LANG"
				fi
			fi
		fi

		if [ "$INSTALL_SCREEN" == "yes" ]; then
			doInstallScreen

			if [ "$HOST_USER_CREATE_SCREENRC" == "yes" ]; then
				doCopyToSu "$HOST_USER_USERNAME"
				doSuUserCreateScreenrc "$HOST_USER_USERNAME"
			fi

			if [ "$MAIN_USER_CREATE_SCREENRC" == "yes" ]; then
				doCopyToSu "$MAIN_USER_USERNAME"
				doSuUserCreateScreenrc "$MAIN_USER_USERNAME"
			fi
		fi

		if [ "$INSTALL_SSH" == "yes" ]; then
			doInstallSsh

			[ "$ENABLE_SERVICE_SSH" == "yes" ] && doEnableServiceSsh

			[ "$SSH_ACCEPT_KEY_TYPE_SSH_DSS" == "yes" ] && doSshAcceptKeyTypeSshDss
		fi

		[ "$INSTALL_SUDO" == "yes" ] && doInstallSudo

		[ "$ENABLE_MULTILIB" == "yes" ] && doEnableMultilib

		[ "$INSTALL_DEVEL" == "yes" ] && doInstallDevel

		if [ "$INSTALL_YAOURT" == "yes" ]; then
			doCopyToSu "$YAOURT_USER_USERNAME"
			doSuInstallYaourt
		fi

		if [ "$INSTALL_X11" == "yes" ]; then
			doInstallX11

			[ "$X11_KEYBOARD_CONF" == "yes" ] && \
				doX11KeyboardConf "$X11_KEYBOARD_LAYOUT" "$X11_KEYBOARD_MODEL" "$X11_KEYBOARD_VARIANT" "$X11_KEYBOARD_OPTIONS"

			[ "$X11_INSTALL_FONTS" == "yes" ] && doX11InstallFonts

			[ "$X11_INSTALL_XFCE" == "yes" ] && doX11InstallXfce

			[ "$X11_INSTALL_UBUNTU_FONT_RENDERING" == "yes" ] && doX11InstallUbuntuFontRendering

			[ "$X11_INSTALL_THEMES" == "yes" ] && doX11InstallThemes

			if [ "$X11_INSTALL_LIGHTDM" == "yes" ]; then
				doX11InstallLightdm

				[ "$ENABLE_SERVICE_LIGHTDM" == "yes" ] && doEnableServiceLightdm
			fi

			if [ "$X11_INSTALL_TEAMVIEWER" == "yes" ]; then
				doX11InstallTeamviewer

				[ "$ENABLE_SERVICE_TEAMVIEWER" == "yes" ] && doEnableServiceTeamviewer
			fi
		fi

		if [ "$INSTALL_NETWORK_MANAGER" == "yes" ]; then
			doInstallNetworkManager

			[ "$ENABLE_SERVICE_NETWORK_MANAGER" == "yes" ] && doEnableServiceNetworkManager
		fi

		if [ "$INSTALL_CRON" == "yes" ]; then
			doInstallCron

			[ "$ENABLE_SERVICE_CRON" == "yes" ] && doEnableServiceCron
		fi

		if [ "$INSTALL_AT" == "yes" ]; then
			doInstallAt

			[ "$ENABLE_SERVICE_AT" == "yes" ] && doEnableServiceAt
		fi

		if [ "$INSTALL_CUPS" == "yes" ]; then
			doInstallCups

			[ "$ENABLE_SERVICE_CUPS" == "yes" ] && doEnableServiceCups
		fi

		if [ "$INSTALL_TLP" == "yes" ]; then
			doInstallTlp

			[ "$ENABLE_SERVICE_TLP" == "yes" ] && doEnableServiceTlp
		fi

		[ "$INSTALL_PULSEAUDIO" == "yes" ] && doInstallPulseaudio

		if [ "$INSTALL_VIRTUALBOX_GUEST" == "yes" ]; then
			doInstallVirtualboxGuest

			[ "$ENABLE_MODULES_VIRTUALBOX_GUEST" == "yes" ] && doEnableModulesVirtualboxGuest
		fi

		if [ "$INSTALL_VIRTUALBOX_HOST" == "yes" ]; then
			doInstallVirtualboxHost

			[ "$ENABLE_MODULES_VIRTUALBOX_HOST" == "yes" ] && doEnableModulesVirtualboxHost
		fi

		[ "$DISABLE_PC_SPEAKER" == "yes" ] && doDisablePcSpeaker

		[ "$SYMLINK_HASH_COMMANDS" == "yes" ] && doSymlinkHashCommands

		[ "$OPTIMIZE_SWAPPINESS" == "yes" ] && doOptimizeSwappiness

		[ "$OPTIMIZE_IO_SCHEDULER_UDEV" == "yes" ] && doOptimizeIoSchedulerUdev

		[ ! -z "$INSTALL_PACKAGE_SETS" ] && doInstallPackageSets

		if [ "$INSTALL_REMOVE_FROM_SU" == "yes" ]; then
			[ "$ADD_HOST_USER" == "yes" ] && doRemoveFromSu "$HOST_USER_USERNAME"
			[ "$ADD_MAIN_USER" == "yes" ] && doRemoveFromSu "$MAIN_USER_USERNAME"

			[ "$INSTALL_YAOURT" == "yes" ] && doRemoveFromSu "$YAOURT_USER_USERNAME"
		fi

		exit 0
		;;

	suBashLogoutClear)
		doBashLogoutClear
		exit 0
		;;

	suUserSetLocaleLang)
		doUserSetLocaleLang "$INSTALL_OPTIONS"
		exit 0
		;;

	suUserCreateScreenrc)
		doUserCreateScreenrc
		exit 0
		;;

	suInstallYaourt)
		doInstallYaourt
		exit 0
		;;

	suYaourt)
		doYaourt "$INSTALL_OPTIONS"
		exit 0
		;;

	*)
		printf "ERROR: Unknown target ('$INSTALL_TARGET')\n"
		exit 1
		;;
esac
