# Experiment 03 — ConfigMaps and Secrets

ConfigMaps and Secrets are Kubernetes's two mechanisms for decoupling configuration from container images. ConfigMaps carry plaintext config; Secrets carry values that should be access-controlled. This experiment makes concrete the key operational distinction: mounted ConfigMap files update in a running pod (within ~60 seconds), but environment variables — whether from ConfigMaps or Secrets — do not update without a pod restart. It also surfaces the most important thing to understand about Secrets: base64 encoding is not encryption, and anyone with API read access can decode every Secret in the cluster.

## Files

| File | Purpose |
|------|---------|
| `namespace.yaml` | Creates the `config-demo` namespace |
| `configmap.yaml` | `app-config` ConfigMap with two env vars and a mounted `config.ini` file |
| `secret.yaml` | `app-secret` with `DB_PASSWORD` and `API_KEY` (stored as `stringData`, served as base64) |
| `deployment.yaml` | busybox Deployment that consumes both the ConfigMap and Secret as env vars, and mounts `config.ini` at `/etc/app/config.ini` |

## Apply

The namespace must exist first:

```
kubectl apply -f experiments/03-configmaps-and-secrets/namespace.yaml && kubectl apply -f experiments/03-configmaps-and-secrets/
```

## Observe

### Inspect the ConfigMap

```
kubectl get configmap app-config -n config-demo -o yaml
```

The `data` field is plaintext. ConfigMaps are appropriate for anything you'd commit to a git repo.

### Inspect the Secret

```
kubectl get secret app-secret -n config-demo -o yaml
```

Values under `data` are base64-encoded, not encrypted. Decode one:

```
kubectl get secret app-secret -n config-demo -o jsonpath='{.data.DB_PASSWORD}' | base64 -d
```

That prints `supersecret`. The encoding exists for binary safety, not security. What actually restricts access to Secrets is RBAC — and optionally encryption at rest (not enabled by default in k3s) or an external secrets operator (Vault, SOPS).

### Exec into the pod

```
kubectl get pods -n config-demo
```

```
kubectl exec -n config-demo -it <pod-name> -- sh
```

Inside:

```sh
echo $APP_ENV
echo $DB_PASSWORD
cat /etc/app/config.ini
exit
```

The pod cannot distinguish a value from a ConfigMap vs a Secret — both arrive as plain environment variables.

### Observe the ConfigMap update behavior

Patch the ConfigMap to change the log level:

```
kubectl patch configmap app-config -n config-demo --type merge -p '{"data":{"APP_LOG_LEVEL":"debug"}}'
```

Mounted files update automatically within ~60 seconds:

```
kubectl exec -n config-demo <pod-name> -- cat /etc/app/config.ini
```

Environment variables do not — the pod must restart to see the new value:

```
kubectl exec -n config-demo <pod-name> -- sh -c 'echo $APP_LOG_LEVEL'
```

Still shows `info`. Delete the pod to force a restart (the Deployment recreates it):

```
kubectl delete pod -n config-demo <pod-name>
```

After the replacement pod is Running, `APP_LOG_LEVEL` will be `debug`.

## Teardown

```
kubectl delete namespace config-demo
```
