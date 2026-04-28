# fido2luks

This is an initramfs-tools extension to unlock LUKS-encrypted volumes at boot time using a FIDO2 token (YubiKey, Nitrokey, ...).

`fido2luks` is designed for scenarios where a FIDO2 token has been enrolled into a LUKS volume using `systemd-cryptenroll --fido2-device`, but systemd itself is not used in the initramfs.

Updated script has support for Plymouth bootsplash, has multilingual support (curently English and SLovenian language) and can supress technical/debug messages and shown only user-friendly output.

Script was tested with Yubikey 5 NFC and Nitrokey 3A Mini on Debian 13.4, however it should support any FIDO2 key.

To disable technical/debug messages (and show only messages suitable for non-tecnical users) change:

`FIDO2LUKS_DEBUG=${FIDO2LUKS_DEBUG:-1}`

to:

`FIDO2LUKS_DEBUG=${FIDO2LUKS_DEBUG:-0}`

Default language is English, you can change it to Slovenian with:

`FIDO2LUKS_LANG=${FIDO2LUKS_LANG:-sl}`

## Installation

Here's how to install `fido2luks` if it's not already available on your distro:

- Dependencies: you need `initramfs-tools`, `fido2-tools` and `jq` on your system. On Debian you can install them with: `apt install fido2-tools jq -y`.

- Install `fido2luks` using one of these options:
  1. Download a `.deb` package from the GitHub [releases](https://github.com/bertogg/fido2luks/releases) page and install it:
     ```
     wget https://github.com/bertogg/fido2luks/releases/download/v0.0.3/fido2luks_0.0.3-1_all.deb
     apt install ./fido2luks_0.0.3-1_all.deb
     ```
  2. Build your own package using the provided scripts by running `fakeroot debian/rules binary`.
  3. Simply run `make install` (this won't generate or install any `.deb` package).

Copy my patched `keyscript.sh` to `/lib/fido2luks/keyscript.sh`.

## How to use it

⚠️ **Warning**: this can render your system unbootable, so make sure that you have a backup of your files or a working initramfs that you
  can use as a fallback in case things go wrong.

1. Install FIDO2 tools:
   ```
   apt install libfido2-dev libfido2-1 fido2-tools -y
   ```
   
2. Enroll your FIDO2 token into the LUKS volume, for example, if you have `/dev/nvme0n1p5` (so called "Encrypted LVM" on Debian):
  1. `systemd-cryptenroll --fido2-device=auto --fido2-with-client-pin=true --fido2-with-user-presence=true /dev/nvme0n1p5`
  2. After that, if you run `cryptsetup luksDump /dev/nvme0n1p5` you should be able to see the `systemd-fido2` token data.

3. Edit `/etc/crypttab` and add `keyscript=/usr/lib/fido2luks/keyscript.sh` to the options of the volume that you want to unlock (for instance `nvme0n1p5_crypt`):
   ```
   sed -i \
   '/^nvme0n1p5_crypt /{
     /keyscript=/! s#$#,keyscript=/lib/fido2luks/keyscript.sh#
     s#keyscript=[^, ]*#keyscript=/lib/fido2luks/keyscript.sh#
   }' \
   /etc/crypttab
   ```

4. Generate a new initramfs with `update-initramfs -u`.

That's it. Next time you boot the system `fido2luks` should detect if your FIDO2 token is inserted and use it to unlock the LUKS volume. If the token is not detected then it will fall back to using a regular passphrase as usual.

If you have multiple tokens you can enroll all of them, and `fido2luks` will detect which one to use at boot time.

If the token is connected but not detected during boot make sure that the initramfs contains the necessary drivers. Check your `initramfs.conf` and set `MODULES=most` or add the necessary modules manually.

## Some useful commands

List FIDO tokens:
```
fido2-token -L
```

Get FIDO2 properties:
```
fido2-token -I /dev/hidraw1
```

Sets an initial FIDO2 PIN:
```
fido2-token -S /dev/hidraw1
```

Change the existing FIDO2 PIN:
```
fido2-token -C /dev/hidraw1
```

Check if FIDO2 PIN is set:
```
fido2-token -I /dev/hidraw1 | grep 'clientPin\|pin retries'
```

Sample output:
```
options: rk, up, noplat, credMgmt, clientPin, nolargeBlobs, pinUvAuthToken, makeCredUvNotRqd
pin retries: 8
```

- `clientPin`: FIDO2 PIN is configured
- `pin retries`: number of remaining PIN retries

## Important information about security

Using a FIDO2 security key with LUKS disk encryption significantly improves security. To unlock the disk, multiple factors are required:
- Something you have (the FIDO2 security key)
- Something you know (the PIN for your FIDO2 security key)
- User presence, confirmed by physically touching the key

Importantly, the PIN is verified inside the FIDO2 device itself, not by LUKS. The LUKS system never sees or stores the PIN.

However, security key can be lost, damaged, or unavailable. Also, there is a chance that kernel or initramfs updates may temporarily break FIDO2 support and in that case you will not be able to unlock the disk with FIDO2 security key. And finally, entering the wrong PIN too many times can lock the USB key.

And if the PIN becomes blocked and must be reset, the FIDO2 credentials stored on the device are typically erased. This means the associated LUKS key will no longer work.

For these reasons, it is strongly recommended to always keep a backup LUKS passphrase and, ideally, multiple FIDO2 keys (this script already supports multiple security USB keys and (multiple) LUKS passwords).

Best practice for high assurance would be:
- use 2–3 FIDO2 keys (different vendors if possible)
- strong LUKS passphrase stored securely (for instance printed and sealed somewhere)

## How this scipt works

If you are not interested in the technical details you can skip this section.

When systemd enrolls a FIDO2 token into a LUKS volume it uses an extension called hmac-secret, supported by many hardware tokens.

In a nutshell, the token calculates an HMAC using a secret that never leaves the device and a salt provided by the user. The result is sent back to the user and is used to unlock the LUKS volume.

Since nothing is stored on the hardware token itself the user needs to provide some data that is kept on the LUKS header:
- A credential ID (previously generated during the enrollment process).
- A _relying party_ ID (`io.systemd.cryptsetup` in this case).
- The aforementioned salt (which should be random and different for each LUKS volume).
- Some settings such as whether to require a PIN or presence verification (usually physically touching the USB key).

Check out the scripts in the examples/ directory to see how to generate your own credentials and secrets. See also the `fido2-cred(1)` and `fido2-assert(1)` manpages for more details.

## Credits and license

fido2luks was written by Alberto Garcia. Plymouth bootslpash patch and multilingual support was writen by Matej Kovačič. 

This program is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation; either version 2 of the License, or (at your option) any later version.
