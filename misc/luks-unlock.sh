#!/bin/sh

PASSKEY=Super_Sec-ret_pass_worD_or_anything
echo "Unlock encrypted luks drive"
read -sp 'Your Passkey: ' passvar
echo ""
encryptedDrives=("/dev/sda2 sda2-crypt" "/dev/md0 md0-crypt")

for i in ${!encryptedDrives[@]};
do
  drive=${encryptedDrives[$i]}
  # cryptsetup luksOpen /dev/* *-crypt
  echo -n $passvar | cryptsetup luksOpen $drive;
done

vgchange -a y ssd_crypt
vgchange -a y raid_crypt
mount -a

