# Experiment 02: Ingress

Exposes the hello deployment from experiment 01 through Traefik (the k3s
default ingress controller) using a hostname-based routing rule, instead of
a raw NodePort.

## What you'll observe

- How an Ingress routes HTTP requests by hostname to a backend service
- How Traefik picks up Ingress resources automatically via the ingressClassName
- The difference between hitting a NodePort directly vs going through the ingress controller
- How path-based routing would work (extension of this experiment)

## Prerequisites

Experiment 01 must be applied — the `demo` namespace, `hello` deployment, and
`hello` service must exist.

## Apply

```
kubectl apply -f experiments/02-ingress/ingress.yaml
```

## Configure local DNS

Traefik is listening on all three node IPs on port 80. The Ingress rule routes
requests with `Host: hello.ipc` to the hello service. You need that hostname
to resolve to one of the node IPs on your client machine.

Add to `/etc/hosts` on omen:

```
192.168.88.55  hello.ipc
```

## Test it

```
curl http://hello.ipc
```

You should get the nginx hello page. Hit it several times — the pod hostname
in the response will rotate across your three pods, same as with NodePort.

## What changed from NodePort

With NodePort you were bypassing the ingress controller entirely — the iptables
rules handled balancing directly. With Ingress, the request flow is:

```
curl → Traefik (port 80 on ipc4) → hello Service → pod
```

Traefik is a real proxy process doing the load balancing, not kernel iptables
rules. It also reads the Host header, which is how you can route multiple
services through the same port 80 using different hostnames.

## Add a second route (extension)

To see path-based routing, add a second path to the ingress rules:

```yaml
- path: /api
  pathType: Prefix
  backend:
    service:
      name: some-other-service
      port:
        number: 80
```

Traefik will route `/api/*` to one service and everything else to hello.

## Teardown

```
kubectl delete -f experiments/02-ingress/ingress.yaml
```

The hello deployment and service from experiment 01 remain — only the Ingress
rule is removed.
