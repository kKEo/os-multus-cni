# Tuning, MAC, MTU and bandwidth

These meta plugins are chained after the interface plugin in a conflist.

## tuning

```json
{
  "type": "tuning",
  "capabilities": { "mac": true },
  "mtu": 9000,
  "promisc": false,
  "allmulti": false,
  "sysctl": {
    "net.ipv4.conf.IFNAME.arp_ignore": "1",
    "net.ipv4.conf.IFNAME.arp_announce": "2",
    "net.ipv4.conf.IFNAME.rp_filter": "2"
  }
}
```

`IFNAME` is replaced with the actual interface name.

| Common setting | Why |
| --- | --- |
| `capabilities.mac` + `mac` in the annotation | Stable MAC for DHCP reservations, licences, ARP caches |
| `arp_ignore=1`, `arp_announce=2` | Several interfaces on overlapping L2: stop the pod answering ARP for net1's IP on eth0 and vice versa |
| `rp_filter=2` (loose) | Multi-homed pods where strict reverse-path filtering drops legitimate asymmetric traffic |
| `mtu` | Jumbo frames on storage or replication networks. Must be ≤ parent MTU |

**Pros:** small, per-attachment, declarative.
**Cons:** only namespaced sysctls (`net.*` inside the pod netns) are allowed. Some clusters restrict which sysctls are permitted (an allowlist in the tuning config or the platform).

## bandwidth

```json
{ "type": "bandwidth", "capabilities": { "bandwidth": true } }
```

Per pod: `"bandwidth": {"ingressRate": 100000000, "ingressBurst": 1000000, "egressRate": 100000000, "egressBurst": 1000000}` (bits/s, bits).

**Pros:** protects shared uplinks from a single noisy pod.
**Cons:** TBF shaping costs CPU, and ingress shaping uses an IFB device. It's coarse compared with hardware rate limits (SR-IOV `max_tx_rate`).

## MTU guidance

| Interface | Default MTU | Advice |
| --- | --- | --- |
| macvlan / ipvlan | parent MTU | Set the parent to the target MTU. The child can be smaller, never larger |
| bridge | 1500 | Set `mtu` on the bridge plugin **and** the bridge/uplink |
| SR-IOV VF | PF MTU | Configure the PF MTU (SR-IOV operator policy) |
| eth0 (overlay) | often 1450/1400 | Unrelated to secondary networks. Don't copy it |
