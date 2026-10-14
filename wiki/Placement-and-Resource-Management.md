# Placement & Resource Management

This page explains how the cluster allocates resources, calculates available memory without races, and enforces multi-layer isolation boundaries.

---

## 1. The Placement Challenge

Naive VM placement implementations typically suffer from two catastrophic flaws:
1. **Lazy Page Fault Inaccuracy**: When a guest boots, Linux KVM does not allocate all guest RAM upfront; memory pages are faulted in dynamically as the guest accesses them. Inspecting `/proc/meminfo` (`MemAvailable`) alone will make a host appear to have abundant free RAM even when heavily overcommitted.
2. **Allocation Concurrency Races**: If two concurrent creation requests arrive simultaneously, both read the same snapshot of host memory and place VMs on the same node, leading to out-of-memory kernel kills (`oom-killer`).

---

## 2. Dual-View Memory Placement Algorithm

To solve these problems, the controller computes the **Effective Free Memory** (`free_effective`) by taking the minimum of the **live host view** and the **committed inventory view**:

$$\text{free\_effective} = \min\Big(\text{MemAvailable} - \text{reserve},\; \text{Total} - \text{reserve} - \sum_{\text{VM} \in \text{Node}} \text{RAM}_{\text{guest}}\Big)$$

- **`MemAvailable`**: Live unallocated and reclaimable page cache reported by `/proc/meminfo` on the worker.
- **`reserve`**: Fixed host headroom (default: `512 MiB`) reserved strictly for the host kernel, system daemons, and `cloud-hypervisor` overhead.
- **$\sum \text{RAM}_{\text{guest}}$**: Sum of all memory allocated to non-deleted VMs in the controller SQLite inventory.

### Placement Step-by-Step

```
[Incoming POST /v1/vms Request]
              |
              v
[Acquire Controller Global Placement Lock]
              |
              +---> Step 1: Query GET /v1/capacity from all HEALTHY workers (timeout: 2s)
              |
              +---> Step 2: Compute free_effective for each node
              |
              +---> Step 3: Filter candidates where free_effective >= requested_memory
              |
      +-------+-------+
      |               |
 [No Candidates]  [Candidates Found]
      |               |
      v               +---> Step 4: Pick Worker via Policy:
[HTTP 409 Conflict]         - Worst-Fit (Default): argmax(free_effective) -> Balances load
                            - Best-Fit: argmin(free_effective) -> Consolidates workloads
                            - Tie-breaker: Node with fewest active VMs, then alphabetical
                      |
                      +---> Step 5: Write-Ahead Allocation in SQLite:
                      |     INSERT INTO vms (..., state="PENDING", reserved_mib=M)
                      |
[Release Placement Lock]
              |
              v
[Invoke Worker: POST /v1/vms]
              |
      +-------+-------+
      |               |
   Success         Failure
      |               |
      v               v
 [State=CREATED] [State=FAILED, Release SQLite Reservation, Rollback Worker]
```

---

## 3. Three-Layer Resource Limit Enforcement

Resource limits are strictly enforced at three distinct layers:

```
+-------------------------------------------------------------------------------+
| LAYER 1: Admission Control (Controller & Worker)                              |
| - Verifies requested flavor against pre-defined templates                     |
| - Validates minimum/maximum limits (e.g., 1-8 vCPUs, 512 MiB - 16 GiB RAM)    |
| - Worker rejects unvetted controller requests independently                   |
+-------------------------------------------------------------------------------+
                                        |
                                        v
+-------------------------------------------------------------------------------+
| LAYER 2: Hypervisor Configuration (Cloud Hypervisor API)                      |
| - Configures exact vCPU limits: boot_vcpus = max_vcpus = N                    |
| - Allocates exact guest memory: memory.size = bytes                           |
| - Configures virtio rate-limiting and device parameters                       |
+-------------------------------------------------------------------------------+
                                        |
                                        v
+-------------------------------------------------------------------------------+
| LAYER 3: Linux Host Hard Caps (cgroup v2)                                     |
| - memory.max = Guest Memory + 128 MiB (Absorbs VMM heap, forbids leaks)       |
| - cpu.max = N * 100000 100000 (Prevents host CPU starvation)                  |
| - pids.max = 32 (Prevents fork-bombs and runaway helper threads)              |
+-------------------------------------------------------------------------------+
```

### Supported Machine Flavors

| Flavor Name | vCPUs | Guest Memory | cgroup `memory.max` | cgroup `cpu.max` | Typical Workload |
|---|---|---|---|---|---|
| **`small`** | 1 | 512 MiB | 640 MiB | `100000 100000` | Microservices, DNS, proxy |
| **`medium`** | 2 | 1024 MiB | 1152 MiB | `200000 100000` | Web applications, APIs |
| **`large`** | 4 | 2048 MiB | 2176 MiB | `400000 100000` | Build nodes, data processing |

---

## 4. Storage Resource Management

1. **Reflink Copy Provisioning (`cp --reflink=auto`)**:
   - On copy-on-write filesystems (Btrfs, XFS), guest root disks are cloned in milliseconds using metadata extents without duplicating data blocks on disk.
2. **Disk Free Space Admission Guard**:
   - Before accepting a new VM, the worker agent verifies that `/var/lib/hvagent` has at least `base_image_size + 2 GiB` of physical disk free.
3. **Storage Cleanup Guarantee**:
   - VM disks are isolated inside `/var/lib/hvagent/vms/<id>/disk.raw`. During VM deletion, this entire directory is deleted, ensuring no orphaned disk images leak across reboots.
