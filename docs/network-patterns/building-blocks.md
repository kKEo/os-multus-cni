# Building blocks

A secondary network is assembled from three layers. This page is a reference for each layer; the pattern pages show how they are combined.

## 1. Interface plugins

| Plugin | What it creates in the pod | Host ↔ pod traffic | Needs per-port MAC freedom | Typical use |
| --- | --- | --- | --- | --- |
| `macvlan` | A virtual interface with its **own MAC**, attached to a parent NIC | **No** (parent cannot talk to its macvlan children) | Yes | Pods directly on an existing L2 network |
| `ipvlan` | A virtual interface that **shares the parent's MAC** | **No** in L2 mode | No | Cloud VMs, OpenStack, switches with port security |
| `bridge` | A veth pair plugged into a Linux bridge on the node | Yes | Yes (if bridge is enslaved to an uplink) | KubeVirt, labs, node-local networks, VLAN trunks |
| `vlan` | An 802.1Q sub-interface of a parent NIC | No | No (single MAC per VLAN subif) | Direct VLAN attachment without a bridge |
| `host-device` | Moves an **existing** host device (NIC, VF, macvlan) into the pod | N/A (device leaves the host) | N/A | Dedicated NIC per pod |
| `sriov` | Moves an SR-IOV **Virtual Function** into the pod (kernel or DPDK) | Via the NIC's embedded switch | No | Telco, high throughput, low latency |
| `ovs` / OVN-Kubernetes secondary | Port on an Open vSwitch bridge, or OVN logical switch | Depends | No | SDN-managed secondary networks |
| `ib-sriov` | InfiniBand VF | — | — | HPC / RDMA |

## 2. IPAM plugins

| IPAM | Scope of uniqueness | State | Pros | Cons |
| --- | --- | --- | --- | --- |
| `host-local` | **Per node only** | Files on the node (`/var/lib/cni/networks`) | Built in, no dependencies, fast | Same range on two nodes ⇒ **duplicate IPs**. Must split ranges per node manually. |
| `whereabouts` | **Cluster-wide** | Kubernetes CRDs (`IPPool`, `OverlappingRangeIPReservation`) | Unique IPs across nodes, exclusions, IPv6, overlapping-range protection | Extra component; API-server dependency on pod creation; stale reservations need the reconciler |
| `static` | Whatever you assign | None | Deterministic, ideal for fixed-IP services; combines with `"ips"` capability for per-pod IPs | You manage uniqueness; no pool, no conflict detection |
| `dhcp` | The external DHCP server | DHCP daemon on each node (`/opt/cni/bin/dhcp daemon`) | Integrates with existing IPAM/DNS/DHCP infrastructure | Daemon must run on every node; lease renewal depends on it; does not work well with ipvlan (shared MAC) |
| none / `""` | — | — | For L2-only or DPDK interfaces | No IP; the application configures addressing |
| Vendor (e.g. `nv-ipam`, OVN-K managed) | Varies | Varies | Integrated with a specific stack | Vendor lock-in |

### Requesting a specific IP/MAC per pod

Multus forwards these fields from the pod annotation (the JSON form of `k8s.v1.cni.cncf.io/networks`) into CNI `runtimeConfig`:

| Annotation field | Runtime config key | Who consumes it | Capability that must be declared in the NAD |
| --- | --- | --- | --- |
| `ips` | `ips` | `static` IPAM (and whereabouts in recent versions) | `"capabilities": {"ips": true}` |
| `mac` | `mac` | `tuning` (and some interface plugins) | `"capabilities": {"mac": true}` |
| `infiniband-guid` | `infinibandGUID` | `ib-sriov` | `"capabilities": {"infinibandGUID": true}` |
| `bandwidth` | `bandwidth` | `bandwidth` | `"capabilities": {"bandwidth": true}` |
| `portMappings` | `portMappings` | `portmap` | `"capabilities": {"portMappings": true}` |
| `deviceID` | `deviceID` | `sriov`, `host-device` | set automatically from the device plugin |
| `interface` | — (sets `CNI_IFNAME`) | all | none |
| `default-route` | — (Multus manipulates routes itself) | Multus | none |
| `cni-args` | injected into `args.cni` of the config | plugins that read `args.cni` | none |

> **Important:** `libcni` passes a runtime-config key to a plugin **only if that plugin declares the capability**. If the pod asks for `"ips"` but the NAD does not declare `"capabilities": {"ips": true}`, the request is silently ignored and IPAM allocates as usual.

## 3. Meta (chained) plugins

These run after the interface plugin inside a conflist (`"plugins": [ ... ]`) and modify the result.

| Plugin | Purpose | Typical reason to add it |
| --- | --- | --- |
| `sbr` | Source-based routing: moves the interface's routes into a dedicated table and adds a `from <ip> lookup <table>` rule | Reply traffic must leave via the interface it arrived on; avoids `rp_filter` drops and asymmetric routing |
| `route-override` | Add, delete or flush routes/gateway produced by IPAM | Fine-grained route control without code changes |
| `tuning` | Set sysctls, MAC, MTU, promiscuous mode, allmulticast | Per-attachment sysctls (`arp_ignore`, `rp_filter`), deterministic MAC |
| `bandwidth` | Ingress/egress shaping using TBF | Prevent a pod saturating a shared uplink |
| `portmap` | hostPort NAT | Rare on secondary networks |
| `vrf` | Puts the interface into a VRF | Overlapping subnets across attachments; stronger isolation than sbr |
| `firewall` | iptables rules for the interface | Simple ingress filtering without multi-networkpolicy |

## Network selection annotation fields

```yaml
k8s.v1.cni.cncf.io/networks: |
  [{
    "name": "macvlan-net",          # NAD name (required)
    "namespace": "infra",           # NAD namespace (default: pod namespace)
    "interface": "data0",           # interface name in the pod (default: net1, net2, ...)
    "ips": ["10.10.0.15/24"],       # needs "ips" capability
    "mac": "02:00:00:aa:bb:cc",     # needs "mac" capability
    "default-route": ["10.10.0.1"], # make this attachment the default gateway
    "bandwidth": {"ingressRate": 100000000, "ingressBurst": 1000000,
                  "egressRate": 100000000,  "egressBurst": 1000000},
    "cni-args": {"foo": "bar"}      # merged into args.cni
  }]
```

The short text form `infra/macvlan-net@data0` covers the namespace, name and interface fields.
