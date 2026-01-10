#!/bin/bash
# SSH into the running VM
set -e

VM_IP="${VM_IP:-192.168.100.2}"
VM_USER="${VM_USER:-cloud}"

echo "=== SSH to Cloud Hypervisor VM ==="
echo "Connecting to ${VM_USER}@${VM_IP}..."
echo "Default password: cloud123"
echo ""

# Wait for SSH to be available
echo "Waiting for SSH to be ready..."
for i in {1..30}; do
    if nc -z "${VM_IP}" 22 2>/dev/null; then
        echo "SSH is ready!"
        break
    fi
    echo -n "."
    sleep 2
done
echo ""

# Connect
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${VM_USER}@${VM_IP}"
