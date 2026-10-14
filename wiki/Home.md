# A3-PS023-TC301 Wiki: Minimal Two-Node Cloud Hypervisor VM Controller

Welcome to the **A3-PS023-TC301** project wiki. This repository contains the architecture, specifications, and reference implementation for **PS-023: Minimal Two-Node Cloud Hypervisor VM Controller**, created for the **AIORI Hackathon 3 (Category: Cloud Computing)**.

---

## 🌟 Executive Summary

Enterprise virtualization platforms (OpenStack, oVirt, Proxmox, vSphere) depend on complex multi-daemon stacks, distributed message brokers, and centralized databases whose resource footprints are excessive for resource-constrained edge deployments. 

[Cloud Hypervisor](https://github.com/cloud-hypervisor/cloud-hypervisor) is a modern, lightweight Rust-based Virtual Machine Monitor (VMM) built directly on Linux KVM (`/dev/kvm`). While Cloud Hypervisor boasts sub-second boot times and minimal overhead, it runs strictly **one process per virtual machine** and possesses no inherent cluster awareness or multi-host coordination.

**A3-PS023-TC301** provides the thinnest possible distributed control plane that unites two KVM-capable Linux hosts into a unified, reliable micro-cloud. It delivers:
- **Two-tier architecture**: A central controller coordinating two worker agents.
- **Full VM Lifecycle**: Authenticated API supporting VM creation, boot, shutdown, and deletion.
- **Accurate Memory-Based Placement**: Eliminates allocation races using dual-view memory accounting (`min(MemAvailable, Committed)`).
- **Three-Layer Resource Limits**: Flavor admission control, VMM parameter clamping, and Linux cgroup v2 kernel caps.
- **Zero-Orphan Guarantee**: Ensures hypervisor processes are never left behind, utilizing `cgroup.kill`, `PR_SET_PDEATHSIG`, write-ahead metadata, undo rollback lists, and self-healing reconciler loops.

---

## 📚 Wiki Contents & Navigation

Explore the in-depth technical documentation across the following pages:

| Wiki Page | Description |
|---|---|
| **[System Architecture](System-Architecture.md)** | Physical/logical topology, process boundaries, socket IPC, and data flow. |
| **[VM Lifecycle & State Machine](VM-Lifecycle-and-State-Machine.md)** | Detailed state transitions (`PENDING` → `RUNNING` → `STOPPED` → `FAILED`), idempotency rules, and escalation teardowns. |
| **[API Reference](API-Reference.md)** | Endpoints, payload schemas, and Bearer token auth for the Controller, Worker, and Cloud Hypervisor APIs. |
| **[Placement & Resource Management](Placement-and-Resource-Management.md)** | Mathematical placement algorithms, concurrency locks, flavor definitions, and cgroup v2 enforcement. |
| **[Reliability & Zero-Orphan Guarantee](Reliability-and-Zero-Orphan-Guarantee.md)** | Mechanisms preventing zombie VMs: `cgroup.kill`, `PDEATHSIG`, rollback undo chains, and reconciliation loops. |
| **[Development, Testing & Demo](Development-Testing-and-Demo.md)** | Unit test suites, integration scenarios, failure injection drills, leak verification, and the 5-7 minute live demo script. |

---

## 🏛️ System Architecture at a Glance

The cluster consists of one central controller (`hvctl-server`) and two node-local worker agents (`hvagent`):

```
                        +---------------------------+
                        |     Operator / Client     |
                        +-------------+-------------+
                                      | HTTPS (Bearer Token)
                                      v
                        +---------------------------+
                        |  Controller: hvctl-server |
                        |  - REST API & Auth        |
                        |  - SQLite Inventory (D1)  |
                        |  - Memory Placement       |
                        |  - Cluster Reconciler     |
                        +------+-------------+------+
                               |             |
        HTTPS + Worker Token   |             |   HTTPS + Worker Token
                 +-------------+             +-------------+
                 v                                         v
   +---------------------------+             +---------------------------+
   |   Host 1: hvagent         |             |   Host 2: hvagent         |
   |   - Agent REST API        |             |   - Agent REST API        |
   |   - cgroup v2 Supervisor  |             |   - cgroup v2 Supervisor  |
   |   - Metadata Store (D2)   |             |   - Metadata Store (D2)   |
   |   - Node Reconciler       |             |   - Node Reconciler       |
   +-------------+-------------+             +-------------+-------------+
                 | UNIX Socket                             | UNIX Socket
                 v                                         v
   +---------------------------+             +---------------------------+
   |  cloud-hypervisor (VM-1)  |             |  cloud-hypervisor (VM-2)  |
   |  - Linux /dev/kvm         |             |  - Linux /dev/kvm         |
   |  - Isolated cgroup        |             |  - Isolated cgroup        |
   +---------------------------+             +---------------------------+
```

---

## ⚡ Quick Example: Operator Workflow

Once deployed, the controller exposes an operator-facing REST API:

```bash
# 1. Check worker health and cluster capacity
curl -s -H "Authorization: Bearer $API_TOKEN" https://controller:8443/v1/workers

# 2. Provision a new virtual machine (Controller performs memory-based placement)
curl -s -H "Authorization: Bearer $API_TOKEN" -X POST https://controller:8443/v1/vms \
     -H "Content-Type: application/json" \
     -d '{"name": "web-node-1", "flavor": "small"}'

# 3. Boot the provisioned VM
curl -s -H "Authorization: Bearer $API_TOKEN" -X POST https://controller:8443/v1/vms/<VM_ID>/start

# 4. List all VMs across both cluster nodes with live hypervisor status
curl -s -H "Authorization: Bearer $API_TOKEN" https://controller:8443/v1/vms

# 5. Gracefully shutdown and cleanup resources
curl -s -H "Authorization: Bearer $API_TOKEN" -X POST https://controller:8443/v1/vms/<VM_ID>/stop
curl -s -H "Authorization: Bearer $API_TOKEN" -X DELETE https://controller:8443/v1/vms/<VM_ID>
```

---

## 👥 Hackathon Team Information

- **Institution:** Institute of Engineering and Management (IEM), Salt Lake, Kolkata
- **Team Code:** A3-PS023-TC301
- **Faculty Mentor:** Prof. Dr. Baisakhi Das (`baisakhi.das@iem.edu.in`)
- **Team Lead:** Debarghaya Mitra (`debarghaya@debarghaya.in`)
- **Team Partner:** Swapnil Chakraborty (`chakrabortyswapnil06@gmail.com`)
