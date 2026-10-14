# VM Lifecycle & State Machine

This page details the finite state machine (FSM) governing virtual machines in the cluster, including state transition invariants, idempotency guarantees, and the forced teardown escalation protocol.

---

## 1. Lifecycle State Machine

The lifecycle of each virtual machine is strictly defined by an explicit state machine:

![VM Lifecycle State Machine](../docs/images/vm-lifecycle.png)

### State Definitions

| State | Scope | Description |
|---|---|---|
| `PENDING` | Controller | Temporary state during placement. Memory has been reserved in SQLite (`D1`), but the worker has not yet completed VM definition. |
| `CREATED` | Controller & Worker | Hypervisor process has spawned, disk image is cloned, cgroup is configured, and `vm.create` succeeded. Guest is paused / not yet booted. |
| `RUNNING` | Controller & Worker | Guest OS is actively executing (`vm.boot` succeeded). Virtio interfaces and vCPUs are hot. |
| `STOPPED` | Controller & Worker | Guest is shutdown cleanly or hypervisor process has exited. Memory reservation is released, but disk and configuration are retained. |
| `FAILED` | Controller & Worker | An operation failed, or the underlying `cloud-hypervisor` process crashed unexpectedly. Resources are cleaned up and memory is released. |
| `DELETED` | Controller | Terminal state. Virtual machine record is removed from the database; disk, cgroups, metadata, and sockets have been purged. |

---

## 2. State Transition Matrix

The table below defines all legal transitions and allowed user/system operations:

| Current State | Target State | Triggering Event / Action | Executing Layer |
|---|---|---|---|
| `None` | `PENDING` | `POST /v1/vms` (Allocation and placement lock acquired) | Controller |
| `PENDING` | `CREATED` | Worker confirms `vm.create` and metadata write-ahead | Controller / Worker |
| `PENDING` | `FAILED` | Placement failed, worker unreachable, or `vm.create` failed | Controller |
| `CREATED` | `RUNNING` | `POST /v1/vms/{id}/start` (`vm.boot` executed) | Operator / Worker |
| `CREATED` | `DELETED` | `DELETE /v1/vms/{id}` (Teardown without boot) | Operator / Worker |
| `RUNNING` | `STOPPED` | `POST /v1/vms/{id}/stop` (`vm.shutdown` executed) | Operator / Worker |
| `RUNNING` | `FAILED` | Hypervisor process killed (`kill -9`, SIGSEGV, or OOM) | Reconciler / Worker |
| `STOPPED` | `RUNNING` | `POST /v1/vms/{id}/start` (Respawn process & boot) | Operator / Worker |
| `STOPPED` | `DELETED` | `DELETE /v1/vms/{id}` (Teardown storage & records) | Operator / Worker |
| `FAILED` | `DELETED` | `DELETE /v1/vms/{id}` (Purge residual artifacts) | Operator / Worker |

---

## 3. Idempotency Guarantees

Every API endpoint across the controller and worker agents is designed to be strictly **idempotent**:

1. **Idempotent Boot (`POST /v1/vms/{id}/start`)**:
   - If the VM is already in `RUNNING` state, the agent queries Cloud Hypervisor via `GET /api/v1/vm.info`. If confirmed running, the call returns `200 OK` with the current state immediately without error.
2. **Idempotent Shutdown (`POST /v1/vms/{id}/stop`)**:
   - If the VM is already in `STOPPED` state, or if the hypervisor process is no longer detected, the agent returns `200 OK` indicating the machine is stopped.
3. **Idempotent Deletion (`DELETE /v1/vms/{id}`)**:
   - Calling delete on an already deleted or non-existent VM returns `204 No Content` or `404 Not Found` consistently without causing orphan artifacts.

---

## 4. Teardown Escalation Sequence

To eliminate zombie hypervisor processes, unresponsiveness during ACPI shutdown is resolved through an automated 4-stage escalation ladder:

```
[Start Teardown Request]
       |
       v
+-------------------------------------------------------+
| Stage 1: Graceful ACPI Shutdown                       |
| PUT /api/v1/vm.shutdown                               |
| Timeout: 10 seconds                                   |
+--------------------------+----------------------------+
                           |
            +--------------+--------------+
            |                             |
      Guest Exited                 Timeout Expired
            |                             |
            v                             v
+--------------------------+  +-------------------------------------------------------+
| Success: Release Memory  |  | Stage 2: VMM Process Termination                      |
+--------------------------+  | PUT /api/v1/vmm.shutdown                              |
                              | Timeout: 3 seconds                                    |
                              +---------------------------+---------------------------+
                                                          |
                                           +--------------+--------------+
                                           |                             |
                                     Process Exited                Timeout Expired
                                           |                             |
                                           v                             v
                               +--------------------------+  +-------------------------------------------------------+
                               | Success: Release Memory  |  | Stage 3: Process Tree Hard Kill (SIGKILL)             |
                               +--------------------------+  | Write "1" to /sys/fs/cgroup/hvagent/<id>/cgroup.kill  |
                                                             | Timeout: 2 seconds                                    |
                                                             +---------------------------+---------------------------+
                                                                                         |
                                                                          +--------------+--------------+
                                                                          |                             |
                                                                    cgroup Empty                  Still Alive
                                                                          |                             |
                                                                          v                             v
                                                              +--------------------------+  +-------------------------------------------------------+
                                                              | Success: Release Memory  |  | Stage 4: Fatal Error Logging & Alarm                  |
                                                              +--------------------------+  | Flag Node Alert; Reconciler Retries Teardown          |
                                                                                            +-------------------------------------------------------+
```

### Protocol Implementation Highlights:

1. **Stage 1 (`vm.shutdown`)**: Sends an ACPI power button event into the guest kernel over virtio. Wait up to 10 seconds for `state == Shutdown`.
2. **Stage 2 (`vmm.shutdown`)**: If ACPI is ignored or guest kernel has hung, the agent requests the VMM process itself to terminate over the socket.
3. **Stage 3 (`cgroup.kill`)**: If the process fails to exit, the agent writes `1` to `/sys/fs/cgroup/hvagent/<vm-id>/cgroup.kill`. This guarantees that all threads (vCPU threads, epoll threads, helper processes) are killed synchronously by the Linux kernel.
4. **Post-condition Verification**: The agent checks `/sys/fs/cgroup/hvagent/<vm-id>/cgroup.procs` to ensure it is completely empty before releasing host memory commitments and removing the cgroup directory.
