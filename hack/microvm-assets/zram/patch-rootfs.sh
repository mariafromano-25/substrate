#!/usr/bin/env bash
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

# Patch the stock Kata rootfs image with the zram init wrapper, without root:
# extract partition 1, edit it with debugfs, check it with e2fsck, write it back.
set -euo pipefail

STOCK="${1:?usage: patch-rootfs.sh STOCK_IMG OUT_IMG WRAPPER}"
OUT="${2:?}"
WRAPPER="${3:?}"
P1="$(mktemp /tmp/zram-p1.XXXXXX.ext4)"
trap 'rm -f "$P1"' EXIT

cp "$STOCK" "$OUT"
START=$(sfdisk -J "$OUT" | jq '.partitiontable.partitions[0].start')
SIZE=$(sfdisk -J "$OUT" | jq '.partitiontable.partitions[0].size')
echo "partition 1: start=$START size=$SIZE sectors"
dd if="$OUT" of="$P1" bs=512 skip="$START" count="$SIZE" status=none

/usr/sbin/debugfs -w -f - "$P1" <<EOF
ln /usr/bin/kata-agent /usr/bin/kata-agent.real
unlink /usr/bin/kata-agent
write $WRAPPER /usr/bin/kata-agent
sif /usr/bin/kata-agent mode 0100755
sif /usr/bin/kata-agent uid 0
sif /usr/bin/kata-agent gid 0
EOF

echo "--- e2fsck (read-only) ---"
/usr/sbin/e2fsck -fn "$P1"

echo "--- verify ---"
for f in /usr/bin/kata-agent /usr/bin/kata-agent.real; do
  /usr/sbin/debugfs -R "stat $f" "$P1" 2>/dev/null | sed -n '1,2p'
done
/usr/sbin/debugfs -R "cat /usr/bin/kata-agent" "$P1" 2>/dev/null | head -3
/usr/sbin/debugfs -R "cat /usr/bin/kata-agent" "$P1" 2>/dev/null | cmp - "$WRAPPER" && echo "wrapper content matches"

dd if="$P1" of="$OUT" bs=512 seek="$START" conv=notrunc status=none
echo "patched: $OUT"
sha256sum "$OUT"
