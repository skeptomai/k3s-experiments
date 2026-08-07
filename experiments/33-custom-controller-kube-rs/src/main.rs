//! stamp-controller — a minimal, concept-complete kube-rs custom controller.
//!
//! Watches `Stamp` custom resources (group `edu.k3s-experiments.dev`, version
//! `v1alpha1`). For each `Stamp`, reconciles the cluster so that exactly
//! `spec.replicas` ConfigMaps exist, each holding `spec.message` and owned
//! (via `ownerReferences`) by the `Stamp`. `status.readyReplicas` is always
//! recomputed from a live list of matching ConfigMaps — never from an
//! in-memory diff — so reconcile is safe to call redundantly, out of order,
//! or after missed events (level-triggered, not edge-triggered).
//!
//! Named `Stamp` rather than something evocative of an existing protocol —
//! this deliberately "stamps out" N copies of a value into storage. An
//! earlier draft called this `Echo`, which is actively misleading: "echo"
//! implies a request/response round-trip (RFC 862, ping), and nothing here
//! sends anything back to a caller — it just writes N ConfigMaps and reports
//! how many it observes. See issue #15 for the full naming discussion.
//!
//! A finalizer (`edu.k3s-experiments.dev/cleanup`) is added on creation and
//! removed only after explicit cleanup logic confirms the owned ConfigMaps
//! are gone. This is a deliberate teaching device: owner-reference garbage
//! collection would clean the ConfigMaps up anyway, but the finalizer
//! add/block-deletion/cleanup/remove lifecycle is the thing this experiment
//! exists to demonstrate.
//!
//! See experiments/33-custom-controller-kube-rs/README.md and
//! https://github.com/skeptomai/k3s-experiments/issues/15 for the full
//! design rationale.

use std::sync::Arc;
use std::time::Duration;

use clap::Parser;
use futures::StreamExt;
use k8s_openapi::api::core::v1::ConfigMap;
use k8s_openapi::apimachinery::pkg::apis::meta::v1::OwnerReference;
use kube::api::{Api, DeleteParams, ListParams, Patch, PatchParams, PostParams, ResourceExt};
use kube::runtime::controller::{Action, Controller};
use kube::runtime::finalizer::{finalizer, Event as FinalizerEvent};
use kube::runtime::watcher;
use kube::{Client, CustomResource, CustomResourceExt};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use tracing::{error, info, warn};

/// Finalizer name added to every `Stamp` on creation.
const FINALIZER: &str = "edu.k3s-experiments.dev/cleanup";
/// Label placed on every ConfigMap this controller creates, used to find
/// "the ConfigMaps that currently belong to this Stamp" without trusting
/// any in-memory bookkeeping.
const OWNER_LABEL: &str = "edu.k3s-experiments.dev/stamp";
/// Namespace this controller watches. Matches manifests/rbac.yaml's Role,
/// which is namespace-scoped rather than cluster-wide (see the RBAC design
/// note in README.md).
const WATCH_NAMESPACE: &str = "custom-controller-demo";

/// `Stamp` — the primary custom resource this controller reconciles.
///
/// group=edu.k3s-experiments.dev, version=v1alpha1, kind=Stamp, scope=Namespaced.
#[derive(CustomResource, Debug, Clone, Deserialize, Serialize, JsonSchema)]
#[kube(
    group = "edu.k3s-experiments.dev",
    version = "v1alpha1",
    kind = "Stamp",
    namespaced,
    status = "StampStatus",
    shortname = "stamp",
    printcolumn = r#"{"name":"Message","type":"string","jsonPath":".spec.message"}"#,
    printcolumn = r#"{"name":"Replicas","type":"integer","jsonPath":".spec.replicas"}"#,
    printcolumn = r#"{"name":"Ready","type":"integer","jsonPath":".status.readyReplicas"}"#
)]
#[serde(rename_all = "camelCase")]
pub struct StampSpec {
    /// Message written into each owned ConfigMap's data.
    pub message: String,
    /// Desired number of owned ConfigMaps.
    pub replicas: i32,
}

/// `Stamp.status` — always recomputed from a live count of owned ConfigMaps.
#[derive(Debug, Clone, Default, Deserialize, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct StampStatus {
    /// Number of matching ConfigMaps observed in the cluster as of the last
    /// reconcile. Never derived from a diff — always a fresh list+count.
    pub ready_replicas: i32,
}

/// Shared reconciler context.
struct Context {
    client: Client,
}

#[derive(Debug, thiserror::Error)]
enum ReconcileError {
    #[error("Kubernetes API error: {0}")]
    Kube(#[from] kube::Error),
    #[error("finalizer error: {0}")]
    Finalizer(#[from] Box<kube::runtime::finalizer::Error<ReconcileError>>),
}

/// Returns the ConfigMaps currently owned by `stamp`, found by label selector
/// (not by trusting any in-memory record of what was previously created).
async fn owned_configmaps(
    client: &Client,
    namespace: &str,
    stamp_name: &str,
) -> Result<Vec<ConfigMap>, kube::Error> {
    let cms: Api<ConfigMap> = Api::namespaced(client.clone(), namespace);
    let lp = ListParams::default().labels(&format!("{OWNER_LABEL}={stamp_name}"));
    Ok(cms.list(&lp).await?.items)
}

/// Builds the ConfigMap manifest for replica index `i` of `stamp`, with an
/// ownerReference back to it so Kubernetes GC (and `.owns()` watches) apply.
fn build_configmap(stamp: &Stamp, i: i32) -> ConfigMap {
    let name = stamp.name_any();
    let uid = stamp.uid().expect("Stamp must have a uid to build owner refs");
    let owner_ref = OwnerReference {
        api_version: "edu.k3s-experiments.dev/v1alpha1".to_string(),
        kind: "Stamp".to_string(),
        name: name.clone(),
        uid,
        controller: Some(true),
        block_owner_deletion: Some(true),
    };

    let mut labels = std::collections::BTreeMap::new();
    labels.insert(OWNER_LABEL.to_string(), name.clone());

    let mut data = std::collections::BTreeMap::new();
    data.insert("message".to_string(), stamp.spec.message.clone());

    ConfigMap {
        metadata: kube::api::ObjectMeta {
            name: Some(format!("{name}-{i}")),
            namespace: stamp.namespace(),
            labels: Some(labels),
            owner_references: Some(vec![owner_ref]),
            ..Default::default()
        },
        data: Some(data),
        ..Default::default()
    }
}

/// Explicit finalizer cleanup: delete every ConfigMap still labeled as
/// belonging to this Stamp, then confirm none remain. Owner-reference GC
/// would eventually remove these anyway; this exists to demonstrate the
/// finalizer's own cleanup-then-confirm lifecycle, not because it is
/// strictly necessary here.
async fn cleanup(client: &Client, stamp: &Stamp) -> Result<Action, ReconcileError> {
    let ns = stamp.namespace().unwrap_or_else(|| "default".to_string());
    let name = stamp.name_any();
    info!(stamp = %name, namespace = %ns, "finalizer cleanup: deleting owned ConfigMaps");

    let cms: Api<ConfigMap> = Api::namespaced(client.clone(), &ns);
    let existing = owned_configmaps(client, &ns, &name).await?;
    for cm in &existing {
        let cm_name = cm.name_any();
        info!(stamp = %name, configmap = %cm_name, "deleting owned ConfigMap");
        match cms.delete(&cm_name, &DeleteParams::default()).await {
            Ok(_) => {}
            Err(kube::Error::Api(e)) if e.code == 404 => {}
            Err(e) => return Err(e.into()),
        }
    }

    // Confirm cleanup actually converged before letting the finalizer be
    // removed — this confirm-then-remove step is the point of the exercise.
    let remaining = owned_configmaps(client, &ns, &name).await?;
    if remaining.is_empty() {
        info!(stamp = %name, "cleanup confirmed: no owned ConfigMaps remain, finalizer will be removed");
    } else {
        warn!(
            stamp = %name,
            remaining = remaining.len(),
            "cleanup issued deletes but ConfigMaps still visible; will retry"
        );
        return Ok(Action::requeue(Duration::from_secs(2)));
    }

    Ok(Action::await_change())
}

/// Core reconcile: convergent, level-triggered, idempotent.
///
/// Always: (1) ensure exactly `spec.replicas` owned ConfigMaps exist with
/// the right content, by listing what's actually present rather than
/// trusting any diff; (2) recount actual owned ConfigMaps and write that
/// (not the desired count) to `status.readyReplicas`.
async fn apply(client: &Client, stamp: &Stamp) -> Result<Action, ReconcileError> {
    let ns = stamp.namespace().unwrap_or_else(|| "default".to_string());
    let name = stamp.name_any();
    let desired = stamp.spec.replicas.max(0);

    let cms: Api<ConfigMap> = Api::namespaced(client.clone(), &ns);
    let existing = owned_configmaps(client, &ns, &name).await?;

    // Index existing ConfigMaps by name so we can tell which desired slots
    // are already satisfied vs. need creating, and which extras (e.g. after
    // a scale-down) need deleting. No in-memory diff from a prior
    // reconcile is used — `existing` is a fresh list from the API server.
    let mut existing_by_name: std::collections::HashMap<String, ConfigMap> = existing
        .into_iter()
        .map(|cm| (cm.name_any(), cm))
        .collect();

    for i in 0..desired {
        let cm_name = format!("{name}-{i}");
        let desired_cm = build_configmap(stamp, i);

        match existing_by_name.remove(&cm_name) {
            Some(current) => {
                let current_message = current
                    .data
                    .as_ref()
                    .and_then(|d| d.get("message"))
                    .cloned()
                    .unwrap_or_default();
                if current_message != stamp.spec.message {
                    info!(stamp = %name, configmap = %cm_name, "message drifted, re-applying");
                    cms.patch(
                        &cm_name,
                        &PatchParams::apply("stamp-controller"),
                        &Patch::Apply(&desired_cm),
                    )
                    .await?;
                }
            }
            None => {
                info!(stamp = %name, configmap = %cm_name, "creating owned ConfigMap");
                match cms.create(&PostParams::default(), &desired_cm).await {
                    Ok(_) => {}
                    Err(kube::Error::Api(e)) if e.code == 409 => {
                        // Already exists (e.g. from a concurrent reconcile) —
                        // fine, level-triggered means we'll converge next pass.
                    }
                    Err(e) => return Err(e.into()),
                }
            }
        }
    }

    // Anything left in existing_by_name is beyond the desired count
    // (e.g. spec.replicas was scaled down) — delete it.
    for (cm_name, _) in existing_by_name {
        info!(stamp = %name, configmap = %cm_name, "deleting excess ConfigMap");
        match cms.delete(&cm_name, &DeleteParams::default()).await {
            Ok(_) => {}
            Err(kube::Error::Api(e)) if e.code == 404 => {}
            Err(e) => return Err(e.into()),
        }
    }

    // Recount from the live cluster state — never trust `desired` or any
    // count derived from the create/delete calls just made above.
    let actual = owned_configmaps(client, &ns, &name).await?.len() as i32;

    let stamps: Api<Stamp> = Api::namespaced(client.clone(), &ns);
    let status_patch = serde_json::json!({
        "status": { "readyReplicas": actual }
    });
    stamps
        .patch_status(
            &name,
            &PatchParams::apply("stamp-controller"),
            &Patch::Merge(&status_patch),
        )
        .await?;
    info!(stamp = %name, desired, actual, "reconciled");

    Ok(Action::requeue(Duration::from_secs(300)))
}

/// Top-level reconcile function handed to `Controller::run`. Delegates to
/// `kube::runtime::finalizer` to drive the add/cleanup/remove lifecycle
/// around the actual `apply`/`cleanup` logic above.
async fn reconcile(stamp: Arc<Stamp>, ctx: Arc<Context>) -> Result<Action, ReconcileError> {
    let ns = stamp.namespace().unwrap_or_else(|| "default".to_string());
    let stamps: Api<Stamp> = Api::namespaced(ctx.client.clone(), &ns);

    finalizer(&stamps, FINALIZER, stamp, |event| async {
        match event {
            FinalizerEvent::Apply(stamp) => apply(&ctx.client, &stamp).await,
            FinalizerEvent::Cleanup(stamp) => cleanup(&ctx.client, &stamp).await,
        }
    })
    .await
    .map_err(|e| ReconcileError::Finalizer(Box::new(e)))
}

fn error_policy(stamp: Arc<Stamp>, err: &ReconcileError, _ctx: Arc<Context>) -> Action {
    error!(stamp = %stamp.name_any(), error = %err, "reconcile failed, requeueing");
    Action::requeue(Duration::from_secs(10))
}

#[derive(Parser, Debug)]
#[command(about = "stamp-controller: kube-rs teaching controller for the Stamp CRD")]
struct Cli {
    /// Print the Stamp CustomResourceDefinition as YAML and exit, instead of
    /// running the controller. Lets the CRD manifest be generated from the
    /// Rust type (source of truth) rather than hand-written.
    #[arg(long)]
    print_crd: bool,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();

    if cli.print_crd {
        let crd = Stamp::crd();
        println!("{}", serde_yaml::to_string(&crd)?);
        return Ok(());
    }

    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "info".into()),
        )
        .init();

    let client = Client::try_default().await?;
    // RBAC for this controller is deliberately namespace-scoped (see
    // manifests/rbac.yaml) rather than a ClusterRole, so watches must be
    // namespaced too, not Api::all() (cluster-scoped list/watch).
    let stamps = Api::<Stamp>::namespaced(client.clone(), WATCH_NAMESPACE);
    let configmaps = Api::<ConfigMap>::namespaced(client.clone(), WATCH_NAMESPACE);

    info!(
        namespace = WATCH_NAMESPACE,
        "stamp-controller starting, watching Stamp (edu.k3s-experiments.dev/v1alpha1)"
    );

    Controller::new(stamps, watcher::Config::default())
        .owns(configmaps, watcher::Config::default())
        .shutdown_on_signal()
        .run(reconcile, error_policy, Arc::new(Context { client }))
        .for_each(|res| async move {
            match res {
                Ok((obj_ref, _action)) => info!(?obj_ref, "reconcile succeeded"),
                Err(err) => error!(error = %err, "reconcile error"),
            }
        })
        .await;

    Ok(())
}
