# Development, Testing & Demonstration Guide

This guide details the testing architecture, failure injection scenarios, leak verification procedures, and the 5–7 minute live evaluation demonstration script.

---

## 1. Test Strategy & Architecture

The testing suite is structured into three tiers:

```
tests/
├── unit/                 # Fast, hermetic, runs anywhere (no KVM required)
│   ├── test_placement.py # Memory accounting math, tie-breaking, concurrency locks
│   ├── test_validation.py# Flavor parsing, parameter bounds checking
│   ├── test_auth.py      # Bearer token verification, timing attack resistance
│   ├── test_fsm.py       # State machine transitions, idempotency checks
│   └── test_ch_client.py # Mock UNIX socket server mimicking Cloud Hypervisor
├── integration/          # Requires /dev/kvm and 2 hosts
│   ├── test_lifecycle.py # Full create -> boot -> ping -> stop -> delete cycle
│   ├── test_multi_host.py# Fill Host 1, spill to Host 2, oversize VM rejection
│   └── test_cgroups.py   # Memory stress test inside guest, verifying cgroup cap
└── failure_injection/    # Chaos testing & resilience verification
    ├── test_ch_kill.py   # kill -9 of Cloud Hypervisor -> FAILED state
    ├── test_agent_kill.py# kill -9 of worker agent -> PDEATHSIG verification
    └── test_partition.py # Dropping worker port -> Controller UNHEALTHY detection
```

---

## 2. Leak Checker Script (`scripts/check_leaks.sh`)

After every integration and chaos test run, the automated leak checker scans the host to ensure zero remnants:

```bash
#!/usr/bin/env bash
# scripts/check_leaks.sh - Strict system resource leak checker
set -euo pipefail

echo "=== Checking Host for Resource Leaks ==="
LEAKS_FOUND=0

# 1. Check for unmanaged cloud-hypervisor processes
CH_PROCS=$(pgrep -l cloud-hypervisor || true)
if [ -n "$CH_PROCS" ]; then
    echo "[!] LEAK DETECTED: Running Cloud Hypervisor processes found:"
    echo "$CH_PROCS"
    LEAKS_FOUND=$((LEAKS_FOUND + 1))
else
    echo "[OK] No stray Cloud Hypervisor processes detected."
fi

# 2. Check for lingering cgroups
if [ -d "/sys/fs/cgroup/hvagent" ]; then
    STRAY_CGROUPS=$(find /sys/fs/cgroup/hvagent -mindepth 1 -maxdepth 1 -type d)
    if [ -n "$STRAY_CGROUPS" ]; then
        echo "[!] LEAK DETECTED: Stray cgroups found under /sys/fs/cgroup/hvagent:"
        echo "$STRAY_CGROUPS"
        LEAKS_FOUND=$((LEAKS_FOUND + 1))
    else
        echo "[OK] cgroup hierarchy is completely clean."
    fi
fi

# 3. Check for leftover UNIX sockets
STRAY_SOCKS=$(find /run/hvagent -name "*.sock" 2>/dev/null || true)
if [ -n "$STRAY_SOCKS" ]; then
    echo "[!] LEAK DETECTED: Stray UNIX domain sockets found in /run/hvagent:"
    echo "$STRAY_SOCKS"
    LEAKS_FOUND=$((LEAKS_FOUND + 1))
else
    echo "[OK] /run/hvagent has zero socket files."
fi

# 4. Check for orphaned VM disk directories
if [ -d "/var/lib/hvagent/vms" ]; then
    STRAY_DISKS=$(find /var/lib/hvagent/vms -mindepth 1 -maxdepth 1 -type d)
    if [ -n "$STRAY_DISKS" ]; then
        echo "[!] LEAK DETECTED: Unregistered VM disk directories found:"
        echo "$STRAY_DISKS"
        LEAKS_FOUND=$((LEAKS_FOUND + 1))
    else
        echo "[OK] No stray VM disk images in /var/lib/hvagent/vms."
    fi
fi

if [ "$LEAKS_FOUND" -gt 0 ]; then
    echo "=================================================="
    echo "FAILED: $LEAKS_FOUND leak categories identified!"
    exit 1
else
    echo "SUCCESS: Host is 100% leak-free."
fi
```

---

## 3. Evaluation Live Demonstration Script (5–7 Minutes)

This script provides the step-by-step walkthrough for hackathon evaluators and mentors.

### Step 1: Cluster Health & Capacity (0:00 - 1:00)
Verify that the controller is online and both worker agents are reporting available memory:

```bash
curl -s -H "Authorization: Bearer $API_TOKEN" https://controller:8443/v1/workers | jq
```
*Evaluator sees both Host 1 and Host 2 marked as `HEALTHY`, reporting free memory and 0 active VMs.*

---

### Step 2: Automated Placement & VM Boot (1:00 - 2:30)
Provision two virtual machines using the `small` flavor (512 MiB RAM each):

```bash
# Provision VM 1
VM1_ID=$(curl -s -H "Authorization: Bearer $API_TOKEN" -X POST https://controller:8443/v1/vms \
  -H "Content-Type: application/json" -d '{"name":"demo-vm-1","flavor":"small"}' | jq -r .id)

# Provision VM 2
VM2_ID=$(curl -s -H "Authorization: Bearer $API_TOKEN" -X POST https://controller:8443/v1/vms \
  -H "Content-Type: application/json" -d '{"name":"demo-vm-2","flavor":"small"}' | jq -r .id)

# Start both VMs
curl -s -H "Authorization: Bearer $API_TOKEN" -X POST "https://controller:8443/v1/vms/$VM1_ID/start"
curl -s -H "Authorization: Bearer $API_TOKEN" -X POST "https://controller:8443/v1/vms/$VM2_ID/start"

# Verify list output
curl -s -H "Authorization: Bearer $API_TOKEN" https://controller:8443/v1/vms | jq
```
*Evaluator sees VM 1 placed on Host 1 and VM 2 placed on Host 2 (or distributed according to memory balance), both in `RUNNING` state.*

---

### Step 3: Oversize VM Rejection (2:30 - 3:30)
Request a virtual machine with 64 GiB of RAM (larger than any host):

```bash
curl -i -H "Authorization: Bearer $API_TOKEN" -X POST https://controller:8443/v1/vms \
  -H "Content-Type: application/json" -d '{"name":"oversize-vm","vcpus":4,"memory_mib":65536}'
```
*Evaluator observes an immediate `409 Conflict` response with an explicit error breakdown detailing available memory on each worker.*

---

### Step 4: Chaos Injection & Crash Recovery (3:30 - 4:45)
Simulate an unexpected crash by killing the Cloud Hypervisor process directly on Host 1:

```bash
# On Host 1: Find and kill the VM hypervisor process
CH_PID=$(pgrep -f "cloud-hypervisor.*$VM1_ID")
kill -9 "$CH_PID"

# On Controller: Check VM status
curl -s -H "Authorization: Bearer $API_TOKEN" "https://controller:8443/v1/vms/$VM1_ID" | jq
```
*Evaluator observes:*
1. VM status shifts from `RUNNING` to `FAILED`.
2. The controller reconciler automatically releases the 512 MiB committed memory back into the cluster pool.
3. No stray hypervisor threads remain running.

---

### Step 5: Teardown & Clean Leak Verification (4:45 - 6:00)
Delete all virtual machines and run the leak checker:

```bash
# Delete VM 1 and VM 2
curl -s -H "Authorization: Bearer $API_TOKEN" -X DELETE "https://controller:8443/v1/vms/$VM1_ID"
curl -s -H "Authorization: Bearer $API_TOKEN" -X DELETE "https://controller:8443/v1/vms/$VM2_ID"

# Run the leak checker on both hosts
./scripts/check_leaks.sh
```
*Evaluator observes clean `[OK]` output across processes, cgroups, sockets, and disk images. Zero leaks proven.*
