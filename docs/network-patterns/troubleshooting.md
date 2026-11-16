# Pitfalls and troubleshooting

## Most frequent mistakes

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Pods on different nodes get the **same IP** | `host-local` with the same range on all nodes | Use whereabouts, or split ranges per node |
| Pod gets an IP from the pool despite `"ips"` in the annotation | NAD lacks `"capabilities": {"ips": true}` | Add the capability to the plugin that runs IPAM |
| `mac` request ignored | No plugin with `"capabilities": {"mac": true}` | Chain `tuning` with the mac capability |
| Pod reachable from the same subnet, **not from other subnets** | Asymmetric routing: replies leave via `eth0` | [sbr](routing.md#2-sbr-source-based-routing) or IPAM routes |
| ClusterIP Services stop working after `default-route` | Default route moved off `eth0`; no route for the Service CIDR | Add a route for the Service CIDR via `eth0` |
| `multus does not support ECMP for default-route` | More than one IPv4 (or IPv6) `default-route` in the pod | Keep one per address family |
| IPv6 egress breaks after an IPv4-only `default-route` | Multus removes default routes on other interfaces regardless of family | Also specify the IPv6 gateway on the chosen attachment, or use sbr |
| Node can't ping pod's `net1` (macvlan/ipvlan) | Parent ↔ child traffic is impossible by design | Host macvlan shim, or use bridge |
| macvlan works on bare metal, not in cloud/VMware | Underlay drops unknown MACs | ipvlan, or enable forged transmits / MAC learning |
| `ContainerCreating` forever, `failed to find plugin` | Plugin binary missing in `/opt/cni/bin` (or `binDir`) on that node | Install CNI plugins on every node |
| Second pod with `host-device` / `vlan` fails on the same node | Device or VLAN ID is exclusive | Use a device plugin, macvlan on a sub-interface, or bridge |
| SR-IOV pod: `no device ID` / wrong VF | NAD `resourceName` annotation doesn't match the pod's resource request | Align the resource names |
| Pod stuck with "readiness indicator file" waiting | Wrong `readinessindicatorfile` path | Fix the path or unset it |
| NAD in another namespace rejected | `namespaceIsolation: true` | Move the NAD or add the namespace to `globalNamespaces` |

## Diagnostic checklist

```bash
# 1. What does Multus think it attached?
kubectl get pod <pod> -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}' | jq

# 2. Is the NAD valid JSON and what Multus will read?
kubectl get net-attach-def <nad> -o jsonpath='{.spec.config}' | jq

# 3. Interfaces, addresses, routes, policy rules inside the pod
kubectl exec <pod> -- ip -d addr
kubectl exec <pod> -- ip route; kubectl exec <pod> -- ip rule
kubectl exec <pod> -- ip route show table all

# 4. Multus logs
#    thick: kubectl -n kube-system logs ds/kube-multus-ds
#    thin:  logFile in the multus config, or kubelet / container runtime logs
#    Set "logLevel": "debug" temporarily.

# 5. whereabouts state
kubectl get ippools.whereabouts.cni.cncf.io -A -o yaml
kubectl get overlappingrangeipreservations.whereabouts.cni.cncf.io -A
```

## Design review questions

Before shipping a NAD, answer these:
1. Who allocates IPs, and is uniqueness guaranteed **across nodes**?
2. Which interface do **replies** use? Which interface do **outbound** connections use?
3. Does the node, or anything on the host network, need to reach this interface?
4. Does the underlay accept the pod's MAC addresses?
5. What happens to the address when the pod is force-deleted or the node dies?
6. How is traffic on this interface filtered (multi-networkpolicy, firewall plugin, external)?
