#!/bin/sh
# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# zram-init: configure in-guest zram swap, then exec the real kata-agent.
# Installed as /usr/bin/kata-agent; the real binary is /usr/bin/kata-agent.real.
# ateom boots init=/usr/bin/kata-agent (cloud-hypervisor >= v53). As PID 1 the agent
# mounts /proc, /sys and /dev itself, so this script mounts only /proc and /sys and
# unmounts them again before handing PID 1 to the agent. (The kernel has already
# mounted devtmpfs on /dev: CONFIG_DEVTMPFS_MOUNT=y.) It must always reach the exec:
# if PID 1 exits, the guest panics. On the systemd boot path it is not PID 1 and only
# configures zram.

ZRAM_ALGO=lz4          # lz4 | zstd
ZRAM_DISK_PCT=100      # zram disksize (uncompressed capacity), % of guest MemTotal
ZRAM_MEMLIMIT_PCT=50   # cap on guest RAM the compressed pool may use, % of MemTotal; 0 = no cap
ZRAM_SWAPPINESS=150    # 0..200; >100 prefers swapping anon to zram over dropping page cache

log() { echo "zram-init: $*" > /dev/kmsg 2>/dev/null; }

if [ "$$" -eq 1 ]; then
  mount -t proc proc /proc
  mount -t sysfs sysfs /sys
fi

Z=/sys/block/zram0
ds=x; [ -r "$Z/disksize" ] && read -r ds < "$Z/disksize"
if [ "$ds" = 0 ]; then
  mem_kb=0
  while read -r key val _; do [ "$key" = "MemTotal:" ] && mem_kb=$val; done < /proc/meminfo
  echo "$ZRAM_ALGO" > "$Z/comp_algorithm"                    # must be set before disksize
  echo "$((mem_kb * ZRAM_DISK_PCT / 100))K" > "$Z/disksize"
  [ "$ZRAM_MEMLIMIT_PCT" -gt 0 ] && echo "$((mem_kb * ZRAM_MEMLIMIT_PCT / 100))K" > "$Z/mem_limit"
  if mkswap /dev/zram0 > /dev/null 2>&1 && swapon /dev/zram0; then
    echo "$ZRAM_SWAPPINESS" > /proc/sys/vm/swappiness
    echo 0 > /proc/sys/vm/page-cluster                        # no swap readahead for zram
    log "on: MemTotal=${mem_kb}kB algo=$ZRAM_ALGO disk=${ZRAM_DISK_PCT}% limit=${ZRAM_MEMLIMIT_PCT}% swappiness=$ZRAM_SWAPPINESS"
  else
    log "swapon failed; continuing without zram"
  fi
else
  log "no unconfigured /sys/block/zram0 (disksize=$ds); continuing without zram"
fi

if [ "$$" -eq 1 ]; then
  umount /sys
  umount /proc
fi
exec /usr/bin/kata-agent.real "$@"
