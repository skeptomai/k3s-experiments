# Experiment 03: ConfigMaps and Secrets

## What you'll observe

- How ConfigMaps inject non-sensitive configuration as environment variables
- How ConfigMaps mount structured files into a container's filesystem
- How Secrets inject sensitive values as environment variables
- That Secrets are base64-encoded in etcd, not encrypted — and what that means
- How to update a ConfigMap and see the change reflected in a running pod

## Apply

```
kubectl apply -f experiments/03-configmaps-and-secrets/namespace.yaml && kubectl apply -f experiments/03-configmaps-and-secrets/
```

## Inspect the ConfigMap

```
kubectl get configmap app-config -n config-demo -o yaml
```

The `data` field is plaintext. ConfigMaps are not for secrets — they're for
configuration that you'd be comfortable putting in a git repo.

## Inspect the Secret

```
kubectl get secret app-secret -n config-demo -o yaml
```

The values under `data` are base64-encoded, not encrypted:

```
kubectl get secret app-secret -n config-demo -o jsonpath='{.data.DB_PASSWORD}' | base64 -d
```

That prints `supersecret`. Anyone with read access to the Kubernetes API can
decode every Secret in the cluster. The base64 encoding exists for binary
safety, not security.

What actually protects Secrets (if anything):
- **RBAC** — restrict which service accounts and users can `get`/`list` Secrets
- **Encryption at rest** — k3s/Kubernetes can encrypt the etcd data on disk,
  but it's not enabled by default and the encryption key still lives on the
  control plane node
- **External secret operators** — Vault, AWS Secrets Manager, SOPS — store the
  real secret outside the cluster and sync only at pod startup

## Exec into the pod and inspect

Get the pod name:

```
kubectl get pods -n config-demo
```

Exec in:

```
kubectl exec -n config-demo -it <pod-name> -- sh
```

Inside the pod:

```sh
# Environment variables from ConfigMap and Secret look identical
echo $APP_ENV
echo $DB_PASSWORD

# The config file is mounted at /etc/app/config.ini
cat /etc/app/config.ini

# Exit
exit
```

The pod cannot tell whether a value came from a ConfigMap or a Secret — they
arrive identically as environment variables. The distinction is purely in how
Kubernetes stores and controls access to them.

## Update the ConfigMap and observe

Edit the ConfigMap to change the log level:

```
kubectl patch configmap app-config -n config-demo --type merge -p '{"data":{"APP_LOG_LEVEL":"debug"}}'
```

**Mounted files update automatically** (within ~60 seconds) — check:

```
kubectl exec -n config-demo <pod-name> -- cat /etc/app/config.ini
```

**Environment variables do NOT update** — the pod must be restarted to pick up
the new value:

```
kubectl exec -n config-demo <pod-name> -- sh -c 'echo $APP_LOG_LEVEL'
```

Still shows `info`. Delete the pod to force a restart (the Deployment recreates it):

```
kubectl delete pod -n config-demo <pod-name>
```

After restart, `APP_LOG_LEVEL` will be `debug`.

## Teardown

```
kubectl delete namespace config-demo
```
