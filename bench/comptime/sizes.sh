#!/usr/bin/env bash
# .rodata and .text of each link-size program (size.zig), in ReleaseSmall
# and ReleaseFast, and each net of `none`. Run from the repository root in
# the dev shell: bench/comptime/sizes.sh
set -euo pipefail
cd "$(dirname "$0")"
for mode in ReleaseSmall ReleaseFast; do
	zig build sizes -Doptimize="$mode" -p "zig-out/$mode"
	echo "== $mode"
	printf '%-16s %9s %9s %9s %9s\n' program rodata text +rodata +text
	read -r r0 t0 < <(size -A "zig-out/$mode/bin/size-none" | awk '$1==".rodata"{r=$2} $1==".text"{t=$2} END{print r, t}')
	for f in "zig-out/$mode"/bin/size-*; do
		read -r r t < <(size -A "$f" | awk '$1==".rodata"{r=$2} $1==".text"{t=$2} END{print r, t}')
		printf '%-16s %9d %9d %9d %9d\n' "${f##*/size-}" "$r" "$t" $((r - r0)) $((t - t0))
	done
done
