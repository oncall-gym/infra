# Certificates

cert-manager issues TLS certificates from the lab's own certificate authority. The names `*.lab.home.arpa` exist only on the local network, so a public CA and ACME are not an option.

## The CA

`gitops/cert-manager/issuers.yaml` builds the CA in three steps:

1. `ClusterIssuer` `selfsigned-bootstrap` signs only the root certificate.
2. `Certificate` `lab-root-ca`: the root (ECDSA P-256, 10 years), stored in the secret `lab-root-ca` in the `cert-manager` namespace.
3. `ClusterIssuer` `lab-ca` signs everything else with that root.

The gateway certificate `lab-wildcard-tls` (`*.lab.home.arpa`, 90 days, renewed automatically) is created by cert-manager from an annotation on the gateway. This requires `enableGatewayAPI: true` in the cert-manager controller config, set in `gitops/apps/cert-manager.yaml`.

## Keeping the root across rebuilds

The CA private key is never in Git. `bootstrap.sh` keeps a copy of the secret outside the repository and restores it before cert-manager starts, so a re-created cluster keeps the same root and clients keep trusting it. If the copy is lost, cert-manager issues a new root and every client has to trust it again. See [bootstrap.md](bootstrap.md).

## Trusting the CA on a client

Export the root certificate (no private key) and add it to the client's trust store:

```sh
kubectl --kubeconfig ./kubeconfig -n cert-manager get secret lab-root-ca \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > lab-root-ca.crt
```

`*.crt` files are git-ignored.

## Checks

```sh
kubectl --kubeconfig ./kubeconfig get clusterissuers
kubectl --kubeconfig ./kubeconfig get certificates -A
```
