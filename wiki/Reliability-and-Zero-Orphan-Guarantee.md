# Reliability & Zero-Orphan Guarantee

A central requirement of **PS-023** is that API failures, network partitions, or daemon crashes must never leak background processes, unmanaged sockets, or phantom storage allocations.

This page explains how the controller and worker agents achieve **zero orphaned VMs by construction**.

---

## 1. Where Orphaned VMs Come From

In conventional process-per-VM hypervisors like Cloud Hypervisor or Firecracker:
1. **Worker Crash**: If the worker agent panics or is killed (`kill -9`), hypervisor processes become orphaned, adopted by PID 1 (`init`/`systemd`), continuing to run and hold host memory indefinitely.
2. **Partial Provisioning Failures**: If disk creation succeeds, but `vm.create` fails or the process dies before registering, residual files and cgroups remain on the filesystem.
3. **Double-Forking / Process Escapes**: Standard `kill(pid, SIGTERM)` only targets the main thread. If helper processes or threads escape, they stay resident.
4. **Network Partitions**: A controller might mark a VM as `FAILED` while the worker continues to run it.

---

## 2. Six Defense Primitives for Zero Orphans

```
+---------------------------------------------------------------------------------------+
| 1. Dedicated cgroup v2 per VM                                                         |
| Every VM lives in /sys/fs/cgroup/hvagent/<id>/. Writing "1" to cgroup.kill terminates |
| all threads and subprocesses synchronously at the kernel level.                       |
+---------------------------------------------------------------------------------------+
                                           |
                                           v
+---------------------------------------------------------------------------------------+
| 2. Kernel Parent-Death Signal (PR_SET_PDEATHSIG)                                      |
| Child hypervisors are spawned with prctl(PR_SET_PDEATHSIG, SIGKILL). If hvagent dies, |
| the Linux kernel delivers SIGKILL to the hypervisors immediately.                     |
+---------------------------------------------------------------------------------------+
                                           |
                                           v
+---------------------------------------------------------------------------------------+
| 3. Write-Ahead Metadata (meta.json)                                                   |
| State is committed to disk before executing hypervisor operations. During recovery,   |
| the agent reads meta.json to identify and reap half-provisioned instances.            |
+---------------------------------------------------------------------------------------+
                                           |
                                           v
+---------------------------------------------------------------------------------------+
| 4. Atomic Compensating Undo Chains                                                    |
| Multi-step actions register rollback closures. If any step fails, the undo stack     |
| unwinds in reverse order, cleaning disks, cgroups, and sockets.                       |
+---------------------------------------------------------------------------------------+
                                           |
                                           v
+---------------------------------------------------------------------------------------+
| 5. Periodic Dual-Tier Reconciler Loop (Every 15s)                                     |
| Cross-checks Controller Inventory (D1), Agent Metadata (D2), and live OS processes.  |
| Discrepancies trigger automatic cleanup or state correction.                          |
+---------------------------------------------------------------------------------------+
                                           |
                                           v
+---------------------------------------------------------------------------------------+
| 6. Crash Recovery on Startup                                                          |
| On daemon restart, agents reconcile filesystem state against OS processes before      |
| opening their listening ports to new traffic.                                         |
+---------------------------------------------------------------------------------------+
```

---

## 3. Atomic Undo Rollback Implementation

When `hvagent` provisions a virtual machine, it registers compensating actions on an execution stack:

```python
def agent_create_vm(vm_id: str, spec: VmSpec):
    undo_stack = []
    write_ahead_meta(vm_id, spec, status="CREATING")
    
    try:
        # Step 1: Clone disk image
        disk_path = clone_disk(BASE_IMAGE, vm_id)
        undo_stack.append(lambda: unlink_if_exists(disk_path))
        
        # Step 2: Create cgroup hierarchy and set resource limits
        cg = setup_cgroup(vm_id, spec)
        undo_stack.append(lambda: kill_and_remove_cgroup(cg))
        
        # Step 3: Spawn cloud-hypervisor binary with death-signal
        proc = spawn_hypervisor(vm_id, cg, pdeathsig=signal.SIGKILL)
        undo_stack.append(lambda: terminate_process(proc))
        
        # Step 4: Wait for UNIX socket responsiveness
        wait_socket_ping(vm_id, timeout_sec=5.0)
        
        # Step 5: Configure VM parameters in Cloud Hypervisor
        ch_client.vm_create(vm_id, spec, disk_path)
        
        # Commit success
        update_meta(vm_id, status="CREATED", pid=proc.pid)
        return {"status": "CREATED", "pid": proc.pid}
        
    except Exception as exc:
        # Execute registered rollbacks in reverse order
        for rollback in reversed(undo_stack):
            try:
                rollback()
            except Exception:
                pass
        delete_meta(vm_id)
        raise exc
```

---

## 4. Dual-Tier Reconciliation Loops

### 4.1 Node Reconciler (`hvagent` - Runs every 15 seconds)

```
[Start Worker Reconciler Tick]
              |
              +---> Step 1: Scan /sys/fs/cgroup/hvagent/* and pgrep cloud-hypervisor
              |
              +---> Step 2: Read all /var/lib/hvagent/vms/*/meta.json
              |
              +---> Step 3: Identify Orphan Processes
              |     For process in (Live_Processes - Known_Meta):
              |         cgroup.kill(process) -> Destroy unknown rogue processes
              |
              +---> Step 4: Identify Missing Hypervisors
              |     For vm in Known_Meta where status == "RUNNING" and pid not in Live_Processes:
              |         meta.update(status="FAILED")
              |         Release node memory reservation
              |
              +---> Step 5: Identify Dangling Disk Images
                    For dir in /var/lib/hvagent/vms/* without meta.json:
                        rm -rf dir
```

### 4.2 Cluster Reconciler (`hvctl-server` - Runs every 30 seconds)

1. **Heartbeat Verification**:
   - Queries `GET /v1/capacity` across all registered workers.
   - If a worker misses 3 consecutive checks (90 seconds), it is marked `UNHEALTHY`.
   - VMs residing on that worker are marked `UNKNOWN` and excluded from new placement calculations.
2. **Pending VM Sweeper**:
   - If a VM remains in `PENDING` state for > 60 seconds (indicates controller crashed mid-request), the controller queries workers to discover if the VM was created.
   - If absent on workers, the database reservation is cleared and state set to `FAILED`.
