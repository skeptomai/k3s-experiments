"""
title: Cluster Health
description: Check k3s cluster node/pod health and CPU temperatures.
"""

import json
import urllib.request
import urllib.parse
import ssl


class Tools:
    def __init__(self):
        pass

    def cluster_health(self) -> str:
        """
        Check the k3s cluster's health: node readiness, any pods that aren't
        Running/Succeeded, and per-node CPU package temperatures. Use this
        whenever asked to check cluster health, cluster status, or node
        temperatures -- don't guess, call this instead.

        :return: A human-readable summary of node status, problem pods, and temps.
        """
        lines = []

        # --- k8s API: node + pod status, via the in-cluster ServiceAccount ---
        try:
            with open("/var/run/secrets/kubernetes.io/serviceaccount/token") as f:
                token = f.read().strip()
            ctx = ssl.create_default_context(
                cafile="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
            )
            headers = {"Authorization": f"Bearer {token}"}

            def k8s_get(path):
                req = urllib.request.Request(
                    f"https://kubernetes.default.svc{path}", headers=headers
                )
                with urllib.request.urlopen(req, context=ctx, timeout=10) as resp:
                    return json.load(resp)

            nodes = k8s_get("/api/v1/nodes")
            node_lines = []
            for item in nodes.get("items", []):
                name = item["metadata"]["name"]
                conditions = item.get("status", {}).get("conditions", [])
                ready = next(
                    (c["status"] for c in conditions if c["type"] == "Ready"), "Unknown"
                )
                node_lines.append(f"  {name}: {'Ready' if ready == 'True' else 'NotReady'}")
            lines.append("Nodes:\n" + "\n".join(node_lines))

            pods = k8s_get("/api/v1/pods")
            problem_pods = []
            for item in pods.get("items", []):
                phase = item.get("status", {}).get("phase", "Unknown")
                if phase in ("Running", "Succeeded"):
                    continue
                ns = item["metadata"]["namespace"]
                name = item["metadata"]["name"]
                problem_pods.append(f"  {ns}/{name}: {phase}")
            if problem_pods:
                lines.append("Pods not Running/Succeeded:\n" + "\n".join(problem_pods))
            else:
                lines.append("Pods: all Running or Succeeded.")
        except Exception as e:
            lines.append(f"Error querying k8s API: {e}")

        # --- Prometheus: per-node CPU package temp + Spark GPU temp ---
        try:
            query = urllib.parse.quote(
                'node_hwmon_temp_celsius{chip="platform_coretemp_0",sensor="temp1"}'
            )
            url = f"http://192.168.89.2:9090/api/v1/query?query={query}"
            with urllib.request.urlopen(url, timeout=10) as resp:
                data = json.load(resp)
            temp_lines = []
            for r in data.get("data", {}).get("result", []):
                node = r["metric"].get("node", "?")
                val = float(r["value"][1])
                temp_lines.append(f"  {node}: {val:.0f}°C")
            if temp_lines:
                lines.append("CPU package temps:\n" + "\n".join(sorted(temp_lines)))

            gpu_url = (
                "http://192.168.89.2:9090/api/v1/query?query=spark_gpu_temperature_celsius"
            )
            with urllib.request.urlopen(gpu_url, timeout=10) as resp:
                gpu_data = json.load(resp)
            gpu_results = gpu_data.get("data", {}).get("result", [])
            if gpu_results:
                gpu_val = float(gpu_results[0]["value"][1])
                lines.append(f"Spark GPU temp: {gpu_val:.0f}°C")
        except Exception as e:
            lines.append(f"Error querying Prometheus: {e}")

        return "\n\n".join(lines)
