# Incident: apparent simulation "stall" — 4h workflow timeouts driven by building type

**Date:** 2026-09-05
**Release:** `openstudio-server` (namespace `openstudio-server`), OpenStack/Azimuth cluster
**Reported symptom:** "No progress at `http://10.60.105.249/resque` for a really long time."

## TL;DR

The cluster was never stalled. Throughput was real but badly degraded by three
independent problems, only one of which was a genuine defect:

1. 732 **zombie Resque worker registrations** (pods gone, registration left behind)
   were holding simulation jobs that would never run. *(fixed — pruned + requeued)*
2. 1,125 worker pods were **unschedulable or unpullable**, pinning the HPA at
   `maxReplicas` so it could never react. *(fixed — HPA `maxReplicas` trimmed)*
3. **`SecondarySchool` prototype models take ~15x longer to simulate than the other
   building types in the same batch**, so roughly half of them exceeded the uniform
   4-hour `run_workflow_timeout` and were permanently failed. This accounted for
   **91% of all failed datapoints in the fleet.** *(root-caused, not yet fixed)*

Item 3 is the durable finding and the reason this document exists.

## Root cause of the timeouts

### What it was NOT

Two plausible theories were tested and disproved:

**Not resource contention.** The initial signal looked like classic contention:
average successful-simulation duration climbed from 10.8 min (09-05 09:00 UTC) to
96–129 min (10:00–21:00). But splitting the same hours by analysis cohort shows two
populations running *concurrently, on the same nodes*, with a 15–20x gap:

| Hour (09-05 UTC) | `batch<2000` avg | `batch>=3500` avg |
| ---------------- | ---------------- | ----------------- |
| 10               | 8 min            | 149 min           |
| 12               | 8 min            | 174 min           |
| 16               | 12 min           | 180 min           |
| 20               | 9 min            | 150 min           |
| 22               | 9 min            | 149 min           |

Identical contention, wildly different runtimes. The apparent "slowdown over time"
was a **composition shift** in which analyses happened to be running, not degradation.

**Not I/O, throttling, or CPU starvation.** A live long-running datapoint was
inspected directly on `worker-65f5ffd788-crw8n`:

- EnergyPlus at **99.8% CPU, state `R`**, elapsed 9,248s
- cgroup v2 `cpu.stat` → `nr_throttled=0`, `cpu.max=max` (no throttling)
- `eplusout.err` only 413 KB (1,561 warnings) — not warning-spam bound
- `eplusout.eso` growing ~19 KB/s on NFS — not I/O bound

The process was genuinely computing the whole time, just very slowly.

### What it actually was

The workflow definitions of a fast analysis (`batch3009_proposed_training_...`) and a
slow one (`batch3713_proposed_training_...`) are **byte-identical** — same 21-measure
chain, same `simulation_settings` (4 timesteps/hr, annual 1/1–12/31). The *only*
differing input is `create_bar_from_building_type_ratios.bldg_type_a`.

Aggregating every completed datapoint by that one argument:

| `bldg_type_a`       | datapoints | avg min | vs 240 min timeout          |
| ------------------- | ---------- | ------- | --------------------------- |
| **SecondarySchool** | 45,251     | **159** | mean at 66% — tail blows through |
| PrimarySchool       | 47,268     | 72      | marginal                    |
| RetailStandalone    | 22,525     | 26      | safe                        |
| Warehouse           | 18,500     | 23      | safe                        |
| MediumOffice        | 48,000     | 20      | safe                        |
| RetailStripmall     | 48,000     | 17      | safe                        |
| SmallOffice         | 42,000     | 9       | safe                        |

`SecondarySchool` is a ~108-zone prototype. The `add_heat_pump_rtu` measure converts
those zones to single-zone VAV heat pumps that repeatedly fail to converge —
`eplusout.err` shows recurring:

```
Coil control failed for AirLoopHVAC:UnitarySystem:... RTU SZ-VAV HEAT PUMP
  sensible part-load ratio determined to be outside the range of 0-1
  Air volume flow rate ratio = 5.036E-002
```

Each convergence failure forces EnergyPlus to shrink the HVAC system timestep, so
zone-count and iteration-count multiply. The result is a model that is legitimately
~15x more expensive than its siblings while being given the *same* 4-hour budget.

**The timeout is uniform (`run_workflow_timeout: 14400` on all 768 analyses), so it
explains why slow runs die but not which runs are slow. Building type is the
differentiator.**

## Damage

This build has **no requeue-on-dirty-exit** (`enqueue_to(:requeued)` is commented out
in `ResqueJobs::RunSimulateDataPoint`, and `RunAnalysis` has no requeue path), so a
timed-out datapoint is failed permanently with no retry.

| Building type       | ok      | failed     | fail%    |
| ------------------- | ------- | ---------- | -------- |
| **SecondarySchool** | 24,143  | **22,787** | **48.6** |
| PrimarySchool       | 45,181  | 2,087      | 4.4      |
| all others          | 185,572 | 56         | ~0.0     |
| **Fleet**           | 254,896 | 24,930     | 8.9      |

**91% of every failed datapoint in the fleet is one building type.**

## Recommendations

1. **Size `run_workflow_timeout` per building type, not globally.** At a 159 min mean,
   a 240 min cap truncates the upper half of the `SecondarySchool` distribution.
   Use ~28800 (8h) for school prototypes; the current 14400 is fine for everything else.
2. **Re-run the 22,787 failed `SecondarySchool` datapoints.** They will not retry
   themselves — see the no-requeue note above.
3. **Fix the underlying measure.** The heat-pump RTU convergence failure on multi-zone
   school models is the actual cost driver; raising the timeout only hides it. Worth
   investigating `upgrade_hvac_add_heat_pump_rtu` / `hardsize_model` sizing behavior on
   high-zone-count prototypes.
4. **Calibrate before committing a large batch.** Four building types in the pending
   queue (`FullServiceRestaurant`, `QuickServiceRestaurant`, `MidriseApartment`,
   `HighriseApartment`, `SmallHotel`) had **zero** completed runs at the time of this
   incident, so their runtime was entirely unknown. A short pilot per building type
   would have surfaced the `SecondarySchool` problem before 22,787 datapoints were lost.

## Reproducing the analysis

Runtime by building type (the decisive query). Mongo database is `os_docker`:

```javascript
// map analysis_id -> bldg_type_a
const T = {};
db.analyses.find({}, { name: 1, "problem.workflow": 1 }).forEach(a => {
  if (!a.problem || !a.problem.workflow) return;
  const w = a.problem.workflow.find(x => x.name === "create_bar_from_building_type_ratios");
  if (!w) return;
  const g = (w.arguments || []).find(x => x.name === "bldg_type_a");
  if (g) T[a._id] = g.value;
});

// NOTE: exclude the last 4h. Datapoints started inside the timeout window
// haven't had time to time out yet, which biases the rate downward.
const cut = new Date(Date.now() - 4 * 3600 * 1000);
const r = db.data_points.aggregate([
  { $match: { run_start_time: { $lt: cut, $ne: null }, run_end_time: { $ne: null } } },
  { $project: { analysis_id: 1,
      mins: { $divide: [{ $subtract: ["$run_end_time", "$run_start_time"] }, 60000] } } },
  { $group: { _id: "$analysis_id", n: { $sum: 1 }, s: { $sum: "$mins" } } }
], { allowDiskUse: true }).toArray();

const B = {};
r.forEach(x => { const t = T[x._id]; if (!t) return;
  if (!B[t]) B[t] = { n: 0, s: 0 }; B[t].n += x.n; B[t].s += x.s; });
Object.keys(B).map(k => [k, B[k].n, B[k].s / B[k].n])
  .sort((a, b) => b[2] - a[2])
  .forEach(x => print(x[0] + " dp=" + x[1] + " avg_min=" + x[2].toFixed(0)));
```

To confirm contention is *not* the cause, run the same aggregation bucketed by
`{$dateToString:{format:"%m-%d %H", date:"$run_start_time"}}` for two cohorts and
compare the same hours side by side.

### Gotchas

- Mongo database is **`os_docker`**, not `os_server`.
- Always exclude the trailing 4 hours from any timeout-rate statistic
  (right-censoring), or recent hours will look artificially healthy.
- `mongosh` frequently returns empty output for multi-line `print()` with `\n`.
  Flatten to one line per record and `grep` a prefix.
- The `containerd-registry-config` DaemonSet contributes ~9,000 pods and dominates
  every `kubectl get pods` listing — filter it out.

## Related

- `docs/helm-uninstall-nfs-cleanup-hook-incident.md` — the `pulp-dev` registry outage
  referenced here (unpullable worker images) recurs; same mirror.
- `openstack/values-openstack.yaml.template` — `worker_hpa.maxReplicas` and
  `web_background.worker_memory_mib` comments record the other two fixes.
