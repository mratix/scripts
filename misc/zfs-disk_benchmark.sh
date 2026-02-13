#!/bin/bash

echo "zfs Disk Performance Benchmark"
sudo -i

echo "Flush buffers or disk caches (read from the disk, not the buffer)"
#echo 3 | sudo tee /proc/sys/vm/drop_caches
echo 3 > /proc/sys/vm/drop_caches
for disk in /dev/sd?; do; hdparm -Ttv $disk; done

#/dev/sda:
# multcount     =  8 (on)
# IO_support    =  0 (default)
# readonly      =  0 (off)
# readahead     = 256 (on)
# geometry      = 121601/255/63, sectors = 1953525168, start = 0
# Timing cached reads:   22726 MB in  1.99 seconds = 11430.90 MB/sec
# Timing buffered disk reads:  86 MB in  3.07 seconds =  28.06 MB/sec

#/dev/sdb:
# multcount     =  8 (on)
# IO_support    =  0 (default)
# readonly      =  0 (off)
# readahead     = 256 (on)
# geometry      = 121601/255/63, sectors = 1953525168, start = 0
# Timing cached reads:   23126 MB in  1.99 seconds = 11632.56 MB/sec
# Timing buffered disk reads:  72 MB in  3.04 seconds =  23.66 MB/sec

#/dev/sdc:
# multcount     =  8 (on)
# IO_support    =  0 (default)
# readonly      =  0 (off)
# readahead     = 256 (on)
# geometry      = 121601/255/63, sectors = 1953525168, start = 0
# Timing cached reads:   23464 MB in  1.99 seconds = 11803.96 MB/sec
# Timing buffered disk reads: 112 MB in  3.06 seconds =  36.60 MB/sec

#/dev/sdd: ssd500
# multcount     =  1 (on)
# IO_support    =  1 (32-bit)
# readonly      =  0 (off)
# readahead     = 256 (on)
# geometry      = 60801/255/63, sectors = 976773168, start = 0
# Timing cached reads:   23814 MB in  1.99 seconds = 11982.10 MB/sec
# Timing buffered disk reads: 630 MB in  3.00 seconds = 209.81 MB/sec

#/dev/sde:
# multcount     =  8 (on)
# IO_support    =  0 (default)
# readonly      =  0 (off)
# readahead     = 256 (on)
# geometry      = 243201/255/63, sectors = 3907029168, start = 0
# Timing cached reads:   22444 MB in  1.99 seconds = 11288.25 MB/sec
# Timing buffered disk reads: 144 MB in  3.02 seconds =  47.63 MB/sec

#/dev/sdf: usb2000bak
# multcount     =  0 (off)
# readonly      =  0 (off)
# readahead     = 256 (on)
# geometry      = 243201/255/63, sectors = 3907029167, start = 0
# Timing cached reads:   23786 MB in  1.99 seconds = 11969.01 MB/sec
# Timing buffered disk reads: 344 MB in  3.01 seconds = 114.35 MB/sec

echo "Get drive write-caching flag (0/1)"
for disk in /dev/sd?; do; hdparm -W $disk; done

#enabled write-caching
#	sda	WD-WCC4J6ZC5EDN	931.51 GiB	tank
#	sdb	WD-WCC4J3ADUDEJ	931.51 GiB	tank
#	sdc	WD-WCC4J4EDC7D1	931.51 GiB	tank
#	sde	WD-WMC5D0D5HYDR	1.82 TiB	tank    CMR oder SMR?
#hdparm -W 1 /dev/sda
#hdparm -W 1 /dev/sdb
#hdparm -W 1 /dev/sdc
#hdparm -W 1 /dev/sde

#/dev/sda:
# write-caching =  1 (on)
#/dev/sdb:
# write-caching =  1 (on)
#/dev/sdc:
# write-caching =  1 (on)
#/dev/sdd:   ssd500
# write-caching =  0 (off)
#/dev/sde:
# write-caching =  1 (on)
#/dev/sdf: usb2000bak
# write-caching = not supported

echo "Flush buffers or disk caches (read from the disk, not the buffer)"
echo 3 > /proc/sys/vm/drop_caches

echo "Testing 1GB Sequential Write Speed"
dd if=/dev/zero of=/tmp/testfile bs=1M count=1024 conv=fdatasync
#1024+0 records in
#1024+0 records out
#1073741824 bytes (1.1 GB, 1.0 GiB) copied, 0.384228 s, 2.8 GB/s

echo "Flush buffers or disk caches (read from the disk, not the buffer)"
echo 3 > /proc/sys/vm/drop_caches

echo "Testing 1GB Sequential Read Speed"
dd if=/tmp/testfile of=/dev/null bs=1M count=1024
#1024+0 records in
#1024+0 records out
#1073741824 bytes (1.1 GB, 1.0 GiB) copied, 0.174944 s, 6.1 GB/s

echo "Rerun the previous test and observe the speed of reading from the buffer cache"
dd if=/tmp/testfile of=/dev/null bs=1M count=1024
#1024+0 records in
#1024+0 records out
#1073741824 bytes (1.1 GB, 1.0 GiB) copied, 0.134549 s, 8.0 GB/s

rm -v /tmp/testfile


echo "Testing 1GB Durchsatz (Streaming I/O)"
dd if=/dev/zero of=/mnt/tank/testfile bs=1G count=1 oflag=dsync
#1+0 records in
#1+0 records out
#1073741824 bytes (1.1 GB, 1.0 GiB) copied, 1.8878 s, 569 MB/s

echo "Testing 1GB Random Write Operation"
dd if=/dev/random of=/mnt/tank/testfile bs=1M count=1000 oflag=dsync
#1000+0 records in
#1000+0 records out
#1048576000 bytes (1.0 GB, 1000 MiB) copied, 153.289 s, 6.8 MB/s

echo "Testing Controller Latenz"
dd if=/dev/zero of=/mnt/tank/testfile bs=512 count=1000 oflag=dsync
#1000+0 records in
#1000+0 records out
#512000 bytes (512 kB, 500 KiB) copied, 69.0377 s, 7.4 kB/s

rm -v /mnt/tank/testfile

