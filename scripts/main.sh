# shellcheck source=./scripts/protection.sh
source "$GENTOO_INSTALL_REPO_DIR/scripts/protection.sh" || exit 1


################################################
# Functions

function install_stage3() {
	prepare_installation_environment
	apply_disk_configuration
	download_stage3
	extract_stage3
	mount_extra_mounts
}

function configure_base_system() {
	einfo "Generating locales"
	echo "$LOCALES" > /etc/locale.gen \
		|| die "Could not write /etc/locale.gen"
	locale-gen \
		|| die "Could not generate locales"

	if [[ $SYSTEMD == "true" ]]; then
		einfo "Setting machine-id"
		systemd-machine-id-setup \
			|| die "Could not setup systemd machine id"

		# Set hostname
		einfo "Selecting hostname"
		echo "$HOSTNAME" > /etc/hostname \
			|| die "Could not write /etc/hostname"

		# Set keymap
		einfo "Selecting keymap"
		echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf \
			|| die "Could not write /etc/vconsole.conf"

		# Set locale
		einfo "Selecting locale"
		echo "LANG=$LOCALE" > /etc/locale.conf \
			|| die "Could not write /etc/locale.conf"

		einfo "Selecting timezone"
		ln -sfn "../usr/share/zoneinfo/$TIMEZONE" /etc/localtime \
			|| die "Could not change /etc/localtime link"
	else
		# kernel-install (systemd-boot) wants a machine-id on OpenRC systems too.
		if [[ ! -s /etc/machine-id ]]; then
			tr -d '-' < /proc/sys/kernel/random/uuid > /etc/machine-id \
				|| die "Could not create /etc/machine-id"
			chmod 444 /etc/machine-id
		fi

		# Set hostname
		einfo "Selecting hostname"
		sed -i "/hostname=/c\\hostname=\"$HOSTNAME\"" /etc/conf.d/hostname \
			|| die "Could not sed replace in /etc/conf.d/hostname"

		# Set timezone
		einfo "Selecting timezone"
		echo "$TIMEZONE" > /etc/timezone \
			|| die "Could not write /etc/timezone"
		try emerge -v --config sys-libs/timezone-data

		# Set keymap
		einfo "Selecting keymap"
		sed -i "/keymap=/c\\keymap=\"$KEYMAP\"" /etc/conf.d/keymaps \
			|| die "Could not sed replace in /etc/conf.d/keymaps"

		# Set locale
		einfo "Selecting locale"
		try eselect locale set "$LOCALE"
	fi

	# Update environment
	env_update
}

# Prints the VIDEO_CARDS value to use (empty for none).
function resolve_video_cards() {
	[[ $DESKTOP == "none" ]] && return 0
	if [[ $VIDEO_CARDS == "amd" ]]; then
		echo "amdgpu radeonsi"
		return 0
	elif [[ $VIDEO_CARDS != "auto" ]]; then
		echo "$VIDEO_CARDS"
		return 0
	fi

	local cards=()
	local dev vendor
	for dev in /sys/bus/pci/devices/*; do
		[[ -r "$dev/class" && -r "$dev/vendor" ]] || continue
		# PCI base class 0x03 = display controller
		[[ "$(<"$dev/class")" == 0x03* ]] || continue
		vendor="$(<"$dev/vendor")"
		case "$vendor" in
			0x1002) cards+=("amdgpu" "radeonsi") ;;
			0x8086) cards+=("intel") ;;
			0x10de) cards+=("nouveau") ;;
			0x15ad) cards+=("vmware") ;;
			0x1af4) cards+=("virgl") ;;
			0x1b36) cards+=("qxl") ;;
		esac
	done

	[[ ${#cards[@]} -gt 0 ]] || return 0
	printf '%s\n' "${cards[@]}" | awk '!seen[$0]++' | paste -sd' '
}

# Sensible MAKEOPTS: one job per core, but at most one job per 2GiB of RAM
# (the usual gentoo handbook rule of thumb), at least one job.
function calculate_makeopts() {
	local cores mem_kb jobs
	cores="$(nproc)" || cores=1
	mem_kb="$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)" || mem_kb=0
	jobs=$((mem_kb / 1024 / 1024 / 2))
	[[ $jobs -gt $cores ]] && jobs=$cores
	[[ $jobs -lt 1 ]] && jobs=1
	echo "-j$jobs"
}

# Merges pending ._cfg files that portage's autounmask wrote (USE flags, keywords, licenses).
function etc_update_auto() {
	command -v etc-update &>/dev/null || return 0
	etc-update --automode -5 &>/dev/null \
		|| ewarn "etc-update could not merge pending configuration changes; check /etc/portage for ._cfg* files."
}

# emerge with automatic handling of the usual "needs a USE flag / keyword / license" failures:
# portage computes the required changes, they are written to /etc/portage (permanently, so later
# upgrades work too), merged, and the merge continues. A second attempt follows if the first one
# stopped, because merging the changes can unlock further steps. Real failures (blockers,
# compile errors) still end up in the interactive try prompt.
# Portage reports dependency cycles together with the USE changes that break them, e.g.
#   - dev-python/pillow-13.0.0 (Change USE: -truetype)
# Apply those temporarily (package.use/zz-circular-breaker); restore_circular_breaks undoes
# them at the end of the installation and rebuilds the affected packages normally.
CIRCULAR_BREAK_FILE="/etc/portage/package.use/zz-circular-breaker"
CIRCULAR_BREAK_ATOMS=()
function break_circular_deps() {
	local log="$1" line atom flags added=1
	local re='^-[[:space:]]+([^[:space:]]+)-[0-9][^[:space:]]*[[:space:]]+\(Change USE:[[:space:]]*([^)]+)\)'
	touch "$CIRCULAR_BREAK_FILE" || return 1
	while IFS= read -r line; do
		[[ $line =~ $re ]] || continue
		atom="${BASH_REMATCH[1]}"
		flags="${BASH_REMATCH[2]}"
		grep -qxF "$atom $flags" "$CIRCULAR_BREAK_FILE" && continue
		echo "$atom $flags" >> "$CIRCULAR_BREAK_FILE" || return 1
		CIRCULAR_BREAK_ATOMS+=("$atom")
		ewarn "Breaking a circular dependency: $atom $flags (restored after the installation)"
		added=0
	done < <(sed 's/\x1b\[[0-9;]*m//g' "$log")
	return "$added"
}

function restore_circular_breaks() {
	[[ ${#CIRCULAR_BREAK_ATOMS[@]} -gt 0 ]] || return 0
	einfo "Restoring the USE flags that were disabled to break dependency cycles"
	rm -f "$CIRCULAR_BREAK_FILE"
	emerge_auto --oneshot --newuse -- "${CIRCULAR_BREAK_ATOMS[@]}" \
		|| ewarn "Could not rebuild ${CIRCULAR_BREAK_ATOMS[*]} with its normal USE flags; run 'emerge --update --newuse @world' after booting."
	CIRCULAR_BREAK_ATOMS=()
}

# emerge with automatic handling of the usual failures:
#  - needs a USE flag / keyword / license: portage computes the changes, they are written to
#    /etc/portage (permanent, so later upgrades work too), merged, and the merge continues;
#  - circular dependencies: the USE changes portage suggests are applied temporarily;
#  - broken binary package signatures: falls back to building from source.
# Anything else (blockers, compile errors) ends in the interactive try prompt.
function emerge_auto() {
	local log rc attempt generic_retry=false
	log="$(mktemp)" || die "Could not create a temporary file"

	for attempt in 1 2 3 4 5 6; do
		local opts=(--verbose --autounmask=y --autounmask-write=y --autounmask-continue=y)
		# Always pass the binary-package options explicitly: the EMERGE_DEFAULT_OPTS environment
		# variable (set by dispatch_chroot.sh) overrides the one in make.conf.
		if [[ $USE_BINHOST == "true" && ${BINHOST_BROKEN:-false} != "true" ]]; then
			opts+=(--getbinpkg --binpkg-respect-use=y)
		fi

		emerge "${opts[@]}" "$@" 2>&1 | tee "$log"
		rc="${PIPESTATUS[0]}"
		etc_update_auto
		[[ $rc == 0 ]] && break

		if [[ ${BINHOST_BROKEN:-false} != "true" ]] && grep -q "GnuPG verification failed" "$log"; then
			ewarn "Binary package signature verification failed. Building from source instead (slower)."
			BINHOST_BROKEN=true
			sed -i -e '/^EMERGE_DEFAULT_OPTS=.*getbinpkg/d' -e 's/^FEATURES="getbinpkg binpkg-request-signature"$/FEATURES=""/' /etc/portage/make.conf \
				|| ewarn "Could not disable the binary package host in make.conf"
			continue
		fi
		if grep -q "circular dependencies" "$log" && break_circular_deps "$log"; then
			continue
		fi
		if [[ $generic_retry == "false" ]]; then
			generic_retry=true
			ewarn "emerge stopped; retrying once after applying portage's suggested configuration changes"
			continue
		fi
		break
	done
	rm -f "$log"
	return "$rc"
}

function configure_portage() {
	# Prepare /etc/portage for autounmask
	mkdir_or_die 0755 "/etc/portage/package.use"
	touch_or_die 0644 "/etc/portage/package.use/zz-autounmask"
	mkdir_or_die 0755 "/etc/portage/package.accept_keywords"
	touch_or_die 0644 "/etc/portage/package.accept_keywords/zz-autounmask"
	touch_or_die 0644 "/etc/portage/package.license"

	if [[ $SELECT_MIRRORS == "true" ]]; then
		einfo "Temporarily installing mirrorselect"
		try emerge_auto --oneshot app-portage/mirrorselect

		einfo "Selecting fastest portage mirrors"
		local mirrorselect_params=("-s" "4" "-b" "10")
		[[ $SELECT_MIRRORS_LARGE_FILE == "true" ]] \
			&& mirrorselect_params+=("-D")
		try mirrorselect "${mirrorselect_params[@]}"
	fi

	einfo "Configuring /etc/portage/make.conf"
	local video_cards
	video_cards="$(resolve_video_cards)"
	{
		echo
		echo "# Added by gentoo-install"
		echo "MAKEOPTS=\"$(calculate_makeopts)\""
		[[ -n $video_cards ]] \
			&& echo "VIDEO_CARDS=\"$video_cards\""
		[[ $IS_EFI == "true" && $BOOTLOADER == "grub" && $GENTOO_ARCH == "amd64" ]] \
			&& echo 'GRUB_PLATFORMS="efi-64"'
		if [[ $USE_BINHOST == "true" ]]; then
			echo "# Use the official gentoo binary package host where possible (falls back to source builds)."
			echo "FEATURES=\"getbinpkg binpkg-request-signature\""
			# FEATURES alone only allows fetching; emerge must also be told to prefer binary packages.
			# binpkg-respect-use makes portage compile from source when the USE flags differ.
			echo "EMERGE_DEFAULT_OPTS=\"--getbinpkg --binpkg-respect-use=y\""
		fi
	} >> /etc/portage/make.conf \
		|| die "Could not modify /etc/portage/make.conf"

	chmod 644 /etc/portage/make.conf \
		|| die "Could not chmod 644 /etc/portage/make.conf"

	if [[ $USE_BINHOST == "true" ]] && type getuto &>/dev/null; then
		einfo "Setting up binary package signature verification"
		try getuto
	fi
}

# Selects the gentoo profile matching the init system and desktop choice,
# the same way the handbook does it (eselect profile). Returns 0 if the profile changed.
function select_profile() {
	local current base sub="" target
	current="$(eselect profile show | tail -n 1 | tr -d '[:space:]')" \
		|| die "Could not determine current profile"
	[[ -n $current ]] \
		|| die "Could not determine current profile"
	base="${current%/systemd}"

	case "$DESKTOP" in
		plasma) sub="/desktop/plasma" ;;
		gnome)  sub="/desktop/gnome" ;;
		xfce|cosmic) sub="/desktop" ;;
	esac
	[[ $SYSTEMD == "true" ]] \
		&& sub="$sub/systemd"
	target="${base}${sub}"

	if [[ $target == "$current" ]]; then
		einfo "Profile is already $target"
		return 1
	fi

	eselect profile list | awk '{ print $2 }' | grep -Fxq -- "$target" \
		|| die "The profile '$target' does not exist in this portage tree. Select one manually with 'eselect profile' in a chroot."
	einfo "Selecting profile $target"
	try eselect profile set "$target"
	return 0
}

# Filters a list of package atoms down to those that exist in the portage tree,
# so a renamed/removed optional package doesn't abort the whole installation.
function existing_atoms() {
	local atom
	for atom in "$@"; do
		if [[ -d "/var/db/repos/gentoo/$atom" ]]; then
			echo "$atom"
		else
			ewarn "Skipping '$atom': not found in the portage tree" >&2
		fi
	done
}

function get_cmdline() {
	local cmdline=("rd.vconsole.keymap=$KEYMAP_INITRAMFS")
	cmdline+=("${DISK_DRACUT_CMDLINE[@]}")

	if [[ $USED_ZFS != "true" ]]; then
		cmdline+=("root=UUID=$(get_blkid_uuid_for_id "$DISK_ID_ROOT")")
	fi

	echo -n "${cmdline[*]}"
}

# Configures dracut (used by installkernel for every kernel installed, also
# future upgrades) so the initramfs can unlock/assemble the configured storage stack.
function configure_dracut() {
	local modules=("bash")
	[[ $USED_RAID == "true" ]] \
		&& modules+=("mdraid")
	[[ $USED_LUKS == "true" ]] \
		&& modules+=("crypt crypt-gpg")
	[[ $USED_BTRFS == "true" ]] \
		&& modules+=("btrfs")
	[[ $USED_ZFS == "true" ]] \
		&& modules+=("zfs")

	mkdir_or_die 0755 /etc/dracut.conf.d
	cat > /etc/dracut.conf.d/10-gentoo-install.conf <<EOF
# Generated by gentoo-install. Applies to every kernel installed via installkernel.
hostonly="no"
compress="zstd"
ro_mnt="yes"
add_dracutmodules+=" ${modules[*]} "
EOF
	chmod 644 /etc/dracut.conf.d/10-gentoo-install.conf \
		|| die "Could not chmod dracut config"
}

function generate_syslinux_cfg() {
	cat <<EOF
DEFAULT gentoo
PROMPT 0
TIMEOUT 0

LABEL gentoo
	LINUX ../vmlinuz-current
	APPEND initrd=../initramfs.img $(get_cmdline)
EOF
}

# Newest kernel version installed to /boot (by installkernel).
function newest_installed_kver() {
	local f
	f="$(find /boot -maxdepth 1 -name 'vmlinuz-*' -printf '%f\n' | sort -V | tail -n 1)"
	[[ -n $f ]] || return 1
	echo "${f#vmlinuz-}"
}

# EFI: systemd-boot or GRUB on the ESP (mounted at /boot), managed by installkernel.
# Every future kernel upgrade automatically creates the boot entry + initramfs.
function install_bootloader_efi() {
	if [[ $BOOTLOADER == "grub" ]]; then
		install_bootloader_efi_grub_prepare
	else
		install_bootloader_efi_systemd_boot
	fi
}

function install_bootloader_efi_systemd_boot() {
	einfo "Preparing systemd-boot and installkernel"
	mkdir_or_die 0755 /etc/portage/package.use
	if [[ $SYSTEMD == "true" ]]; then
		echo "sys-apps/systemd boot kernel-install" > /etc/portage/package.use/gentoo-install-boot \
			|| die "Could not write package.use"
	else
		echo "sys-apps/systemd-utils boot kernel-install" > /etc/portage/package.use/gentoo-install-boot \
			|| die "Could not write package.use"
	fi
	echo "sys-kernel/installkernel dracut systemd systemd-boot" > /etc/portage/package.use/installkernel \
		|| die "Could not write package.use"

	if [[ $SYSTEMD == "true" ]]; then
		try emerge_auto --oneshot sys-apps/systemd
	else
		try emerge_auto --oneshot sys-apps/systemd-utils
	fi
	try emerge_auto sys-kernel/installkernel sys-kernel/dracut

	configure_dracut

	mkdir_or_die 0755 /etc/kernel
	get_cmdline > /etc/kernel/cmdline \
		|| die "Could not write /etc/kernel/cmdline"
	echo >> /etc/kernel/cmdline
	chmod 644 /etc/kernel/cmdline

	einfo "Installing systemd-boot to the EFI system partition"
	SYSTEMD_RELAX_ESP_CHECKS=1 try bootctl --esp-path=/boot install
	cat > /boot/loader/loader.conf <<EOF
timeout 3
console-mode keep
editor no
EOF
}

# GRUB (EFI). Kernels and initramfs live on the ESP at /boot; installkernel regenerates
# grub.cfg whenever a kernel is installed. Part 1 runs before the kernel is installed.
function install_bootloader_efi_grub_prepare() {
	einfo "Preparing GRUB and installkernel"
	mkdir_or_die 0755 /etc/portage/package.use
	mkdir_or_die 0755 /boot/grub
	echo "sys-kernel/installkernel dracut grub -systemd -systemd-boot" > /etc/portage/package.use/installkernel \
		|| die "Could not write package.use"
	try emerge_auto sys-kernel/installkernel sys-kernel/dracut sys-boot/grub sys-boot/efibootmgr

	configure_dracut

	cat > /etc/default/grub <<EOF
# Generated by gentoo-install
GRUB_DISTRIBUTOR="Gentoo"
GRUB_TIMEOUT=3
GRUB_CMDLINE_LINUX="$(get_cmdline)"
GRUB_DISABLE_OS_PROBER=true
EOF
	chmod 644 /etc/default/grub

	# Fallback for kernels installed without installkernel's grub plugin.
	mkdir_or_die 0755 /etc/kernel/postinst.d
	cat > /etc/kernel/postinst.d/95-gentoo-install-grub <<'EOF'
#!/bin/sh
# Installed by gentoo-install: regenerate grub.cfg after a kernel installation,
# unless installkernel's own grub plugin already does it.
[ -e /usr/lib/kernel/postinst.d/91-grub-mkconfig.install ] && exit 0
command -v grub-mkconfig >/dev/null 2>&1 || exit 0
exec grub-mkconfig -o /boot/grub/grub.cfg
EOF
	chmod 755 /etc/kernel/postinst.d/95-gentoo-install-grub \
		|| die "Could not chmod kernel hook"
}

# GRUB part 2: runs after the kernel is installed.
function install_bootloader_efi_grub_finish() {
	local target="x86_64-efi"
	[[ $GENTOO_ARCH == "amd64" ]] \
		|| die "The grub bootloader option is only implemented for amd64."

	einfo "Installing GRUB to the EFI system partition"
	try grub-install --target="$target" --efi-directory=/boot --bootloader-id=Gentoo
	# Also install to the removable/fallback path, so the VM / firmware boots even if
	# the NVRAM boot entry is lost (common with virtual machines).
	try grub-install --target="$target" --efi-directory=/boot --removable

	einfo "Generating grub.cfg"
	mkdir_or_die 0755 /boot/grub
	if ! grub-mkconfig -o /boot/grub/grub.cfg || ! grep -q '^[[:space:]]*linux[[:space:]]' /boot/grub/grub.cfg 2>/dev/null; then
		ewarn "grub-mkconfig did not produce a boot entry inside the chroot; writing a static fallback grub.cfg."
		ewarn "It is replaced by a generated one automatically on the next kernel installation."
		local kver
		kver="$(newest_installed_kver)" \
			|| die "No kernel found in /boot"
		cat > /boot/grub/grub.cfg <<EOF
set timeout=3
set default=0
menuentry "Gentoo Linux ($kver)" {
	search --no-floppy --fs-uuid --set=root $(get_blkid_uuid_for_id "$DISK_ID_EFI")
	linux /vmlinuz-$kver $(get_cmdline)
	initrd /initramfs-$kver.img
}
EOF
	fi
}

# BIOS (legacy): syslinux on the FAT boot partition. A kernel postinst hook keeps it
# in sync with new kernels, so upgrades stay bootable here too.
function install_bootloader_bios_prepare() {
	mkdir_or_die 0755 /etc/portage/package.use
	echo "sys-kernel/installkernel dracut -systemd" > /etc/portage/package.use/installkernel \
		|| die "Could not write package.use"
	try emerge_auto sys-kernel/installkernel sys-kernel/dracut sys-boot/syslinux
	configure_dracut
}

function install_bootloader_bios_finish() {
	mkdir_or_die 0755 /etc/kernel/postinst.d
	cat > /etc/kernel/postinst.d/90-gentoo-install-syslinux <<'EOF'
#!/bin/sh
# Installed by gentoo-install. Copies the newest kernel and initramfs to the
# syslinux boot partition after each kernel installation.
kver="$1"
[ -n "$kver" ] || exit 0
mountpoint -q /boot/bios || exit 0
cp "/boot/vmlinuz-$kver" /boot/bios/vmlinuz-current || exit 1
cp "/boot/initramfs-$kver.img" /boot/bios/initramfs.img || exit 1
EOF
	chmod 755 /etc/kernel/postinst.d/90-gentoo-install-syslinux \
		|| die "Could not chmod kernel hook"

	local kver
	kver="$(newest_installed_kver)" \
		|| die "No kernel found in /boot"
	try /etc/kernel/postinst.d/90-gentoo-install-syslinux "$kver"

	einfo "Installing syslinux"
	local biosdev
	biosdev="$(resolve_device_by_id "$DISK_ID_BIOS")" \
		|| die "Could not resolve device with id=$DISK_ID_BIOS"
	mkdir_or_die 0700 "/boot/bios/syslinux"
	try syslinux --directory syslinux --install "$biosdev"

	generate_syslinux_cfg > /boot/bios/syslinux/syslinux.cfg \
		|| die "Could save generated syslinux.cfg"

	einfo "Copying syslinux MBR record"
	local gptdev
	gptdev="$(resolve_device_by_id "${DISK_ID_PART_TO_GPT_ID[$DISK_ID_BIOS]}")" \
		|| die "Could not resolve device with id=${DISK_ID_PART_TO_GPT_ID[$DISK_ID_BIOS]}"
	try dd bs=440 conv=notrunc count=1 if=/usr/share/syslinux/gptmbr.bin of="$gptdev"
}

function install_kernel() {
	einfo "Installing firmware"
	echo "sys-kernel/linux-firmware linux-fw-redistributable no-source-code" >> /etc/portage/package.license \
		|| die "Could not write to /etc/portage/package.license"
	try emerge_auto sys-kernel/linux-firmware

	if [[ $IS_EFI == "true" ]]; then
		install_bootloader_efi
	else
		install_bootloader_bios_prepare
	fi

	# Storage tooling must be present before the kernel is installed,
	# so the initramfs generated for it can include the matching dracut modules.
	[[ $USED_RAID == "true" ]] && {
		einfo "Installing mdadm"
		try emerge_auto sys-fs/mdadm
	}
	[[ $USED_LUKS == "true" ]] && {
		einfo "Installing cryptsetup"
		try emerge_auto sys-fs/cryptsetup
	}
	[[ $USED_BTRFS == "true" ]] && {
		einfo "Installing btrfs-progs"
		try emerge_auto sys-fs/btrfs-progs
	}

	einfo "Installing the gentoo distribution kernel (binary)"
	try emerge_auto sys-kernel/gentoo-kernel-bin

	if [[ $USED_ZFS == "true" ]]; then
		einfo "Installing zfs"
		try emerge_auto sys-fs/zfs sys-fs/zfs-kmod

		einfo "Enabling zfs services"
		if [[ $SYSTEMD == "true" ]]; then
			try systemctl enable zfs.target
			try systemctl enable zfs-import-cache
			try systemctl enable zfs-mount
			try systemctl enable zfs-import.target
		else
			try rc-update add zfs-import boot
			try rc-update add zfs-mount boot
		fi

		# Reinstall the kernel so the initramfs is regenerated with the zfs module.
		einfo "Regenerating initramfs with zfs support"
		try emerge_auto --oneshot sys-kernel/gentoo-kernel-bin
	fi

	if [[ $IS_EFI == "true" ]]; then
		[[ $BOOTLOADER == "grub" ]] \
			&& install_bootloader_efi_grub_finish
	else
		install_bootloader_bios_finish
	fi
}

function add_fstab_entry() {
	printf '%-46s  %-24s  %-6s  %-96s %s\n' "$1" "$2" "$3" "$4" "$5" >> /etc/fstab \
		|| die "Could not append entry to fstab"
}

function generate_fstab() {
	einfo "Generating fstab"
	install -m0644 -o root -g root "$GENTOO_INSTALL_REPO_DIR/contrib/fstab" /etc/fstab \
		|| die "Could not overwrite /etc/fstab"
	if [[ $USED_ZFS != "true" && -n $DISK_ID_ROOT_TYPE ]]; then
		add_fstab_entry "UUID=$(get_blkid_uuid_for_id "$DISK_ID_ROOT")" "/" "$DISK_ID_ROOT_TYPE" "$DISK_ID_ROOT_MOUNT_OPTS" "0 1"
	fi
	if [[ $IS_EFI == "true" ]]; then
		# The ESP is mounted at /boot, so kernels live on it (works with encrypted roots).
		add_fstab_entry "UUID=$(get_blkid_uuid_for_id "$DISK_ID_EFI")" "/boot" "vfat" "defaults,noatime,fmask=0077,dmask=0077,nodev,nosuid,discard" "0 2"
	else
		add_fstab_entry "UUID=$(get_blkid_uuid_for_id "$DISK_ID_BIOS")" "/boot/bios" "vfat" "defaults,noatime,fmask=0177,dmask=0077,noexec,nodev,nosuid,discard" "0 2"
	fi
	if [[ -v "DISK_ID_SWAP" ]]; then
		add_fstab_entry "UUID=$(get_blkid_uuid_for_id "$DISK_ID_SWAP")" "none" "swap" "defaults,discard" "0 0"
	fi
	local entry id mp fs opts
	for entry in "${DISK_EXTRA_MOUNTS[@]}"; do
		IFS='|' read -r id mp fs opts <<< "$entry"
		add_fstab_entry "UUID=$(get_blkid_uuid_for_id "$id")" "$mp" "$fs" "$opts" "0 2"
	done
}

# Sets the password of $1 from $2 (a crypt hash), or asks interactively if no hash is given.
function set_account_password() {
	local account="$1" hash="$2"
	if [[ -n $hash ]]; then
		printf '%s:%s\n' "$account" "$hash" | chpasswd -e \
			|| die "Could not set password for '$account'"
	else
		einfo "Choose a password for '$account'"
		try passwd "$account"
	fi
}

function setup_accounts() {
	case "$ROOT_PASSWORD_MODE" in
		locked)
			einfo "Locking the root account (administration via sudo)"
			passwd -l root \
				|| die "Could not lock root account"
			;;
		set)
			einfo "Setting the root password"
			set_account_password root "$ROOT_PASSWORD_HASH"
			;;
		ask)
			einfo "Choose a password for 'root'"
			try passwd root
			;;
	esac

	[[ -n $USER_NAME ]] || return 0

	einfo "Creating user '$USER_NAME'"
	local group groups=()
	for group in wheel audio video usb cdrom plugdev input render; do
		getent group "$group" &>/dev/null \
			&& groups+=("$group")
	done
	local group_list
	group_list="$(IFS=,; echo "${groups[*]}")"
	useradd --create-home --groups "$group_list" --shell /bin/bash "$USER_NAME" \
		|| die "Could not create user '$USER_NAME'"
	set_account_password "$USER_NAME" "$USER_PASSWORD_HASH"
}

function setup_sudo() {
	[[ -n $USER_NAME && $USER_SUDO == "true" ]] || return 0

	einfo "Installing sudo and allowing the wheel group"
	try emerge_auto app-admin/sudo
	mkdir_or_die 0750 /etc/sudoers.d
	install -m0440 -o root -g root /dev/null /etc/sudoers.d/10-wheel \
		|| die "Could not create /etc/sudoers.d/10-wheel"
	echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/10-wheel \
		|| die "Could not write /etc/sudoers.d/10-wheel"
	visudo -cf /etc/sudoers.d/10-wheel \
		|| die "Generated sudoers file is invalid"
}

# Wired networking: systemd-networkd on systemd, dhcpcd on OpenRC.
# $1: "dhcp" forces DHCP, otherwise the configured (possibly static) setup is used.
function configure_wired_network() {
	local mode="${1:-configured}"
	if [[ $SYSTEMD == "true" ]]; then
		enable_service systemd-networkd
		enable_service systemd-resolved
		if [[ $mode == "dhcp" || $SYSTEMD_NETWORKD_DHCP == "true" ]]; then
			printf '[Match]\nName=%s\n\n[Network]\nDHCP=yes\n' "${SYSTEMD_NETWORKD_INTERFACE_NAME}" > /etc/systemd/network/20-wired.network \
				|| die "Could not write dhcp network config to '/etc/systemd/network/20-wired.network'"
		else
			local addresses=""
			local addr
			for addr in "${SYSTEMD_NETWORKD_ADDRESSES[@]}"; do
				addresses="${addresses}Address=$addr"$'\n'
			done
			printf '[Match]\nName=%s\n\n[Network]\n%sGateway=%s\n' "${SYSTEMD_NETWORKD_INTERFACE_NAME}" "$addresses" "$SYSTEMD_NETWORKD_GATEWAY" > /etc/systemd/network/20-wired.network \
				|| die "Could not write static network config to '/etc/systemd/network/20-wired.network'"
		fi
		chown root:systemd-network /etc/systemd/network/20-wired.network \
			|| die "Could not change owner of '/etc/systemd/network/20-wired.network'"
		chmod 640 /etc/systemd/network/20-wired.network \
			|| die "Could not change permissions of '/etc/systemd/network/20-wired.network'"
	else
		einfo "Installing dhcpcd"
		try emerge_auto net-misc/dhcpcd
		if [[ $mode == "dhcp" ]]; then
			# Leave wifi interfaces to iwd.
			echo "allowinterfaces en* eth*" >> /etc/dhcpcd.conf \
				|| die "Could not write /etc/dhcpcd.conf"
		fi
		enable_service dhcpcd
	fi
}

function configure_network() {
	case "$NETWORK_BACKEND" in
		iwd)
			einfo "Installing iwd (use 'iwctl' to manage wifi)"
			local resolver="systemd"
			if [[ $SYSTEMD != "true" ]]; then
				resolver="resolvconf"
				try emerge_auto net-dns/openresolv
			fi
			try emerge_auto net-wireless/iwd
			mkdir_or_die 0755 /etc/iwd
			cat > /etc/iwd/main.conf <<EOF
[General]
EnableNetworkConfiguration=true

[Network]
NameResolvingService=$resolver
EOF
			chmod 644 /etc/iwd/main.conf
			enable_service iwd
			# iwd only manages wifi, ethernet is handled by the regular wired setup.
			configure_wired_network dhcp
			;;
		networkmanager)
			einfo "Installing NetworkManager"
			echo "net-misc/networkmanager wifi" > /etc/portage/package.use/gentoo-install-network \
				|| die "Could not write package.use"
			try emerge_auto net-misc/networkmanager
			if [[ $SYSTEMD != "true" ]]; then
				try rc-update add dbus default
			fi
			enable_service NetworkManager
			;;
		wired)
			configure_wired_network configured
			;;
	esac
}

# Resolves a bare package name to category/name inside the cosmic-overlay.
function overlay_atom() {
	local path
	path="$(compgen -G "/var/db/repos/cosmic-overlay/*/$1" | head -n 1)" \
		&& [[ -n $path ]] \
		&& echo "${path#/var/db/repos/cosmic-overlay/}"
}

# COSMIC is not in the main gentoo tree (as of writing); it comes from a community overlay.
function setup_cosmic_overlay() {
	ewarn "COSMIC is not in the main Gentoo tree: using the community 'cosmic-overlay' (experimental)."
	try emerge_auto --oneshot app-eselect/eselect-repository
	try eselect repository add cosmic-overlay git https://github.com/fsvm88/cosmic-overlay
	try emaint sync -r cosmic-overlay
	mkdir_or_die 0755 /etc/portage/package.accept_keywords
	# Accept the tagged (testing-keyword) releases of everything from this overlay.
	echo '*/*::cosmic-overlay' > /etc/portage/package.accept_keywords/cosmic-de \
		|| die "Could not write package.accept_keywords"
	overlay_atom cosmic-meta >/dev/null \
		|| die "cosmic-meta is not in the cosmic-overlay (layout changed?). Choose another desktop."
}

# Enables a third-party repository (idempotent). $1: name, $2: optional git url if it is not
# in the eselect-repository list.
function enable_overlay() {
	local name="$1" url="${2:-}"
	if [[ ! -x /usr/bin/eselect-repository && ! -e /usr/share/eselect/modules/repository.eselect ]]; then
		try emerge_auto --oneshot app-eselect/eselect-repository
	fi
	if [[ ! -d /var/db/repos/$name ]]; then
		eselect repository enable "$name" \
			|| { [[ -n $url ]] && eselect repository add "$name" git "$url"; } \
			|| return 1
		emaint sync -r "$name" || return 1
	fi
}

# Browsers that are not in the main tree come from overlays. If anything about that fails,
# fall back to firefox-bin so the system always ends up with a browser.
function install_overlay_browser() {
	local overlay="" url="" atom=""
	case "$BROWSER" in
		librewolf) overlay="librewolf"; url="https://codeberg.org/librewolf/gentoo.git"; atom="www-client/librewolf" ;;
		zen)       overlay="guru"; atom="www-client/zen-bin" ;;
		waterfox)  overlay="guru"; atom="www-client/waterfox-bin" ;;
		mullvad)   overlay="guru"; atom="www-client/mullvad-browser-bin" ;;
		*) return 0 ;;
	esac

	einfo "Installing the '$BROWSER' browser from the '$overlay' repository"
	if enable_overlay "$overlay" "$url" && [[ -d /var/db/repos/$overlay/$atom ]]; then
		try emerge_auto -- "$atom"
	else
		ewarn "Could not set up '$BROWSER' ($atom in the '$overlay' repository); installing firefox-bin instead."
		try emerge_auto -- www-client/firefox-bin
	fi
}

function configure_greetd_cosmic() {
	einfo "Configuring greetd with cosmic-greeter"
	mkdir_or_die 0755 /etc/greetd
	cat > /etc/greetd/config.toml <<'EOF'
[terminal]
vt = 7

[default_session]
command = "/usr/bin/cosmic-comp /usr/bin/cosmic-greeter"
user = "cosmic-greeter"
EOF
	chmod 644 /etc/greetd/config.toml
	getent passwd cosmic-greeter &>/dev/null \
		|| ewarn "User 'cosmic-greeter' does not exist; the login screen will not start until it is created."
	if [[ $SYSTEMD != "true" ]]; then
		[[ -f /etc/conf.d/display-manager ]] \
			&& { grep -q '^CHECKVT=' /etc/conf.d/display-manager || echo 'CHECKVT=7' >> /etc/conf.d/display-manager; }
	fi
}

function install_desktop() {
	[[ $DESKTOP != "none" ]] || return 0

	local dm="$DISPLAY_MANAGER"
	local pkgs=(
		x11-base/xorg-server
		x11-base/xorg-drivers
		media-video/pipewire
		media-video/wireplumber
		media-fonts/dejavu
		media-fonts/liberation-fonts
	)
	case "$DESKTOP" in
		plasma)
			[[ $dm == "auto" ]] && dm="sddm"
			pkgs+=(kde-plasma/plasma-meta kde-apps/dolphin)
			[[ $TERMINAL == "default" ]] && pkgs+=(kde-apps/konsole)
			;;
		gnome)
			[[ $dm == "auto" ]] && dm="gdm"
			pkgs+=(gnome-base/gnome-light)
			[[ $TERMINAL == "default" ]] && pkgs+=(x11-terms/gnome-terminal)
			;;
		xfce)
			[[ $dm == "auto" ]] && dm="lightdm"
			pkgs+=(xfce-base/xfce4-meta)
			;;
		cosmic)
			[[ $dm == "auto" ]] && dm="cosmic-greeter"
			;;
	esac
	# Browser and terminal chosen in the configuration. Xfce and COSMIC bring their own terminal.
	case "$TERMINAL" in
		kitty)     pkgs+=(x11-terms/kitty) ;;
		foot)      pkgs+=(gui-apps/foot) ;;
		alacritty) pkgs+=(x11-terms/alacritty) ;;
		wezterm)   pkgs+=(x11-terms/wezterm) ;;
		ghostty)   pkgs+=(x11-terms/ghostty) ;;
	esac
	case "$BROWSER" in
		firefox-bin) pkgs+=(www-client/firefox-bin) ;;
		firefox)     pkgs+=(www-client/firefox) ;;
	esac
	local overlay_pkgs=()
	case "$dm" in
		cosmic-greeter) pkgs+=(gui-libs/greetd); overlay_pkgs+=(cosmic-greeter) ;;
		sddm)    pkgs+=(x11-misc/sddm) ;;
		gdm)     pkgs+=(gnome-base/gdm) ;;
		lightdm) pkgs+=(x11-misc/lightdm x11-misc/lightdm-gtk-greeter) ;;
	esac
	if [[ $SYSTEMD != "true" ]]; then
		pkgs+=(sys-auth/elogind sys-apps/dbus gui-libs/display-manager-init)
	fi

	einfo "Installing the '$DESKTOP' desktop (this takes a while)"
	echo "media-video/pipewire sound-server" > /etc/portage/package.use/gentoo-install-desktop \
		|| die "Could not write package.use"
	local available
	readarray -t available < <(existing_atoms "${pkgs[@]}")
	try emerge_auto -- "${available[@]}"

	install_overlay_browser

	if [[ $DESKTOP == "cosmic" ]]; then
		setup_cosmic_overlay
		local cosmic_atoms=() name atom
		for name in cosmic-meta pop-theme-meta "${overlay_pkgs[@]}"; do
			atom="$(overlay_atom "$name")" \
				|| die "Package '$name' was not found in the cosmic-overlay. The overlay layout may have changed; choose another desktop."
			cosmic_atoms+=("$atom")
		done
		einfo "Installing COSMIC (compiled from source, this takes a long time)"
		try emerge_auto -- "${cosmic_atoms[@]}"
	fi

	# cosmic-greeter runs on top of greetd.
	if [[ $dm == "cosmic-greeter" ]]; then
		configure_greetd_cosmic
		dm="greetd"
	fi

	einfo "Enabling the display manager ($dm)"
	if [[ $SYSTEMD == "true" ]]; then
		enable_service "$dm"
		try systemctl set-default graphical.target
		# Per-user audio services (pipewire is started on login via socket activation)
		systemctl --global enable pipewire.socket pipewire-pulse.socket wireplumber.service \
			|| ewarn "Could not enable the pipewire user services; enable them manually with 'systemctl --user enable ...'."
	else
		try rc-update add dbus default
		try rc-update add elogind boot
		if [[ -f /etc/conf.d/display-manager ]]; then
			sed -i "s/^#\?DISPLAYMANAGER=.*/DISPLAYMANAGER=\"$dm\"/" /etc/conf.d/display-manager \
				|| die "Could not set DISPLAYMANAGER"
			try rc-update add display-manager default
		else
			ewarn "/etc/conf.d/display-manager not found; configure your display manager manually."
		fi
		ewarn "OpenRC: audio (pipewire) must be started per session, see 'gentoo-pipewire-launcher' in the gentoo wiki."
	fi
}

function main_install_gentoo_in_chroot() {
	[[ $# == 0 ]] || die "Too many arguments"

	if [[ $IS_EFI == "true" ]]; then
		# Mount efi partition. It is the /boot partition: kernels and initramfs live here,
		# which also works when the root filesystem is encrypted.
		mount_efivars
		einfo "Mounting efi partition"
		mount_by_id "$DISK_ID_EFI" "/boot"
	else
		# Mount bios partition
		einfo "Mounting bios partition"
		mount_by_id "$DISK_ID_BIOS" "/boot/bios"
	fi

	# Ask for passwords first, so the rest can run unattended.
	setup_accounts

	# Sync portage
	einfo "Syncing portage tree"
	try emerge-webrsync

	# Configure basic system things like timezone, locale, ...
	configure_base_system

	# Prepare portage environment
	configure_portage

	# Install git (for git portage overlays)
	einfo "Installing git"
	try emerge_auto dev-vcs/git

	if [[ "$PORTAGE_SYNC_TYPE" == "git" ]]; then
		mkdir_or_die 0755 "/etc/portage/repos.conf"
		cat > /etc/portage/repos.conf/gentoo.conf <<EOF
[DEFAULT]
main-repo = gentoo

[gentoo]
location = /var/db/repos/gentoo
sync-type = git
sync-uri = $PORTAGE_GIT_MIRROR
auto-sync = yes
sync-depth = $([[ $PORTAGE_GIT_FULL_HISTORY == true ]] && echo -n 0 || echo -n 1)
sync-git-verify-commit-signature = yes
sync-openpgp-key-path = /usr/share/openpgp-keys/gentoo-release.asc
EOF
		chmod 644 /etc/portage/repos.conf/gentoo.conf \
			|| die "Could not change permissions of '/etc/portage/repos.conf/gentoo.conf'"
		rm -rf /var/db/repos/gentoo \
			|| die "Could not delete obsolete rsync gentoo repository"
		try emerge --sync
	fi

	# Native CPU flags are only useful when building from source. Setting them would make
	# many packages incompatible with the binary package host, so they are skipped there.
	if [[ $USE_BINHOST != "true" && ( $GENTOO_ARCH == "amd64" || $GENTOO_ARCH == "x86" ) ]]; then
		einfo "Detecting CPU flags"
		try emerge_auto --oneshot app-portage/cpuid2cpuflags
		echo "*/* $(cpuid2cpuflags)" > /etc/portage/package.use/00cpu-flags \
			|| die "Could not write CPU flags"
	fi

	# Choose the profile for the init system / desktop, then update the system to match.
	if select_profile; then
		einfo "Updating the system for the new profile (@world)"
		try emerge_auto --update --deep --newuse @world
	fi

	# Install kernel, initramfs and bootloader
	install_kernel

	# Generate a valid fstab file
	generate_fstab

	# Install gentoolkit
	einfo "Installing gentoolkit"
	try emerge_auto app-portage/gentoolkit

	configure_network
	setup_sudo
	install_desktop

	# Install additional packages, if any.
	if [[ ${#ADDITIONAL_PACKAGES[@]} -gt 0 ]]; then
		einfo "Installing additional packages"
		try emerge_auto -- "${ADDITIONAL_PACKAGES[@]}"
	fi

	restore_circular_breaks

	# If configured, change to gentoo testing at the very end, so the installation
	# above only used the stable tree. You can deal with the blockers afterwards.
	if [[ $USE_PORTAGE_TESTING == "true" ]]; then
		einfo "Adding ~$GENTOO_ARCH to ACCEPT_KEYWORDS"
		echo "ACCEPT_KEYWORDS=\"~$GENTOO_ARCH\"" >> /etc/portage/make.conf \
			|| die "Could not modify /etc/portage/make.conf"
	fi

	# Do this last: the installer needs the copied resolv.conf for downloads until now.
	if [[ $SYSTEMD == "true" && $NETWORK_BACKEND != "networkmanager" ]]; then
		einfo "Linking /etc/resolv.conf to systemd-resolved"
		ln -sf ../run/systemd/resolve/stub-resolv.conf /etc/resolv.conf \
			|| die "Could not link /etc/resolv.conf"
	fi

	einfo "Gentoo installation complete."
	[[ $USED_LUKS == "true" ]] \
		&& einfo "A backup of your luks headers can be found at '$LUKS_HEADER_BACKUP_DIR', in case you want to have a backup."
	einfo "You may now reboot your system or execute ./install --chroot $ROOT_MOUNTPOINT to enter your system in a chroot."
	einfo "Chrooting in this way is always possible in case you need to fix something after rebooting."
}

# Copies wifi profiles of the live environment (iwd) to the new system,
# so the installed system can connect without setting up wifi again.
function copy_live_wifi_profiles() {
	[[ $NETWORK_BACKEND == "iwd" && $COPY_LIVE_WIFI == "true" ]] || return 0
	[[ -d /var/lib/iwd ]] || return 0

	local profiles=()
	local f
	for f in /var/lib/iwd/*.psk /var/lib/iwd/*.open /var/lib/iwd/*.8021x; do
		[[ -f $f ]] && profiles+=("$f")
	done
	[[ ${#profiles[@]} -gt 0 ]] || return 0

	einfo "Copying ${#profiles[@]} wifi profile(s) from the live environment"
	install -d -m0700 "$ROOT_MOUNTPOINT/var/lib/iwd" \
		|| die "Could not create $ROOT_MOUNTPOINT/var/lib/iwd"
	for f in "${profiles[@]}"; do
		install -m0600 "$f" "$ROOT_MOUNTPOINT/var/lib/iwd/" \
			|| die "Could not copy wifi profile '$f'"
	done
}

function main_install() {
	[[ $# == 0 ]] || die "Too many arguments"

	gentoo_umount
	install_stage3
	copy_live_wifi_profiles

	[[ $IS_EFI == "true" ]] \
		&& mount_efivars
	gentoo_chroot "$ROOT_MOUNTPOINT" "$GENTOO_INSTALL_REPO_BIND/install" __install_gentoo_in_chroot
}

function main_chroot() {
	# Skip if already mounted
	mountpoint -q -- "$1" \
		|| die "'$1' is not a mountpoint"

	gentoo_chroot "$@"
}
