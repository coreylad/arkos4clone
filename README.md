# (d)ArkOS 4.4 Kernel Porting for Unsupported Devices

Bringing **(d)ArkOS 4.4 kernel** porting to unsupported devices. Contributions via PRs are always welcome.

> 💡 Use the [DTB Analysis Tool](https://lcdyk0517.github.io/dtbTools.html) to identify your clone type or request support for unsupported devices.

> 🔧 Use the [DTB Customization Tool](https://lcdyk0517.github.io/tools/dtb-tools.html) to customize your device settings, including joystick axis remapping, button mapping, battery capacity, and screen refresh rate.

> ⚠️ Please make sure to read the [Wiki](https://github.com/lcdyk0517/arkos4clone/wiki) thoroughly before use.

> 📝 **[View Changelog](Changelog.md)**

---

## One-command Image Build

On a Linux host with the build dependencies installed, download the ArkOS
R35S/R36S MultiPanel source image and apply all ArkOS4Clone modifications with:

```sh
sudo ./build_image.sh --download
```

To use a dedicated working directory (an ext4 filesystem is recommended):

```sh
sudo ./build_image.sh --download /path/to/work-directory --ci
```

The download mode uses the same source as the ArkOS release workflow and needs
`wget`, `7z` (`p7zip-full` on Ubuntu), and `xz`. The normal build dependencies
include `parted`, `rsync`, `unzip`, `curl`, `python3`, `mkfs.exfat`, filesystem
utilities, and Go for the DTB selector. Root privileges and loop-device/mount
support are required.

Downloaded images are cached in `<working-directory>/source-images`; temporary
archives are cleaned up automatically. Remove the cached `.img` to download it
again. The source is preserved, and the modified, compressed image is written
to the repository directory as `ArkOS4Clone-YYYYMMDD.img.xz`.

Local ArkOS and dArkOS images remain supported:

```sh
sudo ./build_image.sh /path/to/source.img /path/to/work-directory
```

Run `./build_image.sh --help` for all options.

## Support the Project

![devices](https://r36s.dpdns.org/devices.jpg)

If you find (d)ArkOS4Clone helpful and want to support future development:

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/lcdyk)

Thank you for your support! 🙏