"""
title: K8s Explore
description: Read-only exploration of the k3s cluster -- list/get resources, describe an object with its recent events, or read pod logs.
"""

import json
import urllib.request
import urllib.parse
import ssl


# Explicit allowlist, defense-in-depth on top of RBAC (manifests/open-webui/rbac.yaml
# grants exactly this set, get/list/watch only) -- if RBAC is ever accidentally
# broadened, this tool still refuses anything not listed here. "secrets" is
# permanently excluded: read-only RBAC on other resources doesn't protect secret
# *values*, so the only safe rule is the tool never touches them, full stop.
RESOURCE_MAP = {
    "nodes": ("/api/v1", False),
    "pods": ("/api/v1", True),
    "services": ("/api/v1", True),
    "endpoints": ("/api/v1", True),
    "configmaps": ("/api/v1", True),
    "events": ("/api/v1", True),
    "namespaces": ("/api/v1", False),
    "persistentvolumeclaims": ("/api/v1", True),
    "replicationcontrollers": ("/api/v1", True),
    "deployments": ("/apis/apps/v1", True),
    "replicasets": ("/apis/apps/v1", True),
    "daemonsets": ("/apis/apps/v1", True),
    "statefulsets": ("/apis/apps/v1", True),
    "jobs": ("/apis/batch/v1", True),
    "cronjobs": ("/apis/batch/v1", True),
}
MAX_LIST_ITEMS = 50
MAX_OUTPUT_CHARS = 8000


class Tools:
    def __init__(self):
        pass

    def _k8s_client(self):
        with open("/var/run/secrets/kubernetes.io/serviceaccount/token") as f:
            token = f.read().strip()
        ctx = ssl.create_default_context(
            cafile="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
        )
        headers = {"Authorization": f"Bearer {token}"}

        def get(path):
            req = urllib.request.Request(
                f"https://kubernetes.default.svc{path}", headers=headers
            )
            with urllib.request.urlopen(req, context=ctx, timeout=15) as resp:
                return json.load(resp)

        return get

    def _truncate(self, text):
        if len(text) > MAX_OUTPUT_CHARS:
            return text[:MAX_OUTPUT_CHARS] + f"\n...[truncated, {len(text)} chars total]"
        return text

    def k8s_get(
        self, resource: str, namespace: str = "", name: str = "", label_selector: str = ""
    ) -> str:
        """
        List or get Kubernetes resources (read-only). Supports: nodes, pods,
        services, endpoints, configmaps, events, namespaces, persistentvolumeclaims,
        replicationcontrollers, deployments, replicasets, daemonsets, statefulsets,
        jobs, cronjobs. Does NOT support secrets (never), or any resource not in
        this list -- refuses cleanly instead of erroring.

        :param resource: Resource type, e.g. "pods", "deployments", "events". Plural, lowercase.
        :param namespace: Namespace to scope to. Leave empty to list across all namespaces (for namespaced resources) or omit for cluster-scoped resources (nodes, namespaces).
        :param name: Specific object name. Leave empty to list all matching objects instead of getting one.
        :param label_selector: Optional label selector to filter a list, e.g. "app=open-webui".
        :return: A summary of matching object(s), or a refusal message if the resource isn't allowed.
        """
        resource = resource.lower().strip()
        if resource == "secrets" or resource == "secret":
            return "Refused: this tool never accesses Secrets, by design. Read-only RBAC on other resources doesn't protect secret values."
        if resource not in RESOURCE_MAP:
            return f"Refused: resource '{resource}' is not in the allowed list: {', '.join(sorted(RESOURCE_MAP.keys()))}."

        api_prefix, namespaced = RESOURCE_MAP[resource]
        get = self._k8s_client()

        try:
            if name:
                if namespaced and not namespace:
                    return f"Error: '{resource}' is namespaced -- provide a namespace to get a specific object by name."
                path = f"{api_prefix}/namespaces/{namespace}/{resource}/{name}" if namespaced else f"{api_prefix}/{resource}/{name}"
                obj = get(path)
                return self._truncate(json.dumps(obj, indent=2))
            else:
                if namespaced and namespace:
                    path = f"{api_prefix}/namespaces/{namespace}/{resource}"
                else:
                    path = f"{api_prefix}/{resource}"
                if label_selector:
                    path += "?" + urllib.parse.urlencode({"labelSelector": label_selector})
                data = get(path)
                items = data.get("items", [])
                lines = [f"{len(items)} {resource} found" + (f" (showing first {MAX_LIST_ITEMS})" if len(items) > MAX_LIST_ITEMS else "") + ":"]
                for item in items[:MAX_LIST_ITEMS]:
                    meta = item.get("metadata", {})
                    ns = meta.get("namespace")
                    nm = meta.get("name")
                    status = item.get("status", {})
                    phase = status.get("phase", "")
                    label = f"{ns}/{nm}" if ns else nm
                    lines.append(f"  {label}" + (f" [{phase}]" if phase else ""))
                return self._truncate("\n".join(lines))
        except Exception as e:
            return f"Error: {e}"

    def k8s_describe(self, resource: str, name: str, namespace: str = "") -> str:
        """
        Get full detail for one Kubernetes object plus its recent related Events --
        the events are usually the actual answer to "why is this pending/failing".
        Same resource allowlist as k8s_get (no secrets, ever).

        :param resource: Resource type, e.g. "pods", "deployments".
        :param name: The specific object's name.
        :param namespace: Namespace (required for namespaced resources).
        :return: The object's key fields plus any related events, or a refusal/error message.
        """
        resource = resource.lower().strip()
        if resource == "secrets" or resource == "secret":
            return "Refused: this tool never accesses Secrets, by design."
        if resource not in RESOURCE_MAP:
            return f"Refused: resource '{resource}' is not in the allowed list: {', '.join(sorted(RESOURCE_MAP.keys()))}."

        api_prefix, namespaced = RESOURCE_MAP[resource]
        if namespaced and not namespace:
            return f"Error: '{resource}' is namespaced -- provide a namespace."
        get = self._k8s_client()

        try:
            path = f"{api_prefix}/namespaces/{namespace}/{resource}/{name}" if namespaced else f"{api_prefix}/{resource}/{name}"
            obj = get(path)
            meta = obj.get("metadata", {})

            # Events first, not last -- this is usually the actual answer to
            # "why is this pending/failing", and it's what should survive
            # MAX_OUTPUT_CHARS truncation, not get pushed off the end by a
            # large raw spec dump (confirmed the hard way: a pod with several
            # volumeMounts pushed events past the truncation point entirely
            # before this was fixed).
            lines = []
            if namespaced:
                field_selector = urllib.parse.urlencode(
                    {"fieldSelector": f"involvedObject.name={name},involvedObject.namespace={namespace}"}
                )
                events = get(f"/api/v1/namespaces/{namespace}/events?{field_selector}")
                items = sorted(
                    events.get("items", []),
                    key=lambda e: e.get("lastTimestamp") or e.get("eventTime") or "",
                )
                if items:
                    lines.append("Recent events:")
                    for e in items[-15:]:
                        lines.append(
                            f"  [{e.get('type')}] {e.get('reason')}: {e.get('message')} ({e.get('lastTimestamp') or e.get('eventTime')})"
                        )
                else:
                    lines.append("No related events found.")
                lines.append("")

            # Status conditions (compact) rather than the full status blob --
            # container image/volume-mount details etc. are rarely what's
            # needed to answer "why", and crowd out events/conditions.
            status = obj.get("status", {}) or {}
            conditions = status.get("conditions", [])
            if conditions:
                lines.append("Status conditions:")
                for c in conditions:
                    lines.append(
                        f"  {c.get('type')}={c.get('status')}"
                        + (f" ({c.get('reason')}: {c.get('message')})" if c.get("reason") else "")
                    )
                lines.append("")
            phase = status.get("phase")
            if phase:
                lines.append(f"Phase: {phase}\n")

            summary = {
                "name": meta.get("name"),
                "namespace": meta.get("namespace"),
                "labels": meta.get("labels"),
                "creationTimestamp": meta.get("creationTimestamp"),
                "spec": obj.get("spec"),
            }
            lines.append("Object summary (spec may be truncated below):")
            lines.append(json.dumps(summary, indent=2))

            return self._truncate("\n".join(lines))
        except Exception as e:
            return f"Error: {e}"

    def k8s_logs(self, pod_name: str, namespace: str, container: str = "", tail_lines: int = 100) -> str:
        """
        Read the recent log tail for a pod (read-only; not an interactive shell,
        not exec -- just fetches existing log output).

        :param pod_name: The pod's name.
        :param namespace: The pod's namespace.
        :param container: Container name, if the pod has more than one. Leave empty for single-container pods.
        :param tail_lines: How many recent lines to fetch (default 100, capped at 500).
        :return: The log tail, or an error message.
        """
        tail_lines = min(int(tail_lines) if tail_lines else 100, 500)
        try:
            path = f"/api/v1/namespaces/{namespace}/pods/{pod_name}/log?tailLines={tail_lines}"
            if container:
                path += f"&container={urllib.parse.quote(container)}"
            with open("/var/run/secrets/kubernetes.io/serviceaccount/token") as f:
                token = f.read().strip()
            ctx = ssl.create_default_context(
                cafile="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
            )
            req = urllib.request.Request(
                f"https://kubernetes.default.svc{path}",
                headers={"Authorization": f"Bearer {token}"},
            )
            with urllib.request.urlopen(req, context=ctx, timeout=15) as resp:
                text = resp.read().decode("utf-8", errors="replace")
            return self._truncate(text)
        except Exception as e:
            return f"Error: {e}"
