# Networking

## Cilium

Cilium is the CNI and replaces kube-proxy; Flannel and kube-proxy built into Talos are disabled in the machine config. Values: `gitops/cilium/values.yaml`, following the Talos documentation.

- IPAM mode `kubernetes`, pod subnet 10.244.0.0/16 (the Talos default).
- Cilium reaches the API server through KubePrism, the Talos local load balancer on `localhost:7445`.
- The agent capabilities are listed explicitly, cgroup automount is off, and the host's `/sys/fs/cgroup` is used.
- The operator runs as a single replica to save memory.
- Hubble relay and UI are enabled; the UI is at https://hubble.lab.home.arpa.
- Gateway API support is enabled (`gatewayAPI.enabled`), which creates the `GatewayClass` `cilium`.

## MetalLB

MetalLB hands out addresses for `LoadBalancer` services in L2 mode from the pool `lan`, 192.168.91.220–192.168.91.230 (`gitops/metallb-config/pool.yaml`). The chart runs with default values.

- The pool must not overlap the router's DHCP range or the node addresses.
- 192.168.91.220 is reserved for the gateway; the rest of the pool is free.
- The `metallb-system` namespace is labelled `pod-security.kubernetes.io/enforce: privileged`: the speaker uses the host network, and Talos enforces `baseline` by default.

## Shared gateway

All inbound HTTP(S) traffic goes through one Gateway API gateway, `lab` in the `gateway` namespace, implemented by Cilium. There is no separate ingress controller.

| Listener | Port | Routes accepted from | Purpose |
| --- | --- | --- | --- |
| `http` | 80 | the `gateway` namespace only | a single route that redirects everything to HTTPS |
| `https` | 443 | any namespace | service routes; TLS terminates here |

- The gateway service `cilium-gateway-lab` gets 192.168.91.220 through the annotation `metallb.io/loadBalancerIPs` in `spec.infrastructure`.
- The certificate `*.lab.home.arpa` is requested by the annotation `cert-manager.io/cluster-issuer: lab-ca` on the gateway itself; there is no separate `Certificate` manifest (see [certificates.md](certificates.md)).
- The Gateway API CRDs come from the application `gateway-api-crds` (`ServerSideApply`, since they are too large for a regular apply).
- `*.lab.home.arpa` resolves to 192.168.91.220 on the local network only; the DNS records are outside this repository.

Published services:

| Address | `HTTPRoute` | Service |
| --- | --- | --- |
| https://argocd.lab.home.arpa | `argocd` in `argocd` | `argocd-server:80` |
| https://hubble.lab.home.arpa | `hubble` in `kube-system` | `hubble-ui:80` |
| https://grafana.lab.home.arpa | `grafana` in `monitoring` | `vmks-grafana:80` |
| https://trainer.lab.home.arpa | `trainer-api` in `trainer` | `trainer-api:80` |

### Where HTTPRoutes live

- **Third-party platform tools** (Argo CD, Hubble, Grafana): in `gitops/gateway/`,
  because their Helm charts do not ship routes we control.
- **Our own applications** (trainer and future services): next to the application,
  in `gitops/<app>/route.yaml`, in the application's namespace. The route is created,
  changed and deleted together with the app.

The Gateway decides which namespaces may attach routes (`allowedRoutes` on each listener):
`https` accepts routes from all namespaces, `http` only from `gateway`, where the only
route is the redirect to HTTPS.

### Publishing a service

Add an `HTTPRoute` in the service's own namespace, in the place described above, with `parentRefs` pointing at the gateway `lab` in the `gateway` namespace and `sectionName: https`, and a host name `<service>.lab.home.arpa`. Add a DNS record for the name. No certificate is needed: the wildcard covers it. The service itself stays `ClusterIP`.

## Checks

```sh
kubectl --kubeconfig ./kubeconfig get gatewayclass
kubectl --kubeconfig ./kubeconfig get gateway,httproute -A
curl -I --resolve argocd.lab.home.arpa:80:192.168.91.220 http://argocd.lab.home.arpa/                              # 301 to https
curl -I --cacert ./lab-root-ca.crt --resolve argocd.lab.home.arpa:443:192.168.91.220 https://argocd.lab.home.arpa/  # 200
```
