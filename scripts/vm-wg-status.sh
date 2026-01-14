#!/bin/bash
# Show WireGuard port forwarding status for all VMs
# Usage: vm-wg-status.sh
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM_BASE_DIR="${SCRIPT_DIR}/../vm"

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (sudo)"
    exit 1
fi

echo "=== WireGuard Port Forwarding Status ==="
echo ""

# Get primary interface
PRIMARY_IF=$(ip route | grep default | awk '{print $5}' | head -1)
echo "Primary interface: ${PRIMARY_IF}"
echo ""

# Check if any VMs exist
if ! ls -d "${VM_BASE_DIR}"/vm-*/ &>/dev/null; then
    echo "No VMs found."
    exit 0
fi

printf "%-8s %-18s %-10s %-15s %-15s\n" "VM_ID" "VM_IP" "WG_PORT" "FORWARD" "DNAT"
printf "%-8s %-18s %-10s %-15s %-15s\n" "------" "-----------------" "--------" "--------------" "--------------"

for vm_dir in "${VM_BASE_DIR}"/vm-*/; do
    if [[ -f "${vm_dir}/vm.conf" ]]; then
        # Reset variables
        VM_ID=""
        VM_IP=""
        WG_PORT=""

        source "${vm_dir}/vm.conf"

        # Skip if WG_PORT not set (old VMs created before this feature)
        if [[ -z "${WG_PORT}" ]]; then
            WG_PORT="N/A"
            FWD_STATUS="N/A"
            DNAT_STATUS="N/A"
        else
            # Check FORWARD rule
            if iptables -C FORWARD -p udp -d "${VM_IP}" --dport "${WG_PORT}" -j ACCEPT 2>/dev/null; then
                FWD_STATUS="OK"
            else
                FWD_STATUS="MISSING"
            fi

            # Check DNAT rule
            if iptables -t nat -C PREROUTING -i "${PRIMARY_IF}" -p udp --dport "${WG_PORT}" -j DNAT --to-destination "${VM_IP}:${WG_PORT}" 2>/dev/null; then
                DNAT_STATUS="OK"
            else
                DNAT_STATUS="MISSING"
            fi
        fi

        printf "%-8s %-18s %-10s %-15s %-15s\n" "${VM_ID}" "${VM_IP}" "${WG_PORT}" "${FWD_STATUS}" "${DNAT_STATUS}"
    fi
done

echo ""
echo "Legend:"
echo "  FORWARD: iptables FORWARD rule allowing UDP to VM"
echo "  DNAT: iptables PREROUTING rule redirecting external traffic to VM"
