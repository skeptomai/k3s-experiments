# Reconcile Loop Internals — Tracing kube-runtime's Source

A companion deep-dive to [`README.md`](README.md) and
[issue #15](https://github.com/skeptomai/k3s-experiments/issues/15). Where
those cover *what* this controller does, this covers *how kube-runtime
actually calls `reconcile()`* — traced against the real dependency source on
disk, not inferred from documentation. Every excerpt below is quoted
verbatim from:

```
~/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/kube-runtime-4.2.0/src/
```

(`kube-runtime = 4.2.0`, pinned via the `kube` dependency in `Cargo.toml`.
Line numbers are only valid for that exact version — if the pinned version
ever changes, this doc should be re-verified against the new source rather
than trusted as-is.)

## Two independent trigger mechanisms

`reconcile()` gets called for two structurally different reasons, and it's
worth keeping them separate:

1. **Real watch events** — something actually changed in the cluster (a
   `Stamp` was created/updated/deleted, or an owned `ConfigMap` was).
2. **Self-scheduled requeues** — the `Action` value a previous reconcile
   *returned* asked to be called again after some duration, regardless of
   whether anything else happens.

Both funnel into the same underlying stream/queue machinery, described
below.

## Trigger 1: watch events

### `Controller::new` — the watch on the primary resource (`Stamp`)

`controller/mod.rs:745` (`new_with`, called by `new` at line 724):

```rust
let self_watcher = trigger_self(
    reflector(writer, watcher(main_api, wc)).applied_objects(),
    dyntype.clone(),
).boxed();
trigger_selector.push(self_watcher);
```

`watcher(main_api, wc)` is the literal call that opens the watch on `Stamp`.
`reflector(...)` wraps it with a local cache (the `Store` that `apply()`
etc. never actually read from directly, since this controller always
re-lists from the live API instead — but it's what backs `Runner`'s object
lookups, see Trigger dispatch below). `trigger_self(...)` turns raw watch
events into "reconcile this object" requests. The result is pushed into
`trigger_selector`, a `futures::stream::SelectAll` — a combinator that
merges multiple independent event streams into one.

### `.owns()` — the watch on the owned resource (`ConfigMap`)

`controller/mod.rs:1004` (`owns_with`, called by `owns` at line 992):

```rust
let child_watcher = trigger_owners(
    metadata_watcher(api, wc).touched_objects(),
    self.dyntype.clone(),
    dyntype,
);
self.trigger_selector.push(child_watcher.boxed());
```

`metadata_watcher` (not the full `watcher`) is used here deliberately — it
only needs each ConfigMap's metadata (including `ownerReferences`), not its
full body, to know *which* `Stamp` to re-trigger. `trigger_owners(...)` does
that mapping. Pushed into the *same* `trigger_selector` as the self-watch —
this is the concrete mechanism behind the abstract "owned resources also
trigger the parent's reconcile" description in README.md.

### `.run()` — wiring the merged watch stream to your reconcile function

`controller/mod.rs:1683`:

```rust
pub fn run<...>(self, mut reconciler: ..., error_policy: ..., context: ...)
    -> impl Stream<Item = Result<(ObjectRef<K>, Action), Error<...>>>
{
    applier(
        move |obj, ctx| CancelableJoinHandle::spawn(reconciler(obj, ctx), ...),
        error_policy, context, self.reader,
        StreamBackoff::new(self.trigger_selector, self.trigger_backoff)...,
        self.config,
    )...
}
```

Note the return type: `impl Stream<...>`. Calling `.run()` does not start
anything — it *constructs* a `Stream` value describing the whole reconcile
loop. In Rust, a `Stream` (like a `Future`) is inert data until something
polls it.

## Trigger 2: self-scheduled `Action`

`apply()`/`cleanup()`/`error_policy()` in `src/main.rs` return `Action`
values that ask to be called again later regardless of any real event:

```rust
Ok(Action::requeue(Duration::from_secs(300)))   // apply() success
Ok(Action::requeue(Duration::from_secs(2)))     // cleanup(), still cleaning up
Ok(Action::await_change())                      // cleanup() success — no self-requeue
Action::requeue(Duration::from_secs(10))        // error_policy(), any failure
```

This is what keeps a healthy, *unchanged* `Stamp` being reconciled roughly
every 300 seconds, forever — not because kube-runtime has some blanket
resync timer (`watcher::Config::default()` configures no such thing), but
because `apply()` explicitly asks for it every single time it succeeds.

## `applier()` — where `reconciler(...)` is actually called

`controller/mod.rs:399`, inside a `Runner`-driven closure:

```rust
Runner::new(
    debounced_scheduler(s, config.debounce),
    config.concurrency,
    move |request| {
        ...
        TryFutureExt::into_future(
            reconciler_span.in_scope(|| reconciler(Arc::clone(&obj), context.clone()))
        )
        .then(move |res| {
            RescheduleReconciliation::new(res, |err| error_policy(obj, err, error_policy_ctx),
                request.obj_ref.clone(), scheduler_tx)
        })
    },
)
```

`reconciler(Arc::clone(&obj), context.clone())` — that call *is* our
`reconcile()` function being invoked. `obj` comes from the reflector's
`Store` (populated by the watch), keyed by whatever `ObjectRef` triggered
this dispatch.

## What actually happens when a requeue timer "fires"

This is the part worth being precise about: **the same `Future` instance
from the previous reconcile does not get re-polled.** It already resolved
and was dropped. What happens instead is a *new* reconcile gets scheduled
and, later, dispatched as a fresh call. Traced end to end:

**1. The instant your reconcile future resolves**, `.then(...)` runs
`RescheduleReconciliation::new` (`controller/mod.rs:518`):

```rust
let reconciler_finished_at = Instant::now();
...
reschedule_request: action.requeue_after.map(|requeue_after| ScheduleRequest {
    message: ReconcileRequest { obj_ref, reason: ... },
    run_at: reconciler_finished_at.checked_add(requeue_after)...,
})
```

`run_at` — a concrete wall-clock deadline (`now + 300s`) — is computed
immediately. `RescheduleReconciliation`'s own `poll()` (line 551) sends
that `ScheduleRequest` into an internal `mpsc` channel right away too. None
of this step is delayed — the *request* to be reconciled again later is
recorded instantly; only the *reconciliation itself* is deferred.

**2. Where the waiting actually happens.** That message flows into
`debounced_scheduler(...)` (`scheduler.rs:290`), which constructs a
`Scheduler<T, R>`:

```rust
use tokio_util::time::delay_queue::{self, DelayQueue};
...
pub struct Scheduler<T, R> {
    ...
    queue: DelayQueue<T>,
}
```

`DelayQueue` (from `tokio-util`) is a general-purpose primitive for exactly
this: hold N items, each tagged with a deadline, and yield each one via
`poll_next` only once its deadline has passed. It registers with Tokio's
own timer wheel. While an item's deadline hasn't arrived, polling
`Scheduler` returns `Poll::Pending` — it does not busy-loop or re-check on
a fixed interval. It parks, and Tokio's timer driver holds a `Waker` that
it calls at (approximately) the exact moment the deadline passes.

**3. The wake.** When the deadline hits, Tokio's timer driver invokes that
stored `Waker`. This wakes the task currently polling the `Scheduler`
stream — part of the same merged stream chain the program's top-level
`.for_each(...).await` (in `main()`) is ultimately driving. Being woken
causes that task to be re-polled by the executor, which is what lets
`Scheduler` actually yield the now-ready `ReconcileRequest`. That flows on
into `Runner`, which constructs a **brand-new**
`reconciler(Arc::clone(&obj), context.clone())` call — fetching the object
fresh from the `Store` at that moment — and spawns it via
`CancelableJoinHandle::spawn`, exactly like any watch-triggered dispatch.

**So, precisely**: timer fires → wakes the task polling the scheduling
stream → that stream yields the pending request → a *new* `reconcile()`
invocation gets constructed and spawned. From the executor's point of
view, a fired timer and a byte arriving on the watch's HTTP connection are
the same kind of thing: a `Waker` being called, causing something to be
re-polled. What differs is only what gets constructed as a result — for a
watch event, the object's *current* state from the reflector; for a timer,
whatever the `ReconcileRequest` in the `DelayQueue` still points at.

## Why this matters for the level-triggered design

None of this scheduling machinery cares *why* `reconcile()` is being
called — a watch event and a 300-second timer both just enqueue "go
reconcile this object." That's exactly why `apply()` is written to never
trust anything about *how* it was triggered (see the doc comment on
`apply()` and on `stamped_message()` in `src/main.rs`): it always
re-lists ConfigMaps from the API server and recomputes from scratch. The
dispatch layer traced above is edge-triggered in the literal
implementation sense (each trigger is a discrete event/wake), but the
*reconcile logic itself* is level-triggered by design — the two are
independent, and conflating them is a common source of real controller
bugs.
