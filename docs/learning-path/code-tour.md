# Stage 4: Read the code

**Goal:** find the function behind a given behaviour, follow one CNI `ADD` from the entry point to the delegate, and run the tests.

**Time:** about 2 hours.

Multus is a small Go code base: about 9,000 lines outside the tests, and one function, `CmdAdd`, that holds most of the story. If you did the [lab](first-lab.md), you have already seen everything this code does. This stage shows where it happens.

## Learn

### 1. The repository map

| Path | What is in it |
| --- | --- |
| `cmd/multus` | The thin plugin binary. Its `main` wires the CNI verbs to `pkg/multus` |
| `cmd/multus-shim` | The thick plugin binary that the runtime executes. It only forwards requests |
| `cmd/multus-daemon` | The thick daemon: loads its configuration, starts the server, keeps the node's Multus configuration up to date |
| `cmd/install_multus` | Copies `multus` or `multus-shim` into the node's CNI binary directory. It is the DaemonSet's init container |
| `cmd/thin_entrypoint` | Entrypoint of the thin DaemonSet: generates the Multus configuration and kubeconfig on the node |
| `cmd/kubeconfig_generator`, `cmd/cert-approver` | Helpers for credentials: a kubeconfig for Multus, and a controller that approves its certificate requests when per-node certificates are enabled |
| `cmd/passthru-cni` | A plugin that does nothing and returns an empty result. It is the head of the auxiliary CNI chain |
| `pkg/multus` | **The core.** `CmdAdd`, `CmdDel`, `CmdCheck`, `CmdGC`, `CmdStatus` and the code that invokes delegates |
| `pkg/types` | Configuration structs and their parsing: the Multus configuration, delegates, annotation elements |
| `pkg/k8sclient` | Everything that talks to the Kubernetes API: reading pods and NADs, parsing annotations, writing the network status |
| `pkg/server` | The thick daemon's HTTP server. `pkg/server/api` is the shim side; `pkg/server/config` generates and watches the Multus configuration |
| `pkg/netutils` | Default route handling for the `default-route` annotation field |
| `pkg/kubeletclient`, `pkg/checkpoint`, `pkg/draclient` | Where device IDs come from: the kubelet pod-resources API, the kubelet checkpoint file, and Dynamic Resource Allocation claims |
| `pkg/logging` | The `Debugf`, `Verbosef`, `Errorf` and `Panicf` helpers used everywhere |
| `deployments/` | The DaemonSet manifests you applied in the lab |
| `images/` | Dockerfiles for the thin, thick and debug images |
| `e2e/` | End-to-end tests that run on kind |
| `hack/` | `build-go.sh` and `test-go.sh` |

In this repository, `Dockerfile.openshift`, `Dockerfile.microshift`, `.ci-operator.yaml` and `OWNERS` belong to the OpenShift fork; see [The OpenShift fork](../history/openshift-fork.md).

### 2. Three types to recognise

All three are in `pkg/types/types.go`.

| Type | Represents | Filled from |
| --- | --- | --- |
| `NetConf` | The Multus configuration: `clusterNetwork`, `defaultNetworks`, `delegates`, `namespaceIsolation`, logging options, ... | The JSON on stdin, by `LoadNetConf` |
| `NetworkSelectionElement` | One entry of the `k8s.v1.cni.cncf.io/networks` annotation: `name`, `namespace`, `interface`, `ips`, `mac`, `default-route`, ... | The pod annotation, by `parsePodNetworkAnnotation` |
| `DelegateNetConf` | One plugin configuration that Multus will invoke, plus the per-pod requests merged into it | A NAD and a selection element, by `LoadDelegateNetConf` |

The whole of Multus can be read as: build a `NetConf`, turn annotation elements into `DelegateNetConf` values, run them.

### 3. Follow one ADD

<!-- svgdog add-path
version: 1
theme: docs-auto
diagram: flow
direction: down
title: The code path of a CNI ADD
description: The thin binary calls multus.CmdAdd directly; the thick shim posts the request over a Unix socket to the daemon, which calls the same function. CmdAdd loads the configuration, builds the delegate list from the pod annotations, invokes each delegate and publishes the network status.
nodes:
  - { id: thin, label: "cmd/multus\n(thin plugin)", kind: client }
  - { id: shim, label: "cmd/multus-shim\npkg/server/api", kind: client }
  - { id: daemon, label: "cmd/multus-daemon\npkg/server", kind: service }
  - { id: cmdadd, label: "multus.CmdAdd\npkg/multus/multus.go", kind: service, emphasis: true }
  - { id: conf, label: "types.LoadNetConf\npkg/types/conf.go", kind: box }
  - { id: k8s, label: "k8sclient: GetDefaultNetworks,\nTryLoadPodDelegates", kind: box }
  - { id: deleg, label: "DelegateAdd\n(libcni executes the plugin)", kind: box }
  - { id: status, label: "k8sclient.SetNetworkStatus", kind: box }
edges:
  - "thin -> cmdadd"
  - "shim -> daemon: HTTP over a Unix socket"
  - "daemon -> cmdadd"
  - "cmdadd -> conf"
  - "cmdadd -> k8s"
  - "cmdadd -> deleg"
  - "cmdadd -> status"
steps:
  - { text: Parse the Multus configuration received on stdin., show: [conf] }
  - { text: "Build the delegate list: cluster network first, then one delegate per attachment.", show: [k8s] }
  - { text: "Run every delegate in order; roll back with DEL if one fails.", show: [deleg] }
  - { text: Write the network-status annotation and return the default network result., show: [status] }
-->

![The code path of a CNI ADD. The thin binary calls multus.CmdAdd directly; the thick shim posts the request over a Unix socket to the daemon, which calls the same function. CmdAdd loads the configuration, builds the delegate list from the pod annotations, invokes each delegate and publishes the network status.](diagrams/code-tour-add-path.svg)

**Two entry points, one function.** Both deployments end in `multus.CmdAdd` in `pkg/multus/multus.go`:

* Thin: `cmd/multus/main.go` registers `multus.CmdAdd` with the CNI `skel` package, which reads the environment and stdin.
* Thick: `cmd/multus-shim/main.go` calls `api.CmdAdd` in `pkg/server/api/shim.go`. That function packs the environment and stdin into a request and posts it to the daemon's socket. In the daemon, `handleCNIRequest` in `pkg/server/server.go` unpacks it and calls the same `multus.CmdAdd`, passing its long-lived Kubernetes client.

**Inside `CmdAdd`.** Read the function from top to bottom with this list next to it:

| Step | Call | What it does |
| --- | --- | --- |
| 1 | `types.LoadNetConf` | Parses the Multus configuration |
| 2 | `types.GetReadinessIndicatorFile` | Waits for the default network, if `readinessindicatorfile` is set |
| 3 | `GetPod` | Fetches the pod, so that its annotations are available |
| 4 | `k8s.GetDefaultNetworks` | Resolves `clusterNetwork` and `defaultNetworks` into the first delegates. Delegate 0 is marked as the master plugin |
| 5 | `k8s.TryLoadPodDelegates` | Parses the pod's `networks` annotation, enforces namespace isolation, fetches each NAD and appends one delegate per element |
| 6 | `saveDelegates` | Caches the delegate list on the node, for the later `DEL` |
| 7 | For each delegate: `getIfname`, `DelegateAdd` | Chooses the interface name and runs the plugin through `libcni`. On failure, `delPlugins` removes what was already added |
| 8 | For each delegate: `netutils.DeleteDefaultGW`, `netutils.SetDefaultGW` | Applies a `default-route` request, if there is one |
| 9 | `k8s.SetNetworkStatus` | Writes the `network-status` annotation, once all delegates have run |
| 10 | `return result` | Returns the master plugin's result to the runtime |

`CmdDel` mirrors it: it loads the cached delegates and calls `delPlugins`, which walks the list backwards.

### 4. What only the thick daemon does

`pkg/server` adds three things on top of the shared core:

* **Informers.** `newPodInformer` and `newNetDefInformer` keep local caches of the node's pods and of all NADs, so that an `ADD` does not need a fresh API round trip for each lookup.
* **Configuration management.** `pkg/server/config` generates `00-multus.conf` from the primary CNI configuration and regenerates it when that file changes. This is the `"multusConfigFile": "auto"` behaviour you saw in the lab.
* **Health and metrics endpoints.** The server registers `/healthz`, `/readyz` and a Prometheus request counter.

## Do

### 1. Three reading exercises

Find the answers in the code before opening the solutions. Each takes about ten minutes.

<details>
<summary>Where does the name <code>net1</code> come from, and when is it not used?</summary>

`getIfname` in `pkg/multus/multus.go`. It returns the requested name if the annotation gave one, the runtime's interface name (`eth0`) for the master plugin, and otherwise `net` followed by the delegate's index in the list.

</details>

<details>
<summary>Which function rejects a pod that references a NAD in another namespace when namespace isolation is on?</summary>

`GetNetworkDelegates` in `pkg/k8sclient/k8sclient.go`. It compares the pod's namespace with the namespace in each selection element and returns the error you saw in [Stage 3, exercise 3](design-and-operate.md#exercise-3-namespace-isolation).

</details>

<details>
<summary>A pod has three attachments and the third plugin fails. What happens to the first two?</summary>

In the delegate loop of `CmdAdd`, a failing `DelegateAdd` triggers `delPlugins` for the delegates up to the failing index, and `CmdAdd` returns an error. The pod sandbox is not created, and the kubelet retries later.

</details>

### 2. Build

```bash
git clone https://github.com/k8snetworkplumbingwg/multus-cni.git
cd multus-cni
./hack/build-go.sh
ls bin/
```

The script builds `multus`, `multus-daemon`, `multus-shim`, `install_multus` and `thin_entrypoint` into `bin/`.

> **Build on Linux.** The code imports Linux-only packages, and the script uses GNU `date`. On macOS, work in a Linux VM or container. To check only that your change compiles, cross-compile a single binary: `GOOS=linux go build -o /tmp/multus ./cmd/multus`.

### 3. Run the unit tests

```bash
sudo env "PATH=$PATH" ./hack/test-go.sh
```

The tests use the Ginkgo framework and live next to the code as `*_test.go`. They need root on Linux because several suites create network namespaces. The most instructive file is `pkg/multus/multus_cni100_test.go`: every `It(...)` block is a small scenario, such as "executes delegates and cleans up on failure", with a fake plugin executor in place of real binaries. Reading a test next to the code it covers is the fastest way to understand a branch of `CmdAdd`.

### 4. Run your build in a cluster

The `e2e/` directory does what you did by hand in the lab, with an image built from your working tree: `setup_cluster.sh` builds `images/Dockerfile.thick`, creates a kind cluster, loads the image and deploys Multus, and the `test-*.sh` scripts run scenarios against it. Start with [`e2e/README.md`](https://github.com/k8snetworkplumbingwg/multus-cni/blob/master/e2e/README.md) and read `test-simple-macvlan1.sh`; it is the lab's Part 4 as a script. The helper scripts download Linux x86-64 tools, so run them on such a host.

### 5. Before your first change

* [Development and support](../development.md): logging conventions, supported Kubernetes versions, release schedule.
* [`CONTRIBUTING.md`](https://github.com/k8snetworkplumbingwg/multus-cni/blob/master/CONTRIBUTING.md): commit message format and sign-off.
* If you work in the OpenShift fork: fix upstream first. The reasons and the exceptions are in [Practical guidance for contributors](../history/openshift-fork.md#practical-guidance-for-contributors).

## Check yourself

<details>
<summary>In a thick deployment, in which process does <code>multus.CmdAdd</code> run?</summary>

In `multus-daemon`. The shim that the runtime executes only forwards the request and prints the response.

</details>

<details>
<summary>Why does <code>CmdAdd</code> save the delegates to disk before running them?</summary>

So that `CmdDel` can remove exactly what was added, even if the pod's annotations or its NADs have changed or disappeared in the meantime.

</details>

<details>
<summary>Whose result does Multus return to the container runtime?</summary>

The master plugin's, which is the default network's. This is the reason the pod IP is always the `eth0` address.

</details>

<details>
<summary>You want to add a field to the network selection annotation. Which type and which two functions do you look at first?</summary>

`NetworkSelectionElement` in `pkg/types/types.go`, `parsePodNetworkAnnotation` in `pkg/k8sclient/k8sclient.go` where it is validated, and `LoadDelegateNetConf` in `pkg/types/conf.go` where it is merged into the delegate.

</details>

**Back to:** [Learning path overview](README.md)
