#!/usr/bin/env bash
set -e

if [[ "$EUID" -ne 0 ]]; then
  echo "Please run as root"
  exit
fi

function help() {
  echo ""
  echo "This is a utility to prepare disk for running ansible playbook. Based on parameters, it will:"
  echo "  - format disk"
  echo "  - create encrypted partitions"
  echo "  - setup mount points"
  echo "  - bootstrap clean arch installation"
  echo "  - chroot into installation so you can run ansible playbook"
  echo ""
  echo "To run it you should run ./disk-bootstrap.sh -s [disk size] -n {device}"
  echo "where device is a block device where to install e.g. /dev/sda (not a partition e.g. /dev/sda1)"
  echo ""
  echo "Optional parameters (need to be added before other parameters):"
  echo "  h - this help"
  echo "  m - don't run install script, only mount volumes"
  echo "  n - no-format disk"
  echo "  c - clear install dir after installation"
  echo "  s - disk size for sgdisk e.g.: 200GiB"

  exit
}

banner() {
  msg="# $* #"
  edge=$(echo "$msg" | sed 's/./#/g')
  echo "$edge"
  echo "$msg"
  echo "$edge"
  echo ""
}

function clear_disk() {
  banner "Clearing disk, you have 3 seconds to cancel"
  sleep 3
  sgdisk --zap-all "$drive"
  sgdisk --clear "$drive"
}

function create_partitions() {
  banner "Creating partitions"
  partprobe "$drive"
  partNum=$(sgdisk -p "$drive" | tail -n 1 | awk '{print $1}')
  sgdisk \
    --new="$((partNum=partNum+1)):0:+550MiB" --typecode="${partNum}":ef00 --change-name="${partNum}":EFI \
    --new="$((partNum=partNum+1)):0:+8GiB" --typecode="${partNum}":8200 --change-name="${partNum}":cryptswap \
    --new="$((partNum=partNum+1)):0:${diskSize:-0}" --typecode="${partNum}":8300 --change-name="${partNum}":cryptsystem \
    "$drive"
}

function encrypt_disk() {
  banner "Encrypting disk"
  partprobe "$drive"
  cryptsetup luksFormat --align-payload=8192 -s 256 -c aes-xts-plain64 /dev/disk/by-partlabel/cryptsystem
}

function open_luks() {
  banner "Opening luks encrypted disk"
  cryptsetup open /dev/disk/by-partlabel/cryptsystem system
  cryptsetup open --type plain --key-file /dev/urandom /dev/disk/by-partlabel/cryptswap swap
}

function format_partitions() {
  banner "Formatting disk"
  mkswap -L swap /dev/mapper/swap
  swapon -L swap
  mkfs.fat -F32 -n EFI /dev/disk/by-partlabel/EFI
  mkfs.btrfs --force --label system /dev/mapper/system
}

function create_subvolumes() {
  banner "Creating subvolumes"
  mount -t btrfs LABEL=system /mnt
  btrfs subvolume create /mnt/root
  btrfs subvolume create /mnt/home
  btrfs subvolume create /mnt/snapshots
  umount -R /mnt
}

function mount_volumes() {
  banner "Mounting volumes"
  o=defaults,discard,x-mount.mkdir
  o_btrfs=$o,compress=lzo,ssd,space_cache,noatime
  mount -t btrfs -o subvol=root,$o_btrfs LABEL=system /mnt
  mount -t btrfs -o subvol=home,$o_btrfs LABEL=system /mnt/home
  mount -t btrfs -o subvol=snapshots,$o_btrfs LABEL=system /mnt/.snapshots
  mount -o $o LABEL=EFI /mnt/boot
}

function bootstrap_arch() {
  banner "Bootstrapping Arch"
  pacstrap /mnt base base-devel linux linux-firmware linux-headers git nano ansible rsync refind
  genfstab -L -p /mnt >>/mnt/etc/fstab
  sed -i "s+LABEL=swap+/dev/mapper/swap+" /mnt/etc/fstab
}

function setup_ansible() {
  banner "Setting up ansible"
  mkdir /mnt/install
  echo "luks_uuid: $(blkid -t PARTLABEL=cryptsystem -s UUID -o value)" >>/install/group_vars/all.yaml
  echo "root_uuid: $(blkid -t LABEL=system -s UUID -o value)" >>/install/group_vars/all.yaml
  echo "pts/0" >>/mnt/etc/securetty
  cp -r /install /mnt/
}

function chroot_system() {
  banner "Chrooting into system"
  read -rsp 'Root password: ' rootPass
  echo ""
  arch-chroot /mnt refind-install
  systemd-nspawn -D /mnt /install/root_pass.sh "$rootPass"
  systemd-nspawn --bind /sys/firmware/efi/efivars -bD /mnt
}

function clean_install() {
  banner "Cleaning up install"
  rm -rf /mnt/install
}

############################################################################

if [[ -n "$mountOnly" ]]; then
  open_luks
  mount_volumes
  exit
fi

if [[ -z "$drive" ]]; then
  help
fi

if [[ -z "$noFormat" ]]; then
  clear_disk
fi

create_partitions
encrypt_disk
open_luks
format_partitions
create_subvolumes
mount_volumes
bootstrap_arch
setup_ansible
chroot_system
if [[ -n "$cleanInstall" ]]; then
  clean_install
fi

banner "All done, reboot system"
