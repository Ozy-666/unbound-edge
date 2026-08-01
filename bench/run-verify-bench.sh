#!/bin/bash
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Ozy-666 (https://dnsdoh.art)
#
# run-verify-bench.sh — A/B two BoringSSL builds on DNSSEC verification.
#
# unbound-update.sh tells you to re-measure after bumping /opt/boring, because
# BoringSSL was chosen on measured performance rather than assumed parity.
# This is the tool for that. It builds dnssec-verify-bench.c once per library
# prefix and runs the two binaries INTERLEAVED, so CPU frequency drift and
# background load land on both equally instead of on whichever ran second.
#
# A single round is not evidence: on a live box the run-to-run spread is a few
# percent, which is larger than the difference usually being looked for. The
# default of 8 paired rounds is the point of reporting a median and a win count
# rather than one number.
#
# Usage:
#   ./run-verify-bench.sh <old-prefix> <new-prefix> [rounds] [iters]
#   ./run-verify-bench.sh /opt/boring.bak.20260801_1118 /opt/boring
#
# Each prefix must contain include/ and lib/ from that BoringSSL build. The
# unbound-update.sh BoringSSL bump leaves the previous one in
# /opt/boring.bak.<timestamp>, which is exactly what to pass as <old-prefix>.
set -e

OLD="${1:?usage: $0 <old-prefix> <new-prefix> [rounds] [iters]}"
NEW="${2:?usage: $0 <old-prefix> <new-prefix> [rounds] [iters]}"
ROUNDS="${3:-8}"
ITERS="${4:-30000}"

cd "$(dirname "$0")"
for p in "$OLD" "$NEW"; do
    [ -d "$p/include" ] && [ -d "$p/lib" ] || { echo "missing include/ or lib/ in $p" >&2; exit 1; }
done

for v in old new; do
    p=$([ "$v" = old ] && echo "$OLD" || echo "$NEW")
    gcc -O2 dnssec-verify-bench.c -o "bench-$v" \
        -I"$p/include" -L"$p/lib" -lcrypto -Wl,-rpath,"$p/lib"
    # Prove the binary loads the library it was built for, not the system one.
    ldd "./bench-$v" | grep -q "$p/lib/libcrypto.so" \
        || { echo "bench-$v does not load $p/lib/libcrypto.so" >&2; exit 1; }
done
echo "old = $OLD ($(cat "$OLD/COMMIT" 2>/dev/null || echo '?'))"
echo "new = $NEW ($(cat "$NEW/COMMIT" 2>/dev/null || echo '?'))"
echo "$ROUNDS paired rounds, $ITERS iterations each"
echo

# Pin to one core so the two builds are not scheduled against different
# neighbours mid-run.
CORE=$(( $(nproc) - 1 ))
RAW=$(mktemp)
trap 'rm -f "$RAW"' EXIT
for _ in $(seq 1 "$ROUNDS"); do
    for v in old new; do
        taskset -c "$CORE" "./bench-$v" "$ITERS" | sed "s/^/${v}\t/" >> "$RAW"
    done
done

python3 - "$RAW" <<'PY'
import re, sys, statistics as st, collections
rows = collections.defaultdict(lambda: collections.defaultdict(list))
pat = re.compile(r'^(old|new)\t(.+?\))\s+(\d+)\s+([\d.]+)$')
for line in open(sys.argv[1]):
    m = pat.match(line.rstrip())
    if m:
        rows[m.group(2).strip()][m.group(1)].append(float(m.group(3)))

print(f"{'primitive':<38}{'old med':>9}{'new med':>9}{'delta':>8}{'new wins':>10}")
print("-" * 74)
verdicts = []
for prim, d in rows.items():
    o, n = d['old'], d['new']
    om, nm = st.median(o), st.median(n)
    delta = (nm - om) / om * 100
    wins = sum(1 for a, b in zip(o, n) if b > a)
    print(f"{prim:<38}{om:>9.0f}{nm:>9.0f}{delta:>7.1f}%{f'{wins}/{len(o)}':>10}")
    verdicts.append(delta)

worst = min(verdicts)
print()
if worst < -3:
    print(f"REGRESSION: worst primitive is {worst:.1f}% slower. Investigate before")
    print("keeping this build; unbound-update.sh prints the /opt/boring rollback.")
    sys.exit(1)
if worst < -1:
    print(f"NO REGRESSION: worst primitive is {worst:+.1f}%, inside the ~1-2% run-to-run")
    print("spread on a live box. Raise the round count if you want a tighter bound.")
else:
    print(f"PARITY OR BETTER: worst primitive is {worst:+.1f}%.")
PY
