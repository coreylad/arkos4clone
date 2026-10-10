# (d)ArkOS4Clone

> A custom fork for adapting the **ArkOS 4.4** and **dArkOS** image builds to
> unsupported and clone handheld devices.

This repository contains the files and scripts used to customize a source image,
including boot files, system files, device-tree selection support, and image
build tools. It is an independent community fork and is not an official ArkOS
release.

> **Important:** Device and screen compatibility depends on selecting a matching
> device tree (DTB). Back up your existing SD card before testing a new image.

## Contents

- [Build an image](#build-an-image)
- [Requirements](#requirements)
- [Flash and first boot](#flash-and-first-boot)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)

## Build an image

The build script prepares a source image, applies this repository's
customizations, and writes a compressed image to the repository directory. It
does not modify the source image.

### Option 1: Download the ArkOS source automatically

On a supported Linux host with the requirements below installed:

```sh
sudo ./build_image.sh --download
```

To keep temporary files and the cached source image outside the repository, use
a dedicated working directory on an ext4 filesystem:

```sh
sudo ./build_image.sh --download /path/to/work-directory
```

The downloaded source is cached in
`<work-directory>/source-images`. Delete the cached `.img` file there if you
want the script to download it again. Temporary download archives are removed
automatically.

### Option 2: Use a local source image

Provide an existing ArkOS or dArkOS `.img` file:

```sh
sudo ./build_image.sh /path/to/source.img /path/to/work-directory
```

The working directory is optional; by default, the script uses the source
image's directory. An ext4 filesystem is recommended for the working directory,
especially when building from WSL.

For all options and environment variables:

```sh
./build_image.sh --help
```

## Requirements

Image building is intended for Linux. The script needs root privileges, loop
device support, and permission to mount filesystems. Install the build utilities
using your distribution's package manager. On Ubuntu, the packages used by the
release build include:

```sh
sudo apt-get install \
  parted rsync xz-utils wget unzip golang-go \
  exfat-fuse exfatprogs e2fsprogs dosfstools \
  btrfs-progs f2fs-tools p7zip-full
```

The build also uses standard Linux utilities, including `losetup`, `mount`,
`umount`, `dd`, and `mkfs.exfat`. Automatic download mode specifically requires
`wget` and `7z` (`p7zip-full` on Ubuntu).

## Flash and first boot

1. Let the build finish and locate the generated `ArkOS4Clone-*.img.xz` file in
   the repository directory.
2. Decompress the `.xz` archive to get the `.img` file.
3. Use an image-writing utility to flash the image to a suitable SD card.
   Flashing erases the selected card; double-check the target device.
4. Insert the card and boot the handheld. Allow initial setup to finish before
   powering off.
5. Confirm that the selected DTB matches your device and screen. A missing boot
   logo can indicate an incompatible DTB.

Keep a backup of your working card so you can restore it if the image or DTB
does not work with your device.

## Troubleshooting

- **The screen does not show a boot logo:** Check that the selected DTB matches
  the device and panel.
- **The device worked before but no longer boots:** Disconnect and reconnect the
  battery, then try again.
- **A black screen appears after the logo:** Check the battery charge and try a
  known-good SD card before investigating further.
- **The build fails while mounting or partitioning:** Confirm that you are
  running with `sudo`, that loop devices are available, and that the working
  directory is on a filesystem that supports the required image operations.

When reporting a reproducible issue, include the image type, device, selected
DTB, build command, and relevant error output.

## Contributing

Contributions and bug reports are welcome. Please keep changes focused and
include enough detail to reproduce any reported issue.

See the [changelog](Changelog.md) for project changes and release notes.
