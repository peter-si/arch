#!/usr/bin/env bash

dd bs=512 count=8 if=/dev/urandom of=/crypto_keyfile.bin
cryptsetup luksAddKey /dev/disk/by-partlabel/cryptsystem /crypto_keyfile.bin
chmod 000 /crypto_keyfile.bin
sed -i 's/^FILES=.*/FILES=(\/crypto_keyfile.bin)/' /etc/mkinitcpio.conf
mkinitcpio -P
