# Comparison matrix

The most commonly deployed combinations, roughly in order of how often they appear in upstream examples, ecosystem documentation and production reference designs.

## Overview

| # | Combination | Typical users | Performance | Complexity | Host ↔ pod | Works in public cloud |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | **macvlan + whereabouts** | General purpose, on-prem | High | Low–medium | No | No |
| 2 | **SR-IOV + device plugin + whereabouts/static + tuning** | Telco, NFV, HPC | Very high | High | Via NIC | Limited (cloud-specific SR-IOV) |
| 3 | **macvlan/ipvlan + whereabouts + sbr** | Multi-homed servers, network functions | High | Medium | No | ipvlan: with secondary IPs |
| 4 | **macvlan + static (+ tuning mac)** | Fixed-IP legacy integrations, StatefulSets | High | Low | No | No |
| 5 | **bridge (+vlan) + whereabouts** | KubeVirt VMs, labs, mixed VLANs | Medium | Medium | Yes | No |
| 6 | **ipvlan L2 + whereabouts/static** | Clouds, OpenStack, MAC-restricted switches | High | Low–medium | No | Yes (with IP registration) |
| 7 | **macvlan + DHCP** | Enterprises with existing DHCP/IPAM | High | Medium | No | No |
| 8 | **host-device + static** | Dedicated NIC per pod | Very high | Low (but manual) | N/A | Rare |
| 9 | **any + `default-route`** | Egress gateways, VPN/VNF | — | Medium | — | — |
| 10 | **macvlan + host-local** | Single-node, CI, demos | High | Very low | No | No |
| 11 | **SR-IOV vfio-pci (DPDK), no IPAM** | 5G UPF, packet processing | Maximum | Very high | No | Rare |
| 12 | **OVN-K / OVS secondary (layer2 / localnet)** | OpenShift and OVN-based platforms | Medium | Medium | Depends | Yes (layer2 overlay) |

## Pros and cons at a glance

### 1. macvlan + whereabouts
- ✅ Cluster-unique dynamic IPs; pods can move between nodes.
- ✅ Near-native performance and simple to understand.
- ❌ No host ↔ pod over the parent; needs MAC freedom on the underlay.
- ❌ whereabouts depends on the API server and needs a reconciler for leaks.

### 2. SR-IOV + device plugin
- ✅ Best throughput and latency; hardware VLAN, QoS and anti-spoofing.
- ✅ The scheduler accounts for VF capacity.
- ❌ Hardware, firmware and BIOS dependencies; operator stack; finite VFs.
- ❌ Bypasses host networking, so policy needs SR-IOV-aware tooling.

### 3. + sbr
- ✅ Symmetric replies for inbound traffic on secondary networks; `eth0` stays default.
- ✅ Scales to several secondary networks per pod.
- ❌ App-initiated outbound connections still use the main table unless bound to the source IP.
- ❌ Requires conflist NADs; adds `ip rule` complexity when debugging.

### 4. macvlan + static
- ✅ Deterministic IP/MAC; zero IPAM dependencies.
- ❌ Manual uniqueness; doesn't fit multi-replica Deployments.
- ❌ The `ips` / `mac` request is silently ignored without `capabilities`.

### 5. bridge (+vlan)
- ✅ Host ↔ pod works; VLAN access and trunk ports; KubeVirt-compatible.
- ❌ Bridge and uplink must be provisioned on every node; veth overhead.

### 6. ipvlan L2
- ✅ Single MAC per node, so it works behind MAC filtering.
- ❌ No DHCP; duplicate SLAAC addresses; cloud needs secondary-IP registration.

### 7. macvlan + DHCP
- ✅ Reuses enterprise DHCP, DNS and reservations.
- ❌ DHCP daemon DaemonSet; start-up latency; L2 reachability to the server.

### 8. host-device
- ✅ Any NIC, full features, no SR-IOV.
- ❌ One pod per device; scheduler-unaware without a device plugin.

### 9. default-route override
- ✅ Per-pod, no NAD change; all egress via the provider network.
- ❌ Removes **all** other default routes (both families); ClusterIP may break without explicit routes; no ECMP.

### 10. macvlan + host-local
- ✅ Zero dependencies.
- ❌ Duplicate IPs across nodes unless ranges are split per node.

## Choosing by requirement

| Requirement | Recommended combination |
| --- | --- |
| "Pods on my VLAN with dynamic IPs" | #1 macvlan + whereabouts |
| "...but I'm on AWS/Azure/GCP/OpenStack" | #6 ipvlan L2 (+ cloud IP registration) |
| "...and the node must reach the pods" | #5 bridge |
| "Line rate / DPDK" | #2 or #11 SR-IOV |
| "Pod is a server reached from routed clients on net1" | #3 + sbr |
| "Pod needs a well-known IP" | #4 static (+ tuning mac) |
| "Our network team owns DHCP" | #7 macvlan + DHCP |
| "All traffic of this pod must leave via the provider network" | #9 default-route (+ cluster routes) |
| "Dedicated NIC for one workload" | #8 host-device |
| "Quick demo on one node" | #10 macvlan + host-local |
