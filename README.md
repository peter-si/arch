# Ansible playbook to bootstrap Arch linux


This is an [Ansible][1] playbook meant to provision a personal machine running
[Arch Linux][2]. It is intended to run locally on a fresh Arch install (ie,
taking the place of any [post-installation][3]), but due to Ansible's
idempotent nature it may also be run on top of an already configured machine. 
Contains `disk-bootstrap.sh` which will partition given disk, encrypt and bootstrap 
btrfs with snapshots. Then you can run this ansible playbook to install Arch linux ready to use.

**Note:** If you would like to try recreating all the tasks that are currently
included in the ansible playbook, through a VM, you would need a disk of at least
**16GB** in size.

For best experience this should be added to live usb

```bash
cp -r /usr/share/archiso/configs/releng ~/archlive
git clone git@github.com:peter-si/arch-ansible.git ~/archlive/airootfs/install
cd ~/archlive/airootfs/install && git submodule update --recursive --remote && cd ~
sudo mkarchiso -v -w /tmp/archiso-tmp ~/archlive
sudo dd bs=4M if="location of iso" of=/dev/sdd status=progress oflag=sync
```

You should also add .ssh folder with keys to download dotfiles. These will be automatically installed on new pc

```bash
cp -r ~/.ssh ~/archlive/airootfs/install
```

**Note:** Don't leave your unencrypted private keys in live usb

## Running

If you are on wifi connect to internet via `iwctl`

```iwctl
station wlan0 connect name_of_network
```

Copy your `.ssh` folder to `/install`

```bash
cp -r /media/location/.ssh /install
```

Navigate to `/install` and set up disks with following command (and follow prompts)

```bash
./disk-bootstrap.sh /dev/sdX 
```

Once installed you will be in `systemd-nspawn` system. Right now `chpasswd` is not working, so we have to set up password manually. Run following commands to get to correct nspawn container:

```bash
passwd
logout
```

Once inside navigate to `/install` and run ansible playbook as root.

```bash
ansible-playbook -i pc -l desktop playbook.yaml
```
Or
```bash
ansible-playbook -i laptop -l asus playbook.yaml
```

When run, Ansible will prompt for the user password. This only needs to be
provided on the first run when the user is being created. On later runs,
providing any password -- whether the current user password or a new one --
will have no effect.

This will bootstrap installation with dotfiles and necessary configs. If it is done, you can `poweroff` nspawn container.

We have to regenerate bootloader

```bash
refind-install
```

After this you can reboot into system a finish installation

### Finishing installation

If needed connect to wifi using

```bash
nmcli d wifi c name_of_network password SecretPassword
```

To [check iptables dropped packets](https://wiki.archlinux.org/index.php/iptables#Logging) use

```bash
journalctl -k | grep "IN=.*OUT=.*" | less
```


## SSH

By default, Ansible will attempt to install the private SSH key for the user. The
key should be available at the path specified in the `ssh.user_key` variable.
Removing this variable will cause the key installation task to be skipped.

### SSHD

If `ssh.enable_sshd` is set to `True` the [systemd socket service][4] will be
enabled. By default, sshd is configured but not enabled.

## Dotfiles

Ansible expects that the user wishes to clone dotfiles via the git repository
specified via the `dotfiles.url` variable and install them with [rcm][5]. The
destination to clone the repository to is defined by the `dotfiles.destination`
variable. This is relative the user's home directory.

These tasks will be skipped if the `dotfiles` variable is not defined.

## Tagging

All tasks are tagged with their role, allowing them to be skipped by tag in
addition to modifying `playbook.yml`.

## AUR

All tasks involving the [AUR][6] are tagged `aur`. To provision an AUR-free
system, pass this tag to ansible's `--skip-tag`.

AUR packages are installed via the [ansible-aur][7] module. Note that while
[yay][8], an [AUR helper][9], is installed by default, it will *not* be used
during any of the provisioning.

## Firejail

Many applications are sandboxed with [Firejail][10]. This behavior should be
largely invisible to the user.

Custom security profiles are provided for certain applications. These are
installed to `/usr/local/etc/firejail`. Firejail does not look in this
directory by default. To use the security profiles, they must either be
specified on the command-line or included in an appropriately named profile
located in `~/.config/firejail`.

    # Example 1:
    # Launch Firefox using the custom profile by specifying the full path of the profile.
    $ firejail --profile=/usr/local/etc/firejail/firefox.profile /usr/bin/firefox
    # Example 2:
    # Launch Firefox using the custom profile by specifying its directory.
    $ firejail --profile-path=/usr/local/etc/firejail /usr/bin/firefox
    # Example 3:
    # Include the profile  in ~./config/firejail
    $ mkdir -p ~/.config/firejail
    $ echo 'include /usr/local/etc/firejail/firefox.profile' > ~/.config/firejail/firefox.profile
    $ firejail /usr/bin/firefox

The script `profile-activate` is provided to automatically include the profiles
when appropriate. For every profile located in `/usr/local/etc/firejail`, the
script looks for a profile with the same name in `~/.config/firejail`. If one
is not found, it will create a profile that simply includes the system profile,
as in the third example above. It will not modify any existing user profiles.

### Blacklisting

The `firejail.blacklist` variable is used to populate
`/etc/firejail/globals.local` with a list of blacklisted files and directories.
This file is included by all security profiles, causing the specified locations
to be inaccessible to jailed programs.

## MAC Spoofing

By default, the MAC address of all network interfaces is spoofed at boot,
before any network services are brought up. This is done with [macchiato][11],
which uses legitimate OUI prefixes to make the spoofing less recognizable.

MAC spoofing is desirable for greater privacy on public networks, but may be
inconvenient on home or corporate networks where a consistent (if not real) MAC
address is wanted for authentication. To work around this, allow `macchiato` to
randomize the MAC on boot, but tell NetworkManager to clone the real (or a fake
but consistent) MAC address in its profile for the trusted networks. This can
be done in the GUI by populating the "Cloned MAC address" field for the
appropriate profiles, or by setting the `cloned-mac-address` property in the
profile file at `/etc/NetworkManager/system-connections/`.

Spoofing may be disabled entirely by setting the `network.spoof_mac` variable
to `False`.

## Trusted Networks

The trusted network framework provided by [nmtrust][12] is leveraged to start
certain systemd units when connected to trusted networks, and stop them
elsewhere.

This helps to avoid leaking personal information on untrusted networks by
ensuring that certain network tasks are not running in the background.
Currently, this is used for mail syncing (see the section below on Syncing and
Scheduling Mail), Tarsnap backups (see the section below on Scheduling
Tarsnap), BitlBee (see the section below on BitlBee), and git-annex (see the
section below on git-annex).

Trusted networks are defined using their NetworkManager UUIDs, configured in
the `network.trusted_uuid` list. NetworkManager UUIDs may be discovered using
`nmcli con`.

## Tor

[Tor][23] is installed by default. A systemd service unit for Tor is installed,
but not enabled or started. instead, the service is added to
`/etc/nmtrust/trusted_units`, causing the NetworkManager trusted unit
dispatcher to activate the service whenever a connection is established to a
trusted network. The service is stopped whenever the network goes down or a
connection is established to an untrusted network.

To have the service activated at boot, change the `tor.run_on` variable
from `trusted` to `all`.

If you do not wish to use Tor, simply remove the `tor` variable from the
configuration.

### parcimonie.sh

[parcimonie.sh][24] is provided to periodically refresh entries in the user's
GnuPG keyring over the Tor network. The service is added to
`/etc/nmtrust/trusted_units` and respects the `tor.run_on` variable.



[1]: http://www.ansible.com
[2]: https://www.archlinux.org
[3]: https://wiki.archlinux.org/index.php/Installation_guide#Post-installation
[4]: https://wiki.archlinux.org/index.php/Secure_Shell#Managing_the_sshd_daemon
[5]: https://thoughtbot.github.io/rcm/
[6]: https://aur.archlinux.org
[7]: https://github.com/pigmonkey/ansible-aur
[8]: https://github.com/Jguer/yay
[9]: https://wiki.archlinux.org/index.php/AUR_helpers
[10]: https://firejail.wordpress.com/
[11]: https://github.com/EtiennePerot/macchiato
[12]: https://github.com/pigmonkey/nmtrust
[23]: https://www.torproject.org/
[24]: https://github.com/EtiennePerot/parcimonie.sh
