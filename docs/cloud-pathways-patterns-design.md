# Design: Cloud Pathways Patterns for OpenStudio Server Deployment

**Status:** Draft design note — for review, no implementation yet
**Date:** 9 Nov 2026
**Companion document:** The application-side half of this design lives in
[NatLabRockies/OpenStudio-server](https://github.com/NatLabRockies/OpenStudio-server)
at `doc/cloud_pathways_patterns_design.md`. This document covers what the
Helm chart can express; that document covers the run-controller logic the
chart deploys but cannot implement.
**Source:** Google Cloud Blog, "Cloud Pathways, a distributed ML runtime,
is GA" (9 Nov 2026)

## Recommendation

Do **not** adopt Cloud Pathways. It is a JAX runtime for Google Cloud TPUs
(v5e / v5p / Trillium v6e / Ironwood 7x) on GKE, requiring JAX 0.10.1+.
OpenStudio / EnergyPlus workloads are CPU-based, embarrassingly parallel
simulations — no accelerator, no JAX, no inter-simulation communication.

**Do adopt three of its patterns**, using native Kubernetes primitives.
Pathways is Google's production answer, at Gemini scale, to problems this
deployment also has: a long run should not die because one worker died,
one controller should see the whole run, and heavy data work should happen
on the worker node, not through the controller. All three apply to
refactoring simulations into Kubernetes Jobs with advanced scaling
(e.g. Karpenter). This repo is the implementation surface for patterns
2 and 3, and the deployment surface for pattern 1.

## The patterns, as chart work

### 1. Single-controller orchestration (deployment surface)

Express each datapoint as an idempotent Kubernetes Job from a chart
template. Deploy the run controller as the sole writer of run state, with
its run manifest (inputs, seed, measure versions, weather-file hash) in
object storage, configured through chart values, so any controller replica
can resume a run. The reconciliation logic itself is application work —
see the companion document in OpenStudio-server.

### 2. Elastic fault tolerance — survive N-1 workers

A node loss, spot interruption, or Karpenter consolidation event should
cost at most the in-flight datapoints, never the analysis, and completed
datapoints are never re-run. In chart terms: datapoint-granularity
checkpointing, where a datapoint is done only when its outputs are
committed to object storage with a completion marker; Job backoff limits
and Pod disruption settings that let scale-in drain rather than kill; and
priority classes that protect the controller and web tiers over workers.

### 3. Colocated sidecars

Add an init/sidecar pair to the datapoint Job template, sharing an
`emptyDir` workspace with the OpenStudio container. The sidecar fetches
the OSW, measures, and weather file, verifies hashes, and on completion
uploads results and logs and writes the completion marker — even if the
simulation container crashes. This also gives future pre/post-processing
(e.g. surrogate-model inputs) a home without changing the simulation image.

Lower priority: Pathways' shared, long-running pool tapped interactively
from notebooks maps to a shared OpenStudio Server pool for exploratory
runs. Defer until patterns 1–3 land — interactive sharing multiplies
scheduling and fairness problems.

## What not to copy

TPU/GKE lock-in; a single controller as an unprotected single point of
failure (a self-hosted controller needs restart-from-manifest); and
hyperscale assumptions. Pathways overhead pays off at thousands of
accelerators and is a net cost at small scale.

## Proposed test

Run one representative analysis on the refactored Jobs path and report:
(1) kill a worker node mid-run — does the run complete, re-running only
in-flight datapoints? (2) restart the controller mid-run — does it resume
with no duplicate completed work? (3) wall-clock and cost vs. the current
path at the same datapoint count. Passing all three is the gate for
making this the default execution path.

---

*Prepared from the GA announcement only. No Pathways evaluation, GCP
account, or TPU access is proposed. Revisit adoption only if a future
surrogate-model effort is written in JAX, trained at large scale, and
funded for GCP TPUs.*
