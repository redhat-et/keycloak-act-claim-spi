.PHONY: all build test clean image push deploy verify quick-deploy help

# Variables
VERSION ?= 1.0.0-SNAPSHOT
IMAGE_NAME := keycloak-act-claim-spi
REGISTRY ?= ghcr.io/pavelanni
IMAGE := $(REGISTRY)/$(IMAGE_NAME):$(VERSION)
CONTAINER_ENGINE ?= podman

# Remote Podman connection (e.g., PODMAN_CONNECTION=rhel)
# When set, builds run on the remote host via 'podman --connection <name>'
PODMAN_CONNECTION ?=
ifdef PODMAN_CONNECTION
  CONTAINER_ENGINE := podman --connection $(PODMAN_CONNECTION)
  # No --platform needed when building on native x86_64
  PLATFORM_FLAG :=
else
  PLATFORM_FLAG := --platform linux/amd64
endif

# Default target
all: build

# Build the JAR
build:
	mvn clean package

# Run unit tests
test:
	mvn test

# Clean build artifacts
clean:
	mvn clean

# Build the container image (x86_64)
image: build
	$(CONTAINER_ENGINE) build $(PLATFORM_FLAG) -t $(IMAGE) .

# Push the container image
push:
	$(CONTAINER_ENGINE) push $(IMAGE)

# Build and push in one step
release: image push

# Deploy to OpenShift
deploy:
	oc patch deployment keycloak -n spiffe-demo \
		--patch-file k8s/keycloak-deployment-patch.yaml

# Verify the SPI is loaded
verify:
	oc logs deployment/keycloak -n spiffe-demo | grep -i "act-claim"

# Quick iteration: copy JAR into running pod and restart
quick-deploy: build
	oc cp target/$(IMAGE_NAME)-$(VERSION).jar \
		spiffe-demo/$$(oc get pod -n spiffe-demo -l app=keycloak \
		-o jsonpath='{.items[0].metadata.name}'):/opt/keycloak/providers/
	oc rollout restart deployment/keycloak -n spiffe-demo

# Help
help:
	@echo "Keycloak Act Claim SPI"
	@echo ""
	@echo "Targets:"
	@echo "  make build        - Build the JAR (mvn clean package)"
	@echo "  make test         - Run unit tests"
	@echo "  make clean        - Clean build artifacts"
	@echo "  make image        - Build x86_64 container image"
	@echo "  make push         - Push container image to registry"
	@echo "  make release      - Build and push image"
	@echo "  make deploy       - Patch OpenShift deployment"
	@echo "  make verify       - Check SPI loaded in Keycloak logs"
	@echo "  make quick-deploy - Copy JAR to pod and restart (dev only)"
	@echo ""
	@echo "Variables:"
	@echo "  REGISTRY            - Container registry (default: ghcr.io/pavelanni)"
	@echo "  VERSION             - Image tag (default: 1.0.0-SNAPSHOT)"
	@echo "  PODMAN_CONNECTION   - Remote Podman host (e.g., rhel) for native x86_64 builds"
	@echo ""
	@echo "Examples:"
	@echo "  make image                          # local build with QEMU emulation"
	@echo "  make image PODMAN_CONNECTION=rhel    # build on remote x86_64 host"
	@echo "  make release PODMAN_CONNECTION=rhel  # build + push from remote host"
