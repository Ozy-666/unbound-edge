# Edge network-plane tuning — FI28499 (2026-05-30)

AMD EPYC 7542 (Zen 2) KVM VPS · virtio-net `ens1` · Unbound :5353 (BoringSSL + jemalloc)

## Recon outcome (what is NOT a lever here)

| Knob | Finding | Action |
|------|---------|--------|
| RX/TX ring buffers (`ethtool -g ens1`) | current **256/256 == hardware max** | none — already maxed |
| Combined RX queues (`ethtool -l ens1`) | **4/4 == max** | none — already maxed |
| IRQ coalescing (`ethtool -c ens1`) | rx-usecs=0, rx-frames=1 (interrupt-per-pkt) | **not changed** — would trade latency for marginal gain at ~2k pps/queue; latency-sensitive resolver |
| `net.ipv4.tcp_slow_start_after_idle` | **already 0** | pinned in sysctl.d for reproducibility |

The proposed `txqueuelen` + `tcp_max_tw_buckets` changes are TCP-plane. The Unbound
workload is **UDP** DNS, which exercises neither TIME_WAIT buckets nor TCP slow-start,
so these are applied as low-risk hygiene/headroom, **not** as a softirq optimization.
No A/B flood was run — it would have measured noise. This is consistent with the prior
conclusion that the box is kernel/network-bound with large headroom not gated by these knobs.

## Persisted changes

### sysctl (survives reboot automatically)
`/etc/sysctl.d/99-edge-tuning.conf`:
```
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_max_tw_buckets = 2000000
```

### NIC txqueuelen (NOT persisted by sysctl — needs a startup hook)
Runtime command applied:
```
ip link set dev ens1 txqueuelen 10000
```
Ring buffers are already at max, so **do NOT** run `ethtool -G` (it would only reset the
NIC for zero gain).

To make txqueuelen survive reboot, this unit is **installed + enabled + active** (2026-05-30):
```ini
# /etc/systemd/system/edge-nic-tuning.service
[Unit]
Description=Edge NIC tuning (txqueuelen) for ens1
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/sbin/ip link set dev ens1 txqueuelen 10000
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```
Enable with: `systemctl daemon-reload && systemctl enable --now edge-nic-tuning.service`

## Rollback (full)
```
systemctl disable --now edge-nic-tuning.service
rm /etc/systemd/system/edge-nic-tuning.service && systemctl daemon-reload
ip link set dev ens1 txqueuelen 1000
sysctl -w net.ipv4.tcp_max_tw_buckets=32768
rm /etc/sysctl.d/99-edge-tuning.conf
```
