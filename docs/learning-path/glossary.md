# Glossary and cheat sheet

A reference to keep open while you follow the [learning path](README.md). The first half explains the words; the second half lists the commands, annotations and paths you will use most.

## Glossary

| Term | Meaning |
| --- | --- |
| **Attachment** | One extra interface in a pod, created from one NetworkAttachmentDefinition. Also called a secondary network attachment |
| **Capability** | A per-pod value, such as `ips` or `mac`, that a plugin declares it accepts with `"capabilities": {...}`. Undeclared values are not passed to the plugin |
| **Cluster network** | The network that implements the Kubernetes network model and provides `eth0` and the pod IP. Same as *default network* |
| **CNI** | Container Network Interface: the contract between a container runtime and the executables that set up pod networking |
| **CNI plugin** | An executable, usually in `/opt/cni/bin`, that implements the CNI verbs `ADD`, `DEL` and `CHECK` |
| **conf / conflist** | A CNI configuration with one plugin (`.conf`) or a chain of plugins (`.conflist`, with a `plugins` array) |
| **Default network** | See *cluster network*. In the Multus configuration it is set with `clusterNetwork` |
| **`defaultNetworks`** | A Multus option that attaches extra NADs to every pod, without an annotation |
| **Delegate** | A CNI plugin configuration that Multus invokes. The default network is the first delegate; each attachment adds one |
| **Device plugin** | A Kubernetes component that advertises hardware, such as SR-IOV Virtual Functions, as schedulable resources. Multus passes the allocated device to the delegate |
| **DRA** | Dynamic Resource Allocation: the newer Kubernetes API for requesting devices. Multus can read device IDs from resource claims |
| **Interface plugin** | A plugin that creates the interface: `macvlan`, `ipvlan`, `bridge`, `sriov`, `host-device`, ... Also called a main plugin |
| **IPAM plugin** | A plugin that allocates addresses for an interface plugin: `host-local`, `whereabouts`, `static`, `dhcp` |
| **Master plugin** | The code's name for the delegate of the default network. Its result is returned to the container runtime |
| **Meta plugin** | A plugin that calls or modifies other plugins. Multus is one; so are chained plugins such as `tuning`, `sbr` and `portmap` |
| **Multi-homed pod** | A pod with more than one network interface besides loopback |
| **NAD** | NetworkAttachmentDefinition: a namespaced custom resource that stores one CNI configuration under a name |
| **Network selection annotation** | `k8s.v1.cni.cncf.io/networks` on a pod: the list of NADs to attach |
| **Network status annotation** | `k8s.v1.cni.cncf.io/network-status` on a pod: what Multus attached, written by Multus |
| **NPWG** | The Kubernetes Network Plumbing Working Group, which defines the NAD and the annotations in its multi-network specification |
| **Secondary network** | Any network attached in addition to the default network. Kubernetes Services, probes and NetworkPolicy do not use it |
| **Shim** | `multus-shim`, the small binary the runtime executes in a thick deployment. It forwards each request to the daemon |
| **Thick plugin** | The client and server deployment: `multus-shim` on the node, `multus-daemon` in a pod |
| **Thin plugin** | The single-binary deployment: the runtime executes `multus`, which does all the work in that process |

## Annotations

| Annotation | On | Written by | Purpose |
| --- | --- | --- | --- |
| `k8s.v1.cni.cncf.io/networks` | Pod | You | Which NADs to attach |
| `k8s.v1.cni.cncf.io/network-status` | Pod | Multus | What was attached: interface, IPs, MAC per network |
| `v1.multus-cni.io/default-network` | Pod | You | Replace the default network for this pod |
| `k8s.v1.cni.cncf.io/resourceName` | NAD | You | The device plugin resource whose devices this network uses |

Forms of the network selection annotation:

```yaml
# Text: name, namespace/name, name@interface, comma-separated
k8s.v1.cni.cncf.io/networks: lab-net, storage/fast@data0

# JSON: one object per attachment, for per-pod values
k8s.v1.cni.cncf.io/networks: '[{ "name": "lab-static", "ips": ["10.20.0.11/24"] }]'
```

## Commands

```bash
# NetworkAttachmentDefinitions (short names: nad, net-attach-def)
kubectl get net-attach-def -A
kubectl get nad <name> -o jsonpath='{.spec.config}' | jq

# What Multus attached to a pod
kubectl get pod <pod> -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}' | jq
kubectl describe pod <pod>          # annotations and AddedInterface events

# Inside the pod
kubectl exec <pod> -- ip -o -4 addr
kubectl exec <pod> -- ip route
kubectl exec <pod> -- ping -c 3 -I net1 <address>

# Multus itself (thick deployment)
kubectl -n kube-system get pods -l name=multus -o wide
kubectl -n kube-system logs <multus pod on the pod's node> -c kube-multus
kubectl -n kube-system get configmap multus-daemon-config -o yaml
```

The complete diagnostic sequence is in [Pitfalls and troubleshooting](../network-patterns/troubleshooting.md#diagnostic-checklist).

## Paths on a node

| Path | Content |
| --- | --- |
| `/etc/cni/net.d/00-multus.conf` | The Multus configuration, generated by the DaemonSet. First in the directory, so the runtime uses it |
| `/etc/cni/net.d/<other files>` | The cluster network's own configuration, which Multus adopts as `clusterNetwork` |
| `/opt/cni/bin/` | Plugin binaries: `multus` or `multus-shim`, and every plugin that a NAD names |
| `/run/multus/multus.sock` | Thick deployment: the socket between shim and daemon |
| `/var/lib/cni/multus/` | Multus's per-pod cache of delegates, used at deletion |
| `/var/lib/cni/networks/<network name>/` | `host-local` allocations for that network, one file per address |

All of these are defaults. Distributions may move them; OpenShift, for example, uses different directories.

## Where to go for more

| Question | Page |
| --- | --- |
| What does option X of the Multus configuration do? | [Configuration](../configuration.md) |
| Which plugin and IPAM should I combine? | [Network Attachment Patterns](../network-patterns/README.md) |
| What can I put into the JSON annotation? | [Building blocks](../network-patterns/building-blocks.md#network-selection-annotation-fields) |
| My pod is stuck or has the wrong address | [Pitfalls and troubleshooting](../network-patterns/troubleshooting.md) |
| How does the daemon and shim split work? | [Thick plugin](../thick-plugin.md) |
| Why does this option exist? | [History of Multus CNI](../history/README.md) |
