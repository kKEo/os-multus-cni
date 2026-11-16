# Lab follow-up: Test Multus configurations

**Goal:** change one Multus setting at a time, and prove what the change does with a check that passes or fails.

**Time:** 60 to 90 minutes. Parts 1 and 2 continue on the cluster from the [hands-on lab](first-lab.md); Parts 3 and 4 use a second, smaller cluster.

In the lab you made one configuration work. Sooner or later you need to compare several: a different annotation, another daemon option, the thin deployment, or your own build. This page gives you a repeatable way to do that on a laptop.

> **Status of this page.** The commands follow the repository's manifests, source code and e2e scripts, and have not yet been run from start to finish on a lab cluster. If a step behaves differently for you, trust what you see and correct the page.

## Which method for which question

| You want to know | Use | Feedback in |
| --- | --- | --- |
| How a NAD or an annotation behaves | The lab cluster; apply and look ([Part 1](#part-1-nad-and-annotation-variants)) | Seconds |
| What a daemon option does | The lab cluster; change the ConfigMap and restart ([Part 2](#part-2-daemon-options)) | About a minute |
| How the thin deployment differs | A second kind cluster ([Part 3](#part-3-the-thin-deployment)) | A few minutes |
| How Multus reads a configuration file | The `multus` binary, called by hand ([Part 4](#part-4-multus-without-kubernetes)) | Seconds |
| Whether your code change works | Your own image in the lab cluster ([Part 5](#part-5-test-your-own-build)) | A few minutes |
| Whether you broke something else | The unit tests and the e2e suite ([Beyond the lab](#beyond-the-lab)) | 10 to 30 minutes |

## The test loop

Every test on this page has the same five steps:

1. **Change** one thing: a NAD, an annotation or a Multus option.
2. **Restart** Multus, only if you changed a Multus option.
3. **Create** a pod that uses the change.
4. **Check** the result against a value you wrote down beforehand.
5. **Clean up**, so that the next test starts from a known state.

Step 4 is the one people skip. Looking at the output and deciding that it seems right is not a test. Define three small shell functions and use them for every check:

```bash
# Compare an actual value with an expected one.
expect() {
  if [ "$2" = "$3" ]; then
    echo "PASS  $1"
  else
    echo "FAIL  $1: got '$2', want '$3'"
    return 1
  fi
}

# Print what Multus recorded for a pod: netstatus <pod> [namespace]
netstatus() {
  kubectl get pod "$1" -n "${2:-default}" \
    -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}' \
    | jq -c '.[] | {name, interface, ips}'
}

# Merge options into the thick daemon configuration, then restart Multus.
set_daemon_option() {
  kubectl -n kube-system get configmap multus-daemon-config -o json \
    | jq --argjson patch "$1" '.data["daemon-config.json"] |= (fromjson + $patch | tojson)' \
    | kubectl apply -f -
  kubectl -n kube-system rollout restart daemonset/kube-multus-ds
  kubectl -n kube-system rollout status daemonset/kube-multus-ds --timeout=180s
}
```

There are three places to look for a result. Use the one that matches your question:

| Look at | It tells you |
| --- | --- |
| `ip addr` and `ip route` in the pod | What the plugins did |
| The `network-status` annotation | What Multus recorded |
| Pod events and the Multus log | Why something failed |

## Part 1: NAD and annotation variants

A NAD is read when a pod is created, so these variants need no restart. Create a new pod for every variant.

This example tests the `default-route` field of the annotation. It reuses the `lab-static` network from [Part 4 of the lab](first-lab.md#part-4-two-pods-across-nodes). Expected result: the default route of the pod moves from `eth0` to `net1`.

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: pod-route
  annotations:
    k8s.v1.cni.cncf.io/networks: '[{
      "name": "lab-static",
      "ips": ["10.20.0.21/24"],
      "default-route": ["10.20.0.254"]
    }]'
spec:
  containers:
  - name: shell
    image: alpine:3.22
    command: ["sleep", "infinity"]
EOF

kubectl wait --for=condition=Ready pod/pod-route --timeout=180s

expect "net1 address" \
  "$(kubectl exec pod-route -- ip -o -4 addr show net1 | awk '{print $4}')" \
  "10.20.0.21/24"

expect "default route" \
  "$(kubectl exec pod-route -- ip route | awk '/^default/ {print $3, $5}')" \
  "10.20.0.254 net1"

netstatus pod-route
kubectl delete pod pod-route
```

Both checks print `PASS`. The pod now sends everything that is not on a directly connected network through `net1`, so it can no longer reach pods on other nodes over the cluster network.

Try these variants the same way. Write down the expected value first, then run the check.

| Variant | Change | What to check |
| --- | --- | --- |
| Custom interface name | `"interface": "data0"` in the annotation | `ip addr show data0` succeeds, and `net1` does not exist |
| Two networks | Two entries in the annotation list | `netstatus` prints three lines |
| NAD in another namespace | `"namespace": "team-a"` in the annotation | The pod starts, unless namespace isolation is on (Part 2) |
| The `ips` capability removed | Delete `"capabilities"` from a copy of `lab-static` | Predict the result with the help of [Building blocks](../network-patterns/building-blocks.md#requesting-a-specific-ipmac-per-pod), then test it |
| Invalid NAD | Break the JSON in `spec.config` | The pod stays in `ContainerCreating`; the event names the error |

## Part 2: Daemon options

In a thick deployment the options are in the `multus-daemon-config` ConfigMap. The daemon reads it once, at start. `set_daemon_option` therefore does two things: it merges your change into `daemon-config.json` and restarts the DaemonSet.

Test `logLevel` first, because the check is simple. The daemon writes its options into the node configuration, so read them back from there:

```bash
set_daemon_option '{"logLevel": "debug"}'

expect "logLevel on the node" \
  "$(docker exec multus-lab-worker cat /etc/cni/net.d/00-multus.conf | jq -r .logLevel)" \
  "debug"
```

Now a test with two outcomes. With `namespaceIsolation` on, a pod must not use a NAD from another namespace. This is [exercise 3 of Stage 3](design-and-operate.md#exercise-3-namespace-isolation), written as a test. It needs the namespaces, the NAD and the pods from that exercise.

```bash
set_daemon_option '{"namespaceIsolation": true}'

kubectl -n team-b delete pod intruder --ignore-not-found
# Apply the "intruder" pod from exercise 3 again, then:

sleep 20
expect "intruder is blocked" \
  "$(kubectl -n team-b get pod intruder -o jsonpath='{.status.phase}')" \
  "Pending"

kubectl -n team-b get events --field-selector involvedObject.name=intruder \
  -o custom-columns=REASON:.reason,MESSAGE:.message | grep "namespace isolation"
```

Then change one more option and repeat the same check with the opposite expectation. `globalNamespaces` lists namespaces whose NADs stay usable from everywhere:

```bash
set_daemon_option '{"namespaceIsolation": true, "globalNamespaces": "team-a"}'

kubectl -n team-b delete pod intruder
# Apply the "intruder" pod again, then:

kubectl -n team-b wait --for=condition=Ready pod/intruder --timeout=120s
netstatus intruder team-b
```

The same pod, with the same annotation, now starts. That pair of tests, one that must fail and one that must pass, is what makes the result convincing.

Put the cluster back when you are done:

```bash
set_daemon_option '{"namespaceIsolation": false, "globalNamespaces": "", "logLevel": "verbose"}'
```

> **A restart is not free.** While the Multus pod on a node restarts, new pods on that node wait. Running pods keep their interfaces. On a real cluster, change one node first.

Other options to test in the same way are listed in the [Configuration reference](../configuration.md) and in [Thick plugin](../thick-plugin.md#server--daemon-configuration).

## Part 3: The thin deployment

Thin and thick install different files on the nodes, so do not switch a cluster from one to the other. Create a second cluster. One worker is enough:

```bash
cat <<EOF | kind create cluster --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: multus-thin
nodes:
  - role: control-plane
  - role: worker
EOF

kubectl apply -f https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/master/deployments/multus-daemonset.yml
kubectl -n kube-system rollout status daemonset/kube-multus-ds --timeout=300s
```

> **Memory.** Two kind clusters at once may be too much for a small Docker VM. Delete the first one (`kind delete cluster --name multus-lab`) if `kubectl` starts to time out.

Compare the node with what you saw in [step 2.3 of the lab](first-lab.md#23-see-what-changed-on-the-node):

```bash
docker exec multus-thin-worker ls /etc/cni/net.d /opt/cni/bin
docker exec multus-thin-worker cat /etc/cni/net.d/00-multus.conf | jq
```

| | Thick | Thin |
| --- | --- | --- |
| Binary in `/opt/cni/bin` | `multus-shim` | `multus` |
| `type` in `00-multus.conf` | `multus-shim` | `multus` |
| How it reaches the API server | Through the daemon | With a kubeconfig file, named in `00-multus.conf` |
| Where options are set | The `multus-daemon-config` ConfigMap | Arguments of the `thin_entrypoint` container |
| Where the log goes | The Multus pod | The runtime's log on the node, or a log file |

In a thin deployment an option is a command-line argument. Add one, and check the generated configuration as before:

```bash
kubectl -n kube-system patch daemonset kube-multus-ds --type=json -p '[
  {"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--multus-log-level=debug"}
]'
kubectl -n kube-system rollout status daemonset/kube-multus-ds --timeout=180s

expect "logLevel on the node" \
  "$(docker exec multus-thin-worker cat /etc/cni/net.d/00-multus.conf | jq -r .logLevel)" \
  "debug"
```

`--namespace-isolation=true` and `--global-namespaces=<list>` are the thin forms of the two options from Part 2. The full list of arguments is at the top of `cmd/thin_entrypoint/main.go`.

## Part 4: Multus without Kubernetes

The thin `multus` binary is an ordinary CNI plugin. If its configuration lists the networks directly, in `delegates`, and names no kubeconfig, Multus does not contact the API server at all. That gives you the fastest test of how Multus reads a configuration: no pod, no NAD, no restart.

Repeat [step 1.3 of the lab](first-lab.md#13-be-the-container-runtime), with Multus in place of `ptp`. Open a shell on the worker of the thin cluster:

```bash
docker exec -it multus-thin-worker bash
```

Inside the node, create a namespace and a configuration with two delegates:

```bash
ip netns add demo

cat > /tmp/multus-demo.conf <<EOF
{
  "cniVersion": "1.0.0",
  "name": "multus-demo",
  "type": "multus",
  "logLevel": "debug",
  "logToStderr": true,
  "delegates": [
    {
      "cniVersion": "1.0.0",
      "name": "first",
      "type": "ptp",
      "ipam": { "type": "host-local", "subnet": "10.98.0.0/24" }
    },
    {
      "cniVersion": "1.0.0",
      "name": "second",
      "type": "ptp",
      "ipam": { "type": "host-local", "subnet": "10.99.0.0/24" }
    }
  ]
}
EOF

CNI_COMMAND=ADD CNI_CONTAINERID=demo1 CNI_NETNS=/var/run/netns/demo \
CNI_IFNAME=eth0 CNI_PATH=/opt/cni/bin /opt/cni/bin/multus < /tmp/multus-demo.conf

ip -n demo -o -4 addr
```

Expected result: the namespace has `eth0` with an address from `10.98.0.0/24` and `net1` with one from `10.99.0.0/24`. The JSON that Multus prints is the result of the first delegate only. The debug lines on your terminal show both delegate calls.

Three things to notice:

* The first delegate received the interface name the caller asked for. The second received `net1`. This is the same rule as in a cluster.
* `ls /var/lib/cni/multus/` shows a file for `demo1`. It is the delegate cache that `DEL` reads.
* Nothing here used Kubernetes. Options that need the API server (`clusterNetwork`, `defaultNetworks`, namespace isolation, the annotations) cannot be tested this way.

Now change the configuration and call the binary again. Remove `"name"` from a delegate, misspell `"delegates"`, or set `"binDir"` to a directory without plugins, and read the error. Clean up with `DEL`:

```bash
CNI_COMMAND=DEL CNI_CONTAINERID=demo1 CNI_NETNS=/var/run/netns/demo \
CNI_IFNAME=eth0 CNI_PATH=/opt/cni/bin /opt/cni/bin/multus < /tmp/multus-demo.conf

ip netns del demo
rm /tmp/multus-demo.conf
exit
```

Delete the thin cluster if you do not need it any more: `kind delete cluster --name multus-thin`.

## Part 5: Test your own build

To test a change in the code, replace the image. From the root of your clone:

```bash
docker build -t localhost:5000/multus:e2e -f images/Dockerfile.thick .
kind load docker-image localhost:5000/multus:e2e --name multus-lab

kubectl -n kube-system set image daemonset/kube-multus-ds \
  kube-multus=localhost:5000/multus:e2e \
  install-multus-binary=localhost:5000/multus:e2e
kubectl -n kube-system rollout status daemonset/kube-multus-ds --timeout=180s
```

`kind load` copies the image into every node, so no registry is needed. Both containers must use the new image: the init container installs `multus-shim` on the node, and the main container runs the daemon. Then run the tests from Parts 1 and 2 again.

For the thin deployment, build `images/Dockerfile` and load the image into the `multus-thin` cluster.

## Beyond the lab

A laptop cluster answers the question "does this configuration do what I think?". Two more tools answer "did I break something else?".

* **Unit tests.** `sudo ./hack/test-go.sh` runs them. They need Linux and root, because they create network namespaces. The cases closest to this page are in `pkg/types/conf_test.go` (configuration parsing) and `pkg/server/config/` (the configuration that the thick daemon generates). [Stage 4](code-tour.md) shows how to read and run them.
* **The e2e suite.** It runs in GitHub Actions for the thin and thick deployments and two CNI versions. Push a branch to your fork to start it. [End-to-end test coverage](../testing/README.md) lists what it checks, and what it does not.

## Check yourself

<details>
<summary>You changed <code>logLevel</code> in the ConfigMap and the log looks the same. What did you forget?</summary>

To restart the DaemonSet. The daemon reads its configuration once, at start.

</details>

<details>
<summary>Which changes need a restart of Multus, and which do not?</summary>

Multus options need one. NADs and pod annotations do not: they are read every time a pod is created, so a new pod is enough.

</details>

<details>
<summary>Why is a second cluster the safer way to compare thin and thick?</summary>

Each deployment leaves its own binary and its own `00-multus.conf` on every node. After a switch on the same cluster, leftovers of the first deployment can make the result hard to interpret.

</details>

<details>
<summary>You call the <code>multus</code> binary by hand with <code>delegates</code>. Why can you not test namespace isolation like this?</summary>

Without a kubeconfig, Multus does not talk to the API server. There are no pods, namespaces or NADs to apply the rule to.

</details>

<details>
<summary>Why is "the pod is Ready" a weak check for a secondary network?</summary>

Readiness says that the sandbox was created. It does not say that `net1` has the address, route or peer you wanted. Compare a concrete value, as `expect` does.

</details>

**Next:** [Stage 3: Design and operate](design-and-operate.md) to choose and review networks, or [End-to-end test coverage](../testing/README.md) to see how the project tests the same things.
