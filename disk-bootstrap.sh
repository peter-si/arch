#!/usr/bin/env bash
set -e

if [[ "$EUID" -ne 0 ]]; then
  echo "Please run as root"
  exit
fi

root_pass_file="/tmp/rootPass"

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
  echo "  m - run only installation"
  echo "  n - no-format disk"
  echo "  l - ansible host for which to run this installation"
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

function ask_root_pass(){
  if [[ ! -f "$root_pass_file" ]]; then
    read -rsp 'Root password: ' rootPass
    echo ""
    echo "${rootPass}" > $root_pass_file
  fi
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
  ask_root_pass
  cryptsetup luksFormat /dev/disk/by-partlabel/cryptsystem --key-file=$root_pass_file
}

function open_luks() {
  banner "Opening luks encrypted disk"
  ask_root_pass
  cryptsetup luksOpen /dev/disk/by-partlabel/cryptsystem system --key-file=$root_pass_file
  cryptsetup plainOpen --key-file /dev/urandom /dev/disk/by-partlabel/cryptswap swap
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
  pacstrap /mnt base base-devel linux linux-firmware linux-headers git nano ansible rsync
  genfstab -L -p /mnt >>/mnt/etc/fstab
  sed -i "s+LABEL=swap+/dev/mapper/swap+" /mnt/etc/fstab
}

function install_system() {
  banner "Installing system"
  ask_root_pass
  systemd-nspawn --bind-ro=/install:/install --directory=/mnt /install/root_pass.sh "$(cat $root_pass_file)"
  systemd-nspawn \
    --as-pid2 \
    --keep-unit \
    --register=no \
    --settings=false \
    --bind-ro=/install:/install \
    --bind-ro=/proc:/proc \
    --bind-ro=/sys:/sys \
    --bind-ro=/sys/firmware/efi/efivars:/sys/firmware/efi/efivars \
    --directory=/mnt \
      ansible-playbook /install/playbook.yaml -M /install/library/ansible-aur/library -i /install/localhost -l "$host" --extra-vars "user_password=$(cat $root_pass_file)"
}

############################################################################

while getopts ":s:l:nmih" opt; do
  case "${opt}" in
  n) noFormat=true ;;
  m) mountOnly=true ;;
  i) installOnly=true ;;
  s) diskSize="+${OPTARG}" ;;
  l) host="${OPTARG}" ;;
  h) help ;;
  *)
    echo "Invalid Option: -$OPTARG" 1>&2
    help
    ;;
  esac
done
shift $((OPTIND - 1))

drive="$1"

if [[ -n "$installOnly" ]]; then
  install_system
  exit
fi

if [[ -z "$drive" ]]; then
  banner "Missing drive"
  help
fi

if [[ -n "$mountOnly" ]]; then
  open_luks
  mount_volumes
  exit
fi

if [[ -z "$host" ]]; then
  banner "Missing ansible host"
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
install_system

banner "All done, reboot system"
