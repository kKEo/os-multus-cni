# ipvlan patterns

ipvlan creates child interfaces that **share the parent's MAC address** and are distinguished by IP. It is the usual replacement for macvlan in environments that drop unknown MACs.

## Modes

| Mode | Behaviour | ARP/broadcast | Typical use |
| --- | --- | --- | --- |
| `l2` (default) | Children are on the parent's L2 segment | Yes | Drop-in macvlan replacement in clouds or OpenStack |
| `l3` | Parent routes for children; no broadcast or multicast | No | Routed designs; the upstream router needs routes to the pod IPs via the node |
| `l3s` | Like `l3`, but traffic passes through netfilter (conntrack, iptables) | No | When you need host firewalling on the traffic |

## Combination: ipvlan L2 + whereabouts

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: ipvlan-l2
spec:
  config: '{
    "cniVersion": "0.4.0",
    "type": "ipvlan",
    "master": "eth1",
    "mode": "l2",
    "ipam": {
      "type": "whereabouts",
      "range": "10.30.0.0/24",
      "gateway": "10.30.0.1"
    }
  }'
```

**Pros**
- Works where macvlan doesn't: public cloud VMs (with the secondary IPs registered on the cloud NIC), OpenStack with port security, and switches that limit MACs per port.
- Lower MAC-table pressure on the switch.
- Similar performance to macvlan.

**Cons**
- All pods on a node share one MAC, so **DHCP is impractical**, because many servers key leases on MAC. Use whereabouts or static.
- No host ↔ pod traffic over the parent, the same as macvlan.
- In clouds you still have to register each pod IP as a secondary IP on the VM's NIC, or the VPC drops it. That usually needs an operator or a cloud-specific CNI.
- IPv6 SLAAC and EUI-64 addressing produce duplicate interface IDs.
- A single parent can't have macvlan and ipvlan children at the same time.

## Combination: ipvlan L3 + static routes upstream

This is used when the secondary network is routed, not bridged. Each node advertises or is configured with routes to the pod IPs on that node.

**Pros:** no broadcast domain, so it scales well and fits leaf-spine designs.
**Cons:** someone must program upstream routes, for example BGP from the node or static routes per node. There is no ARP, so peers on the same subnet cannot reach pods without a route.

## When to pick ipvlan over macvlan

| Condition | Pick |
| --- | --- |
| Underlay drops unknown MACs (cloud, port security, Wi-Fi) | ipvlan |
| Switch has strict MAC-per-port limits and many pods per node | ipvlan |
| You need DHCP or per-pod MAC identity | macvlan |
| You need multicast/broadcast-heavy protocols (VRRP, some discovery protocols) | macvlan (or ipvlan L2 with care) |
