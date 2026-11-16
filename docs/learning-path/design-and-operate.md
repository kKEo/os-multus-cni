# Stage 3: Design and operate

**Goal:** read a NetworkAttachmentDefinition and predict how it behaves: who allocates the addresses, which interface replies leave on, and what breaks first.

**Time:** 2 to 3 hours. The reading can be spread over several days; the exercises need the [lab cluster](first-lab.md).

After the lab you can make an attachment work. This stage is about choosing the right one and keeping it working.

## Learn: a reading order

The [Network Attachment Patterns](../network-patterns/README.md) section is the core text of this stage. Read it in this order, and stop after each page to answer the question in the last column.

| # | Read | Take away | Ask yourself |
| --- | --- | --- | --- |
| 1 | [Building blocks](../network-patterns/building-blocks.md) | Every attachment is three choices: interface plugin, IPAM plugin, optional meta plugins | Which three did `lab-static` in the lab use? |
| 2 | [Overview and decision guide](../network-patterns/README.md) | Three questions select the interface plugin | Which plugin fits a cloud VM that drops unknown MAC addresses? |
| 3 | [macvlan](../network-patterns/macvlan.md), in full | The reference pattern; the other interface plugins are variations of it | Why can a node not ping the `net1` address of its own pods? |
| 4 | The pattern page for your environment: [ipvlan](../network-patterns/ipvlan.md), [bridge and VLAN](../network-patterns/bridge-vlan.md) or [SR-IOV and host-device](../network-patterns/sriov-host-device.md) | What changes compared with macvlan | What extra component does your choice need on every node? |
| 5 | [Routing](../network-patterns/routing.md) | A pod with two interfaces has one routing table. Replies follow routes, not the interface a request arrived on | Why is a pod reachable from its own subnet and not from another one? |
| 6 | [Multus deployment options](../network-patterns/deployment-options.md) | Thin or thick, `clusterNetwork` or `delegates`, namespace isolation, readiness indicator | Which of these would you change on a shared, multi-tenant cluster? |
| 7 | [Configuration](../configuration.md), skimmed | Which options exist, so that you can find them later | Where would you raise the log level? |
| 8 | [Pitfalls and troubleshooting](../network-patterns/troubleshooting.md) | The symptom table and the five-step diagnostic checklist | Which rows did you already meet in the lab? |

Two pages are lookups, not reading: the [Comparison matrix](../network-patterns/comparison-matrix.md) when you weigh combinations against each other, and [How to use](../how-to-use.md) when you need a manual installation or an annotation form you have not used.

Read these only when they apply to you:

| Topic | Page |
| --- | --- |
| SR-IOV and other device plugins | [SR-IOV and host-device](../network-patterns/sriov-host-device.md), then [Device resource assignment](../device-resource-assignment.md) |
| Dynamic Resource Allocation (DRA) | The DRA section of [How to use](../how-to-use.md#run-pod-with-network-annotation-and-dynamic-resource-allocation-driver) |
| OpenShift | [The OpenShift fork](../history/openshift-fork.md) |
| Why an option exists in two forms | [Upstream history](../history/upstream.md#how-the-configuration-model-evolved) |

## Do: three exercises

The exercises continue on the lab cluster. If you deleted it, repeat Parts 1 and 2 of the [lab](first-lab.md).

### Exercise 1: Cluster-wide addresses with whereabouts

In experiment 5.1 two pods on different nodes received the same address from `host-local`. [whereabouts](https://github.com/k8snetworkplumbingwg/whereabouts) is an IPAM plugin that stores its allocations in the Kubernetes API, so every node sees them.

Install it:

```bash
WB=https://raw.githubusercontent.com/k8snetworkplumbingwg/whereabouts/master/doc/crds
kubectl apply \
  -f $WB/daemonset-install.yaml \
  -f $WB/whereabouts.cni.cncf.io_ippools.yaml \
  -f $WB/whereabouts.cni.cncf.io_overlappingrangeipreservations.yaml
kubectl -n kube-system rollout status daemonset/whereabouts --timeout=240s
```

Its DaemonSet copies a `whereabouts` binary into `/opt/cni/bin` on every node, the same way Multus installed its shim. Now define a network that uses it, and start one pod on each worker:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: lab-wb
spec:
  config: |
    {
      "cniVersion": "1.0.0",
      "name": "lab-wb",
      "type": "macvlan",
      "master": "eth0",
      "mode": "bridge",
      "ipam": {
        "type": "whereabouts",
        "range": "10.30.0.0/24"
      }
    }
---
apiVersion: v1
kind: Pod
metadata:
  name: wb-1
  annotations:
    k8s.v1.cni.cncf.io/networks: lab-wb
spec:
  nodeSelector:
    kubernetes.io/hostname: multus-lab-worker
  containers:
  - name: shell
    image: alpine:3.22
    command: ["sleep", "infinity"]
---
apiVersion: v1
kind: Pod
metadata:
  name: wb-2
  annotations:
    k8s.v1.cni.cncf.io/networks: lab-wb
spec:
  nodeSelector:
    kubernetes.io/hostname: multus-lab-worker2
  containers:
  - name: shell
    image: alpine:3.22
    command: ["sleep", "infinity"]
EOF

kubectl wait --for=condition=Ready pod/wb-1 pod/wb-2 --timeout=180s
kubectl exec wb-1 -- ip -o -4 addr show net1
kubectl exec wb-2 -- ip -o -4 addr show net1
kubectl get ippools.whereabouts.cni.cncf.io -A
```

The pods get `10.30.0.1` and `10.30.0.2`: different addresses on different nodes, with no per-pod configuration. The pool is visible as an `IPPool` object named `10.30.0.0-24`.

**What you learned:** the IPAM plugin, not Multus and not the interface plugin, decides whether addresses are unique across the cluster.

### Exercise 2: Debug logging

In a thick deployment the daemon's settings come from the `multus-daemon-config` ConfigMap. Open it and change `"logLevel": "verbose"` to `"logLevel": "debug"`:

```bash
kubectl -n kube-system edit configmap multus-daemon-config
```

The daemon reads its configuration at start, so restart it:

```bash
kubectl -n kube-system rollout restart daemonset/kube-multus-ds
kubectl -n kube-system rollout status daemonset/kube-multus-ds --timeout=180s
docker exec multus-lab-worker cat /etc/cni/net.d/00-multus.conf
```

The regenerated node configuration now contains `"logLevel":"debug"`. Create any pod with an attachment, then read the log of the Multus pod on its node as in [experiment 5.4](first-lab.md#54-read-the-multus-log). Next to the `[verbose]` lines there are now `[debug]` lines, one for nearly every function Multus enters, with its arguments.

**What you learned:** where the daemon configuration lives, that a change needs a restart, and what debug output looks like before you need it in an incident. Set the level back to `verbose` when you are done; debug logs grow quickly.

### Exercise 3: Namespace isolation

By default a pod may reference a NAD in any namespace. Turn that off. Edit the ConfigMap again and add one line to `daemon-config.json`:

```json
{
    "namespaceIsolation": true,
    "chrootDir": "/hostroot",
    ...
}
```

Restart the DaemonSet as in exercise 2. Then create a network in one namespace and try to use it from another:

```bash
kubectl create namespace team-a
kubectl create namespace team-b

cat <<EOF | kubectl apply -f -
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: team-net
  namespace: team-a
spec:
  config: |
    {
      "cniVersion": "1.0.0",
      "name": "team-net",
      "type": "macvlan",
      "master": "eth0",
      "mode": "bridge",
      "ipam": { "type": "host-local", "subnet": "10.40.0.0/24" }
    }
---
apiVersion: v1
kind: Pod
metadata:
  name: member
  namespace: team-a
  annotations:
    k8s.v1.cni.cncf.io/networks: team-net
spec:
  containers:
  - name: shell
    image: alpine:3.22
    command: ["sleep", "infinity"]
---
apiVersion: v1
kind: Pod
metadata:
  name: intruder
  namespace: team-b
  annotations:
    k8s.v1.cni.cncf.io/networks: team-a/team-net
spec:
  containers:
  - name: shell
    image: alpine:3.22
    command: ["sleep", "infinity"]
EOF

kubectl -n team-a wait --for=condition=Ready pod/member --timeout=120s
kubectl get pods -n team-b
kubectl -n team-b describe pod intruder
```

`member` runs. `intruder` stays in `ContainerCreating`, and its events contain:

```text
namespace isolation enabled, annotation violates permission, pod is in namespace team-b but refers to target namespace team-a
```

**What you learned:** isolation is enforced by Multus when the pod is created, not by the API server when the pod is admitted. NADs in the `default` namespace, and in namespaces listed in `globalNamespaces`, stay usable from everywhere; see [Namespace isolation](../configuration.md#namespace-isolation).

## Operating Multus: what to keep in mind

* **A NAD is per cluster, a plugin binary is per node.** Every plugin named in a NAD must exist in `/opt/cni/bin` on every node that can run the pod.
* **A NAD is read when a pod is created.** Editing a NAD does not touch running pods; they keep the interface they were given until they are recreated.
* **Deletion uses a cache.** At `ADD`, Multus stores the delegates it used under its `cniDir` (default `/var/lib/cni/multus`). `DEL` reads them back, so a pod can be cleaned up even if its NAD has changed or is gone.
* **Secondary addresses are not in `status.podIPs`.** Tools that need them must read the `network-status` annotation.
* **A broken default network stops every pod on the node.** A broken secondary network stops only the pods that ask for it. Treat anything in `defaultNetworks` like the cluster network.
* **Logs are per node.** In a thick deployment, read the Multus pod on the node where the failing pod was scheduled.

Before a new NAD goes to a shared cluster, answer the six [design review questions](../network-patterns/troubleshooting.md#design-review-questions).

## Check yourself

<details>
<summary>A NAD uses <code>macvlan</code> with <code>host-local</code> on a 20-node cluster. What will go wrong, and what are two ways to fix it?</summary>

Pods on different nodes receive the same addresses. Use an IPAM plugin with cluster-wide state such as whereabouts, or give each pod its address through `static` IPAM and the `ips` annotation field.

</details>

<details>
<summary>A pod answers pings from its own secondary subnet, and not from a host behind a router. The NAD has no routes. Why?</summary>

The reply follows the pod's routing table. With no route for the remote subnet on `net1`, it leaves through the default route on `eth0` and is dropped or NATed on the way. Add routes in IPAM, or use source-based routing; see [Routing](../network-patterns/routing.md).

</details>

<details>
<summary>You edit a NAD to change its subnet. A pod that uses it still shows the old address an hour later. Is that a bug?</summary>

No. The NAD is read when a pod is created. Recreate the pod to apply the change.

</details>

<details>
<summary>On a multi-tenant cluster, which Multus option stops a tenant from attaching to a NAD defined in another tenant's namespace?</summary>

`namespaceIsolation`. Shared networks then go into the `default` namespace or one listed in `globalNamespaces`.

</details>

<details>
<summary>A pod is stuck in <code>ContainerCreating</code>. Name the first three places you look.</summary>

The pod's events (`kubectl describe pod`), the NAD's `spec.config` (is it valid JSON, does the plugin exist on that node), and the log of the Multus pod on the node where the pod was scheduled.

</details>

**Next:** [Stage 4: Read the code](code-tour.md), or go back to the [learning path overview](README.md).
