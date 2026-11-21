#!/bin/sh
# Run as root ON THE PHONE (over ssh): reads the touch chip's register table (PDT) straight from the I2C bus.
# Nothing is written except the chip's page-select register (set back to 0 at the end).
export DEBIAN_FRONTEND=noninteractive
if ! command -v i2cdump >/dev/null 2>&1; then
  apt-get update -qq >/dev/null 2>&1
  apt-get install -y -qq i2c-tools >/dev/null 2>&1
fi
command -v i2cdump >/dev/null 2>&1 || { echo "ERROR: i2c-tools could not be installed (no internet on the phone?)"; exit 1; }
B=3; A=0x4b
echo "== uname"; uname -r
echo "== i2c buses"; i2cdetect -l
echo "== dmesg rmi"; dmesg | grep -iE 'rmi|3-004b' | tail -20
for p in 0 1 2 3; do
  echo "== page $p, 0xa0-0xef (function table is just below 0xe9)"
  i2cset -f -y $B $A 0xff $p 2>&1
  i2cdump -f -y -r 0xa0-0xef $B $A b 2>&1
done
i2cset -f -y $B $A 0xff 0 2>&1
echo "== page 0, 0x00-0x3f"
i2cdump -f -y -r 0x00-0x3f $B $A b 2>&1
echo "== done"
