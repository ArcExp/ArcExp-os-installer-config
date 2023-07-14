#!/usr/bin/env bash

# load collection of checks and functions
source /etc/os-installer/lib.sh || { printf 'Failed to load /etc/os-installer/lib.sh\n'; exit 1; }

# sanity check that all variables were set
if [ -z "${OSI_LOCALE+x}" ] || \
   [ -z "${OSI_DEVICE_PATH+x}" ] || \
   [ -z "${OSI_DEVICE_IS_PARTITION+x}" ] || \
   [ -z "${OSI_DEVICE_EFI_PARTITION+x}" ] || \
   [ -z "${OSI_USE_ENCRYPTION+x}" ] || \
   [ -z "${OSI_ENCRYPTION_PIN+x}" ]
then
    printf 'install.sh called without all environment variables set!\n'
    exit 1
fi

# Check if something is already mounted to $workdir
if mountpoint -q "$workdir"; then
    printf "%s is already a mountpoint, unmount this directory and try again\n" "$workdir"
    exit 1
fi

# Write partition table to the disk
if [ "${OSI_DEVICE_IS_PARTITION}" -eq 0 ]; then
    # Disk-level partitioning
    if [ -n "${OSI_DEVICE_EFI_PARTITION}" ]; then
        # GPT partitioning for EFI systems
        task_wrapper sudo parted "${OSI_DEVICE_PATH}" mklabel gpt --script
        task_wrapper sudo parted "${OSI_DEVICE_PATH}" mkpart primary ext4 1MiB 512MiB --script
        task_wrapper sudo parted "${OSI_DEVICE_PATH}" mkpart primary btrfs 512MiB 100% --script
    else
        # MBR partitioning for BIOS systems
        task_wrapper sudo parted "${OSI_DEVICE_PATH}" mklabel msdos --script
        task_wrapper sudo parted "${OSI_DEVICE_PATH}" mkpart primary ext4 1MiB 512MiB --script
        task_wrapper sudo parted "${OSI_DEVICE_PATH}" mkpart primary btrfs 512MiB 100% --script
    fi
fi

# Check if encryption is requested, write filesystems accordingly
if [[ "$OSI_USE_ENCRYPTION" -eq 1 ]]; then
    # If user requested disk encryption
    if [[ "$OSI_DEVICE_IS_PARTITION" -eq 0 ]]; then
        # If target is a drive
        printf '%s\n' "$OSI_ENCRYPTION_PIN" | task_wrapper sudo mkfs.ext4 -F "${OSI_DEVICE_PATH}1"
        printf '%s\n' "$OSI_ENCRYPTION_PIN" | task_wrapper sudo cryptsetup -q luksFormat "${OSI_DEVICE_PATH}2"
        printf '%s\n' "$OSI_ENCRYPTION_PIN" | task_wrapper sudo cryptsetup open "${OSI_DEVICE_PATH}2" "$rootlabel" -
        task_wrapper sudo mkfs.btrfs -f "/dev/mapper/$rootlabel"
    else
        # If target is a partition
        printf 'PARTITION TARGET NOT YET IMPLEMENTED BECAUSE OF EFI DETECTION BUG\n'
        exit 1
    fi
else
    # If no disk encryption requested
    if [[ "$OSI_DEVICE_IS_PARTITION" -eq 0 ]]; then
        # If target is a drive
        yes | task_wrapper sudo mkfs.ext4 -F "${OSI_DEVICE_PATH}1"
        yes | task_wrapper sudo mkfs.btrfs -f "${OSI_DEVICE_PATH}2"
    else
        # If target is a partition
        printf 'PARTITION TARGET NOT YET IMPLEMENTED BECAUSE OF EFI DETECTION BUG\n'
        exit 1
    fi
fi

# Mount partitions
if [[ "$OSI_DEVICE_IS_PARTITION" -eq 0 ]]; then
    # If target is a drive
    task_wrapper sudo mount "${OSI_DEVICE_PATH}2" "$workdir"
    task_wrapper sudo btrfs subvolume create "$workdir/@"
    task_wrapper sudo umount "$workdir"
    task_wrapper sudo mount -o subvol=@ "${OSI_DEVICE_PATH}2" "$workdir"
    task_wrapper sudo mkdir -p "$workdir/boot"
    task_wrapper sudo mount "${OSI_DEVICE_PATH}1" "$workdir/boot"
    task_wrapper sudo mkdir -p "$workdir/home"
else
    # If target is a partition
    printf 'PARTITION TARGET NOT YET IMPLEMENTED BECAUSE OF EFI DETECTION BUG\n'
    exit 1
fi

# Install system packages
task_wrapper sudo pacstrap "$workdir" base base-devel linux linux-firmware intel-ucode amd-ucode

# Populate the Arch Linux keyring inside chroot
task_wrapper sudo arch-chroot "$workdir" pacman-key --init
task_wrapper sudo arch-chroot "$workdir" pacman-key --populate archlinux

# Install desktop environment packages
task_wrapper sudo arch-chroot "$workdir" pacman -S --noconfirm firefox flatpak fsarchiver gdm gedit git gnome-backgrounds gnome-calculator gnome-console gnome-control-center gnome-disk-utility gnome-font-viewer gnome-logs gnome-photos gnome-screenshot gnome-settings-daemon gnome-shell gnome-software gnome-text-editor gnome-tweaks gnu-netcat gpart gpm gptfdisk nautilus neofetch networkmanager network-manager-applet power-profiles-daemon dbus ostree bubblewrap glib2 libarchive flatpak

# Install GRUB based on firmware type (BIOS or UEFI)
if [ -d "$workdir/sys/firmware/efi" ]; then
    # UEFI system
    task_wrapper sudo arch-chroot "$workdir" pacman -S --noconfirm grub efibootmgr
    task_wrapper sudo arch-chroot "$workdir" grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
else
    # BIOS system
    task_wrapper sudo arch-chroot "$workdir" pacman -S --noconfirm grub
    task_wrapper sudo arch-chroot "$workdir" grub-install --target=i386-pc "${OSI_DEVICE_PATH}"
fi

# Generate the GRUB configuration file
task_wrapper sudo arch-chroot "$workdir" grub-mkconfig -o /boot/grub/grub.cfg

# Generate the fstab file
task_wrapper sudo genfstab -U "$workdir" | task_wrapper sudo tee "$workdir/etc/fstab"

exit 0