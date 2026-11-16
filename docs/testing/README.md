# End-to-end test coverage

This page describes what the end-to-end (e2e) tests in the [`e2e/`](https://github.com/k8snetworkplumbingwg/multus-cni/tree/master/e2e) directory check, how they check it, and what they leave out. Read it before you rely on a green e2e run as proof that a change is safe, and before you add a test of your own.

In short: the suite proves that Multus installs, that pods start with and without a secondary network, and that a few specific features work in a thick deployment. It checks very little about addresses, connectivity, deletion and error handling.

## How the suite works

The suite is a set of shell scripts. Each script applies a manifest, waits for pods to become `Ready`, runs a few `kubectl exec` checks and deletes the manifest again. There is no test framework and no shared assertion library; a script passes when it exits with status 0.

The manifests are generated from the Jinja templates in `e2e/templates/`. The only template variable is `CNI_VERSION`, which is written into every NetworkAttachmentDefinition (NAD) and into the Multus configuration.

### The test cluster

`e2e/setup_cluster.sh` builds this environment:

| Part | Value |
| --- | --- |
| Cluster | kind, one control-plane node and two workers (`kind-worker`, `kind-worker2`) |
| Cluster network | kindnet, the kind default |
| Secondary link | A veth pair created by `koko`: `eth1` on each worker, connected back to back |
| Multus image | Built from the working tree, tagged `localhost:5000/multus:e2e` and loaded into the nodes |
| Reference plugins | CNI plugins v1.4.0, installed on every node by a DaemonSet |
| Kubelet | Static pod path enabled on the workers, Dynamic Resource Allocation feature gates on |
| containerd | Container Device Interface (CDI) enabled |

Multus itself is configured as follows. Both variants generate the node configuration automatically from the kindnet configuration.

| Deployment | Configuration under test |
| --- | --- |
| Thick (`multus-daemonset-thick.yml`) | `multusConfigFile: auto`, `forceCNIVersion: true`, `logLevel: debug`, `connectionLimit: 1`, no `chrootDir` |
| Thin (`multus-daemonset.yml`) | `--multus-conf-file=auto`, `--force-cni-version=true`, `--cni-version=<CNI_VERSION>` |

### Where it runs

The workflow `.github/workflows/kind-e2e.yml` runs the suite on every push and on pull requests from forks. It uses a matrix of four cells:

| Deployment | CNI version 0.3.1 | CNI version 0.4.0 |
| --- | --- | --- |
| Thick | Yes | Yes |
| Thin | Yes | Yes |

CNI version 1.0.0 is in the workflow as a commented-out entry. It does not run.

## What each test checks

| Script | Feature under test | What is asserted | Runs for |
| --- | --- | --- | --- |
| `test-simple-pod.sh` | A pod with no annotation gets the cluster network through Multus | The pod becomes `Ready` | Thin and thick |
| `test-simple-macvlan1.sh` | A macvlan attachment on `eth1`, with a static address passed through the `ips` field of the annotation | Both pods become `Ready` and have a `net1` interface | Thin and thick |
| `test-static-pod.sh` | A static pod (created by the kubelet from a file, not through the API) that asks for a bridge attachment | The pod becomes `Ready` and has `net1` | Thin and thick |
| `test-default-route1.sh` | The `default-route` field of the annotation | Both pods become `Ready` and have `net1` | Thin and thick |
| `test-connection-limit.sh` | The daemon option `connectionLimit: 1` under parallel pod creation | Six replicas become `Ready` | Thin and thick; the option only exists in the thick configuration |
| `test-subdirectory-chaining.sh` | Extra plugins chained to the cluster network from a subdirectory of the CNI configuration directory named after it (`/etc/cni/net.d/kindnet/`) | A sysctl set by the chained `tuning` plugin has the value `1` on `eth0` in the pod | Thick only |
| `test-subdirectory-chaining-passthru.sh` | The option `auxiliaryCNIChainName`: the same chaining, from a subdirectory with a name of your choice | The same sysctl check, after the daemon configuration is replaced and the DaemonSet restarted | Thick only |
| `test-node-density-cni.sh` | Pod start-up under load: about 128 pods with a macvlan attachment, created by kube-burner | All pods become `Ready`. Pod latency is recorded, not judged | Thick only |
| `test-dra-integration.sh` | A NAD that refers to a Dynamic Resource Allocation claim | An environment variable injected by the example driver is present in the pod | Not run: the step is commented out in the workflow |

Two of these deserve a closer look.

**The address checks do not fail the test.** `test-simple-macvlan1.sh` and `test-default-route1.sh` read the address of `net1` and the default route and compare them with the expected values. When a value differs, the script prints a message and continues. A run in which the pod received the wrong address, or kept the wrong default route, still passes. Only the existence of `net1` is enforced.

**The density test measures the cluster network path.** Every pod in `test-node-density-cni.sh` has a macvlan attachment, so Multus handles two interfaces per pod. The readiness probe of the client pods calls the web server through a Kubernetes Service, which uses `eth0`. No traffic is sent over `net1`.

The numbers from the density test are published by the `performance-report` workflow as a comment on the pull request, with a comparison against the latest run on the main branch. A slower run does not fail the build.

## Coverage by feature

| Area | Covered | Not covered |
| --- | --- | --- |
| Installation | Thin and thick DaemonSets, automatic generation of the node configuration | A hand-written configuration, `chrootDir`, per-node certificates, upgrade from one version to another |
| Annotation forms | JSON form with `name`, `ips` and `default-route`; short form with one name | `namespace/name@interface`, `mac`, `interface`, several attachments in one pod, the `v1.multus-cni.io/default-network` annotation |
| Interface plugins | macvlan, bridge | ipvlan, host-device, SR-IOV, and any plugin that needs hardware |
| IPAM | `static`, `host-local` | whereabouts, DHCP, IPv6 and dual stack |
| Multus options | `connectionLimit`, `auxiliaryCNIChainName`, `forceCNIVersion`, `logLevel` | `namespaceIsolation`, `globalNamespaces`, `defaultNetworks`, `delegates`, `readinessindicatorfile`, `systemNamespaces`, `retryDeleteOnError`, log file options |
| Results | The `net1` interface exists | The `network-status` annotation, pod events, addresses, routes |
| Data path | Cluster network, through a Service | Traffic between pods over the secondary network |
| Lifecycle | Pod creation; one daemon restart | Pod deletion and clean-up of interfaces and address leases, node reboot, a restart of Multus while pods are created |
| Failures | None | A missing NAD, a missing plugin binary, invalid JSON in a NAD, an address conflict |
| Platforms | linux/amd64, CNI versions 0.3.1 and 0.4.0, containerd | arm64 and other architectures, CNI version 1.0.0 and later, CRI-O |

## Gaps worth knowing

* **No negative tests.** Nothing checks that a pod with a broken network fails, or which message it fails with.
* **Deletion is not verified.** The scripts delete their pods, and do not look for leftover interfaces, address leases or cache files under `/var/lib/cni/multus`.
* **The secondary network carries no traffic.** The veth pair between the workers is used as a macvlan parent, and no test sends a packet across it.
* **Thin options are untested.** The thin deployment runs with three arguments. None of the other `thin_entrypoint` flags is exercised.
* **Several checks only warn.** See the note on address checks above.
* **The static pod test ignores the matrix.** `static-pod-nad.yml` is not a template; it always uses CNI version 0.3.1.
* **Old CNI versions only.** Results in the format of CNI 1.0.0 and later, and the `STATUS` and `GC` verbs, are covered by unit tests alone.

The unit tests fill part of these gaps. Configuration parsing, namespace isolation, default networks, delegates and the handling of all CNI result versions are tested in `pkg/types`, `pkg/multus` and `pkg/server`, with fake plugins instead of a cluster. See [Development and support](../development.md#how-do-i-run-the-unit-tests) for how to run them.

## Run the suite

### On your fork

Push a branch to your fork on GitHub. The `e2e-kind` workflow runs all four matrix cells and uploads the kind logs as an artifact. This is the simplest way to run the suite from a machine that is not Linux on amd64.

### On your machine

The scripts need Linux on amd64, Docker and `sudo`:

* `get_tools.sh` downloads `kind`, `kubectl`, `koko`, `jq`, `helm` and `kube-burner` as linux/amd64 binaries.
* The templates select nodes with `kubernetes.io/arch: amd64`.
* `koko` creates the veth pair from the host, using the process IDs of the node containers. This does not work where Docker runs inside a virtual machine, as it does on macOS.

```bash
cd e2e
./get_tools.sh
./generate_yamls.sh          # needs j2; ./sed_generate_yaml.sh works without it
./setup_cluster.sh
./test-simple-macvlan1.sh
./teardown.sh
```

Choose another matrix cell with environment variables:

```bash
CNI_VERSION=0.3.1 ./generate_yamls.sh
MULTUS_MANIFEST=multus-daemonset.yml MULTUS_DOCKERFILE=Dockerfile ./setup_cluster.sh
```

On other machines, use the cluster from the [hands-on lab](../learning-path/first-lab.md) and the method in [Test Multus configurations](../learning-path/config-lab.md).

## Add a test

1. Add a template to `e2e/templates/`. Use `{{ CNI_VERSION }}` wherever a CNI version appears.
2. Add a script `e2e/test-<name>.sh` that applies the generated file from `yamls/`, waits, checks and cleans up.
3. Make every check end in `exit 1` when it fails. A message alone does not fail the run.
4. Add a step to `.github/workflows/kind-e2e.yml`. Restrict it with an `if:` on `matrix.multus-manifest` when the feature exists in only one deployment type.

If the test changes the Multus configuration, put the previous configuration back at the end. All scripts share one cluster and run one after the other.
