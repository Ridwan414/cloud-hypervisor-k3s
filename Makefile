.PHONY: setup vm-create vm-start vm-stop vm-delete vm-ssh vm-list clean help

help:
	@echo "Cloud Hypervisor VM Management"
	@echo ""
	@echo "Setup:"
	@echo "  make setup              Download cloud-hypervisor, firmware, base image"
	@echo ""
	@echo "VM Management:"
	@echo "  make vm-create ID=N     Create VM N (copy disk, cloud-init, TAP)"
	@echo "  make vm-start ID=N      Start VM N"
	@echo "  make vm-stop ID=N       Stop VM N"
	@echo "  make vm-delete ID=N     Delete VM N and cleanup resources"
	@echo "  make vm-ssh ID=N        SSH into VM N"
	@echo "  make vm-list            List all VMs and their status"
	@echo ""
	@echo "Cleanup:"
	@echo "  make clean              Stop all VMs, remove all resources"
	@echo ""
	@echo "Examples:"
	@echo "  make setup              # First time setup"
	@echo "  make vm-create ID=1     # Create VM 1"
	@echo "  make vm-start ID=1      # Start VM 1"
	@echo "  make vm-ssh ID=1        # SSH into VM 1"
	@echo "  make vm-create ID=2     # Create VM 2"
	@echo "  make vm-list            # Show all VMs"

setup:
	./scripts/01-setup.sh

vm-create:
	@test -n "$(ID)" || (echo "Error: ID required. Usage: make vm-create ID=<number>" && exit 1)
	sudo ./scripts/vm-create.sh $(ID)

vm-start:
	@test -n "$(ID)" || (echo "Error: ID required. Usage: make vm-start ID=<number>" && exit 1)
	./scripts/vm-start.sh $(ID)

vm-stop:
	@test -n "$(ID)" || (echo "Error: ID required. Usage: make vm-stop ID=<number>" && exit 1)
	./scripts/vm-stop.sh $(ID)

vm-delete:
	@test -n "$(ID)" || (echo "Error: ID required. Usage: make vm-delete ID=<number>" && exit 1)
	sudo ./scripts/vm-delete.sh $(ID)

vm-ssh:
	@test -n "$(ID)" || (echo "Error: ID required. Usage: make vm-ssh ID=<number>" && exit 1)
	./scripts/vm-ssh.sh $(ID)

vm-list:
	@./scripts/vm-list.sh

clean:
	sudo ./scripts/cleanup.sh
