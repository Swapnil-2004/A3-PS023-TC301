# API Reference & Contracts

This page defines the complete REST API schemas, headers, authentication mechanisms, and internal Cloud Hypervisor socket endpoints.

---

## 1. Authentication & Security

All external and internal REST interactions require an HTTP Bearer token:

```http
Authorization: Bearer <SECRET_TOKEN>
```

- **Operator API Tokens**: Managed in `/etc/hvctl/api.token` on the controller node.
- **Worker API Tokens**: Managed in `/etc/hvagent/worker.token` on each worker node.
- **Verification**: Handled using constant-time string comparison (`hmac.compare_digest`) over TLS 1.3 to eliminate timing side-channel attacks.

---

## 2. Controller API (Operator-Facing)

The Controller listens on `https://controller:8443`.

### 2.1 Provision VM: `POST /v1/vms`
Submits a request to allocate, place, and define a new virtual machine.

**Request Body:**
```json
{
  "name": "web-01",
  "flavor": "small"
}
```
*Alternatively, explicit parameters may be passed:*
```json
{
  "name": "custom-01",
  "vcpus": 2,
  "memory_mib": 1024
}
```

**Success Response (`201 Created`):**
```json
{
  "id": "8a6f4e12-b91c-4b5a-93f0-2f954f9a0001",
  "name": "web-01",
  "flavor": "small",
  "vcpus": 1,
  "memory_mib": 512,
  "worker_id": "worker-1",
  "state": "CREATED",
  "created_at": "2026-10-14T12:00:00Z"
}
```

**Error Responses:**
- `401 Unauthorized`: Invalid or missing Bearer token.
- `422 Unprocessable Entity`: Requested flavor or memory exceeds bounds.
- `409 Conflict`: Insufficient host memory available on all cluster nodes.

---

### 2.2 List Virtual Machines: `GET /v1/vms`
Lists all known virtual machines in the cluster merged with live hypervisor state.

**Success Response (`200 OK`):**
```json
[
  {
    "id": "8a6f4e12-b91c-4b5a-93f0-2f954f9a0001",
    "name": "web-01",
    "flavor": "small",
    "vcpus": 1,
    "memory_mib": 512,
    "worker_id": "worker-1",
    "state": "RUNNING",
    "ip_address": "192.168.100.15",
    "created_at": "2026-10-14T12:00:00Z"
  }
]
```

---

### 2.3 Get VM Details: `GET /v1/vms/{id}`
Returns details and runtime state for a single virtual machine.

**Success Response (`200 OK`):**
```json
{
  "id": "8a6f4e12-b91c-4b5a-93f0-2f954f9a0001",
  "name": "web-01",
  "vcpus": 1,
  "memory_mib": 512,
  "worker_id": "worker-1",
  "state": "RUNNING",
  "hypervisor_pid": 14205,
  "created_at": "2026-10-14T12:00:00Z"
}
```

---

### 2.4 Start VM: `POST /v1/vms/{id}/start`
Boots an existing created or stopped virtual machine.

**Success Response (`200 OK`):**
```json
{
  "id": "8a6f4e12-b91c-4b5a-93f0-2f954f9a0001",
  "state": "RUNNING",
  "message": "VM booted successfully"
}
```

---

### 2.5 Stop VM: `POST /v1/vms/{id}/stop`
Gracefully halts guest execution using the teardown escalation sequence.

**Success Response (`200 OK`):**
```json
{
  "id": "8a6f4e12-b91c-4b5a-93f0-2f954f9a0001",
  "state": "STOPPED",
  "message": "VM stopped and memory released"
}
```

---

### 2.6 Delete VM: `DELETE /v1/vms/{id}`
Tears down VM processes, deletes the disk copy, removes cgroups, and purges database records.

**Success Response (`204 No Content`)**

---

### 2.7 Cluster Health & Capacity: `GET /v1/workers`
Returns real-time health and memory metrics across all registered worker agents.

**Success Response (`200 OK`):**
```json
[
  {
    "worker_id": "worker-1",
    "host": "192.168.1.10:8444",
    "status": "HEALTHY",
    "total_mib": 16384,
    "available_mib": 12288,
    "committed_mib": 2048,
    "effective_free_mib": 9728,
    "running_vms": 2
  },
  {
    "worker_id": "worker-2",
    "host": "192.168.1.11:8444",
    "status": "HEALTHY",
    "total_mib": 16384,
    "available_mib": 14336,
    "committed_mib": 1024,
    "effective_free_mib": 12800,
    "running_vms": 1
  }
]
```

---

## 3. Worker API (Controller-Facing)

The Worker Agent listens on `https://<worker-ip>:8444`. Only requests with valid worker tokens are accepted.

| Method & Path | Payload / Query | Description |
|---|---|---|
| `GET /v1/capacity` | None | Returns host memory (`total`, `available`, `committed`) and live VM count. |
| `POST /v1/vms` | `{id, name, vcpus, memory_mib}` | Spawns CH, prepares cgroup, writes `meta.json`, calls `vm.create`. |
| `GET /v1/vms` | None | Returns list of locally managed VMs with live `vm.info` statuses. |
| `GET /v1/vms/{id}` | None | Queries local metadata and `vm.info` for a single VM. |
| `POST /v1/vms/{id}/start` | None | Executes `vm.boot` against the VM's UNIX socket. |
| `POST /v1/vms/{id}/stop` | None | Triggers ACPI shutdown, escalating to `cgroup.kill` if unhandled. |
| `DELETE /v1/vms/{id}` | None | Kills process, deletes disk, unlinks socket, removes cgroups. |

---

## 4. Cloud Hypervisor UNIX Domain Socket API

Each VM is managed via HTTP-over-UDS targeting `/run/hvagent/<vm-id>.sock`. All endpoints reside under `/api/v1/`:

| Endpoint | Method | Payload / Action | Purpose |
|---|---|---|---|
| `/api/v1/vmm.ping` | `GET` | Empty | Probes whether the VMM process is alive and responsive. |
| `/api/v1/vm.create` | `PUT` | `VmConfig` JSON | Declares CPU, memory, payload, disk, TAP, and console options. |
| `/api/v1/vm.boot` | `PUT` | Empty | Boots the virtual machine from defined payload/disks. |
| `/api/v1/vm.info` | `GET` | Empty | Returns live guest state (`Created`, `Running`, `Shutdown`, `Paused`). |
| `/api/v1/vm.shutdown` | `PUT` | Empty | Sends ACPI power button event to guest. |
| `/api/v1/vm.delete` | `PUT` | Empty | Unregisters and frees the virtual machine data structures in VMM memory. |
| `/api/v1/vmm.shutdown` | `PUT` | Empty | Asks the Cloud Hypervisor process to cleanly terminate itself. |

### Sample `vm.create` Payload

```json
{
  "cpus": {
    "boot_vcpus": 1,
    "max_vcpus": 1
  },
  "memory": {
    "size": 536870912
  },
  "payload": {
    "firmware": "/usr/share/cloud-hypervisor/hypervisor-fw"
  },
  "disks": [
    {
      "path": "/var/lib/hvagent/vms/8a6f4e12-.../disk.raw"
    }
  ],
  "net": [
    {
      "tap": "tap-vm01",
      "mac": "52:54:00:12:34:56"
    }
  ],
  "serial": {
    "mode": "File",
    "file": "/var/lib/hvagent/vms/8a6f4e12-.../serial.log"
  }
}
```
