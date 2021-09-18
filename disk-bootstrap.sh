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
  echo "  i - run only installation"
  echo "  n - no-format disk"
  echo "  k - add key file``"
  echo "  l - ansible host for which to run this installation"
  echo "  d - disk size for sgdisk e.g.: 200GiB"
  echo "  s - dont't create swap partition"
  echo "  c - dont't encrypt disks"

  exit
}

banner() {
  echo ""
  msg="# $* #"
  edge=$(echo "$msg" | sed 's/./#/g')
  echo "$edge"
  echo "$msg"
  echo "$edge"
  echo ""
}

function ask_root_pass(){
  if [[ ! -f "$root_pass_file" ]]; then
    echo 'Enter password for root and disk encryption:'
    read -rs rootPass
    printf "%s" "${rootPass}" > $root_pass_file
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
  sgdisk --new="$((partNum=partNum+1)):0:+550MiB" --typecode="${partNum}":ef00 --change-name="${partNum}":EFI "$drive"
  if [[ -z "$disableSwap" ]]; then
    sgdisk --new="$((partNum=partNum+1)):0:+8GiB" --typecode="${partNum}":8200 --change-name="${partNum}":"${swapLabel}" "$drive"
  fi
  sgdisk --new="$((partNum=partNum+1)):0:${diskSize:-0}" --typecode="${partNum}":8300 --change-name="${partNum}":"${systemLabel}" "$drive"
}

function encrypt_disk() {
  banner "Encrypting disk"
  partprobe "$drive"
  cryptsetup luksFormat --key-slot 9 --align-payload=8192 -s 256 -c aes-xts-plain64 --label system /dev/disk/by-partlabel/cryptsystem
}

function open_luks() {
  banner "Opening luks encrypted disk"
  cryptsetup luksOpen /dev/disk/by-partlabel/cryptsystem system
  if [[ -z "$disableSwap" ]]; then
    cryptsetup plainOpen --key-file /dev/urandom /dev/disk/by-partlabel/cryptswap swap
  fi
}

function format_partitions() {
  banner "Formatting disk"
  partprobe "$drive"
  if [[ -z "$disableSwap" ]]; then
    mkswap -L swap "${swapPath}"
    swapon -L swap
  fi
  mkfs.fat -F32 -n EFI /dev/disk/by-partlabel/EFI
  mkfs.btrfs --force --label system "${systemPath}"
}

function create_subvolumes() {
  banner "Creating subvolumes"
  mount -t btrfs LABEL=system /mnt
  btrfs subvolume create /mnt/root
  btrfs subvolume create /mnt/home
  btrfs subvolume create /mnt/snapshots
  btrfs subvolume create /mnt/lib
  umount -R /mnt
}

function mount_volumes() {
  banner "Mounting volumes"
  o=defaults,discard,x-mount.mkdir
  o_btrfs=$o,compress=lzo,ssd,space_cache,noatime
  mount -t btrfs -o subvol=root,$o_btrfs LABEL=system /mnt
  mount -t btrfs -o subvol=home,$o_btrfs LABEL=system /mnt/home
  mount -t btrfs -o subvol=snapshots,$o_btrfs LABEL=system /mnt/.snapshots
  mount -t btrfs -o subvol=lib,$o_btrfs LABEL=system /mnt/var/lib
  mount -o $o LABEL=EFI /mnt/boot
}

function bootstrap_arch() {
  banner "Bootstrapping Arch"
  pacstrap /mnt base base-devel linux linux-firmware linux-headers git nano ansible rsync
  genfstab -L -p /mnt >>/mnt/etc/fstab
}

function install_system() {
  banner "Installing system"
  systemd-nspawn --bind-ro=/install:/install --directory=/mnt /install/root-pass.sh "$(cat $root_pass_file)"
  systemd-nspawn \
    --as-pid2 \
    --register=no \
    --settings=false \
    --bind-ro=/install:/install \
    --bind-ro=/proc:/proc \
    --bind-ro=/sys:/sys \
    --bind-ro=/sys/firmware/efi/efivars:/sys/firmware/efi/efivars \
    --directory=/mnt \
      ansible-playbook /install/playbook.yaml -M /install/library/ansible-aur/library -i /install/localhost.yaml -l "$host" --skip-tags "firejail" --extra-vars "user_password=$(cat $root_pass_file) running_in_chroot=True disable_swap=${disableSwap} root_partition=${systemPath}"
}

function add_key_file() {
  dd bs=512 count=8 if=/dev/urandom of=/mnt/crypto_keyfile.bin
  cryptsetup luksAddKey /dev/disk/by-partlabel/cryptsystem /mnt/crypto_keyfile.bin
  chmod 400 /mnt/crypto_keyfile.bin
  sed -i 's/^FILES=.*/FILES=(\/crypto_keyfile.bin)/' /mnt/etc/mkinitcpio.conf
  arch-chroot /mnt mkinitcpio -P
}

############################################################################

while getopts ":d:l:nmiksch" opt; do
  case "${opt}" in
  n) noFormat=true ;;
  m) mountOnly=true ;;
  i) installOnly=true ;;
  k) addKeyFile=true ;;
  s) disableSwap=true ;;
  d) diskSize="+${OPTARG}" ;;
  l) host="${OPTARG}" ;;
  c) noEncrypt=true ;;
  h) help ;;
  *)
    echo "Invalid Option: -$OPTARG" 1>&2
    help
    ;;
  esac
done
shift $((OPTIND - 1))

drive="$1"

if [[ -z "$noEncrypt" ]]; then
  systemLabel="cryptsystem"
  systemPath=/dev/mapper/system
  swapLabel="cryptswap"
  swapPath=/dev/mapper/swap
else
  systemLabel="system"
  systemPath=/dev/disk/by-partlabel/system
  swapLabel="swap"
  swapPath=/dev/disk/by-partlabel/swap
fi

if [[ -n "$installOnly" ]]; then
  ask_root_pass
  install_system
  exit
fi

if [[ -z "$drive" ]]; then
  banner "Missing drive"
  help
fi

if [[ -n "$mountOnly" ]]; then
  if [[ -z "$noEncrypt" ]]; then
    open_luks
  fi
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
ask_root_pass
if [[ -z "$noEncrypt" ]]; then
  encrypt_disk
  open_luks
fi
format_partitions
create_subvolumes
mount_volumes
bootstrap_arch
install_system
if [[ -n "$addKeyFile" ]]; then
  add_key_file
fi

banner "All done, reboot system"
