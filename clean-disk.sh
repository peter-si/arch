#!/usr/bin/env bash

umount -R /mnt
swapoff /dev/mapper/swap
cryptsetup close /dev/mapper/swap
cryptsetup close /dev/mapper/system

