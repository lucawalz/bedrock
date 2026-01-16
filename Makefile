# NixOS Homelab - Command Reference
# Run 'make help' to see all available commands

.PHONY: help switch build update flux-bootstrap flux-check flux-status flux-sync \
        sops-encrypt sops-edit k3s-info nodes pods logs-flux logs-sentio \
        reconcile restart-sentio port-grafana port-keycloak secrets-view test

# Colors
CYAN := \033[36m
GREEN := \033[32m
YELLOW := \033[33m
BLUE := \033[34m
MAGENTA := \033[35m
WHITE := \033[37m
BOLD := \033[1m
DIM := \033[2m
RESET := \033[0m

# Default target
help:
	@printf "\n"
	@printf "$(BOLD)$(CYAN)╔══════════════════════════════════════════════════════════════╗$(RESET)\n"
	@printf "$(BOLD)$(CYAN)║           NixOS Homelab Command Reference                    ║$(RESET)\n"
	@printf "$(BOLD)$(CYAN)╚══════════════════════════════════════════════════════════════╝$(RESET)\n"
	@printf "\n"
	@printf "$(BOLD)$(BLUE)NixOS Operations$(RESET)\n"
	@printf "   $(GREEN)make switch$(RESET) $(YELLOW)HOST=<host>$(RESET)    $(DIM)Build and switch NixOS config$(RESET)\n"
	@printf "   $(GREEN)make build$(RESET) $(YELLOW)HOST=<host>$(RESET)     $(DIM)Test build without switching$(RESET)\n"
	@printf "   $(GREEN)make update$(RESET)                $(DIM)Update flake lock file$(RESET)\n"
	@printf "\n"
	@printf "$(BOLD)$(BLUE)Kubernetes Operations$(RESET)\n"
	@printf "   $(GREEN)make k3s-info$(RESET)              $(DIM)Show cluster info and nodes$(RESET)\n"
	@printf "   $(GREEN)make nodes$(RESET)                 $(DIM)List all cluster nodes$(RESET)\n"
	@printf "   $(GREEN)make pods$(RESET)                  $(DIM)List all pods across namespaces$(RESET)\n"
	@printf "   $(GREEN)make pods-ns$(RESET) $(YELLOW)NS=<ns>$(RESET)       $(DIM)List pods in a namespace$(RESET)\n"
	@printf "\n"
	@printf "$(BOLD)$(BLUE)Flux GitOps$(RESET)\n"
	@printf "   $(GREEN)make flux-bootstrap$(RESET)        $(DIM)Bootstrap Flux (one-time)$(RESET)\n"
	@printf "   $(GREEN)make flux-check$(RESET)            $(DIM)Check all Flux resources$(RESET)\n"
	@printf "   $(GREEN)make flux-status$(RESET)           $(DIM)Show Flux reconciliation state$(RESET)\n"
	@printf "   $(GREEN)make flux-sync$(RESET)             $(DIM)Sync Flux manually$(RESET)\n"
	@printf "   $(GREEN)make reconcile$(RESET)             $(DIM)Reconcile cluster-apps$(RESET)\n"
	@printf "\n"
	@printf "$(BOLD)$(BLUE)Secrets Management$(RESET)\n"
	@printf "   $(GREEN)make sops-encrypt$(RESET) $(YELLOW)FILE=<f>$(RESET) $(DIM)Encrypt a secret file$(RESET)\n"
	@printf "   $(GREEN)make sops-edit$(RESET) $(YELLOW)FILE=<f>$(RESET)    $(DIM)Edit an encrypted secret$(RESET)\n"
	@printf "   $(GREEN)make secrets-view$(RESET)          $(DIM)View sentio secrets (decrypted)$(RESET)\n"
	@printf "\n"
	@printf "$(BOLD)$(BLUE)Debugging & Logs$(RESET)\n"
	@printf "   $(GREEN)make logs-flux$(RESET)             $(DIM)View Flux source-controller logs$(RESET)\n"
	@printf "   $(GREEN)make logs-sentio$(RESET)           $(DIM)View sentio-backend logs$(RESET)\n"
	@printf "   $(GREEN)make logs-keycloak$(RESET)         $(DIM)View sentio-keycloak logs$(RESET)\n"
	@printf "\n"
	@printf "$(BOLD)$(BLUE)Port Forwarding$(RESET)\n"
	@printf "   $(GREEN)make port-grafana$(RESET)          $(DIM)Forward Grafana to localhost:3000$(RESET)\n"
	@printf "   $(GREEN)make port-keycloak$(RESET)         $(DIM)Forward Keycloak to localhost:8080$(RESET)\n"
	@printf "\n"
	@printf "$(BOLD)$(BLUE)Sentio Operations$(RESET)\n"
	@printf "   $(GREEN)make restart-sentio$(RESET)        $(DIM)Restart all sentio deployments$(RESET)\n"
	@printf "   $(GREEN)make helm-releases$(RESET)         $(DIM)Check HelmReleases status$(RESET)\n"
	@printf "\n"
	@printf "$(DIM)Examples:$(RESET)\n"
	@printf "   $(WHITE)make switch HOST=master$(RESET)\n"
	@printf "   $(WHITE)make sops-edit FILE=kubernetes/clusters/home/secrets/sentio-systems.sops.yaml$(RESET)\n"
	@printf "\n"

# ═══════════════════════════════════════════════════════════════
# NixOS Operations
# ═══════════════════════════════════════════════════════════════

# Build and switch NixOS config for a host
switch:
ifndef HOST
	$(error HOST is required. Usage: make switch HOST=master)
endif
	sudo nixos-rebuild switch --flake .#$(HOST)

# Test build without switching
build:
ifndef HOST
	$(error HOST is required. Usage: make build HOST=master)
endif
	nixos-rebuild build --flake .#$(HOST)

# Update flake lock
update:
	nix flake update

# ═══════════════════════════════════════════════════════════════
# Flux GitOps
# ═══════════════════════════════════════════════════════════════

# Bootstrap Flux on the cluster (one-time setup)
# Requires: export GITHUB_TOKEN=<token>
flux-bootstrap:
	flux bootstrap github \
		--owner=lucawalz \
		--repository=nixos-homelab \
		--path=kubernetes/clusters/home \
		--personal

# Check all Flux resources
flux-check:
	flux get all -A

# Show Flux status
flux-status:
	flux get all -A --status

# Sync Flux manually
flux-sync:
	flux reconcile kustomization flux-system --with-source

# Reconcile cluster-apps (for faster secret/config updates)
reconcile:
	flux reconcile kustomization cluster-apps --with-source

# ═══════════════════════════════════════════════════════════════
# Secrets Management
# ═══════════════════════════════════════════════════════════════

# Encrypt a secret for Kubernetes
sops-encrypt:
ifndef FILE
	$(error FILE is required. Usage: make sops-encrypt FILE=path/to/secret.yaml)
endif
	sops --encrypt --in-place $(FILE)

# Edit an encrypted Kubernetes secret
sops-edit:
ifndef FILE
	$(error FILE is required. Usage: make sops-edit FILE=path/to/secret.sops.yaml)
endif
	sops $(FILE)

# View sentio-systems secrets (decrypted)
secrets-view:
	kubectl get secret sentio-secrets -n sentio-systems -o jsonpath='{.data}' | \
		jq 'to_entries | map({key: .key, value: (.value | @base64d)}) | from_entries'

# ═══════════════════════════════════════════════════════════════
# Kubernetes Operations
# ═══════════════════════════════════════════════════════════════

# Show K3s cluster info
k3s-info:
	kubectl cluster-info
	@echo ""
	kubectl get nodes

# List all nodes
nodes:
	kubectl get nodes -o wide

# List all pods across namespaces
pods:
	kubectl get pods -A

# List pods in a specific namespace
pods-ns:
ifndef NS
	$(error NS is required. Usage: make pods-ns NS=sentio-systems)
endif
	kubectl get pods -n $(NS)

# ═══════════════════════════════════════════════════════════════
# Debugging & Logs
# ═══════════════════════════════════════════════════════════════

# View Flux source-controller logs
logs-flux:
	kubectl logs -n flux-system -l app=source-controller --tail=50

# View sentio-backend logs
logs-sentio:
	kubectl logs deploy/sentio-backend -n sentio-systems --tail=50

# View sentio-keycloak logs
logs-keycloak:
	kubectl logs deploy/sentio-keycloak -n sentio-systems --tail=50

# ═══════════════════════════════════════════════════════════════
# Port Forwarding
# ═══════════════════════════════════════════════════════════════

# Forward Grafana to localhost:3000
port-grafana:
	kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80

# Forward Keycloak to localhost:8080
port-keycloak:
	kubectl port-forward svc/sentio-keycloak -n sentio-systems 8080:8080

# ═══════════════════════════════════════════════════════════════
# Sentio Operations
# ═══════════════════════════════════════════════════════════════

# Restart all sentio-systems deployments
restart-sentio:
	kubectl rollout restart deployment -n sentio-systems

# ═══════════════════════════════════════════════════════════════
# Testing
# ═══════════════════════════════════════════════════════════════

# Check HelmReleases status
helm-releases:
	kubectl get helmreleases -A
