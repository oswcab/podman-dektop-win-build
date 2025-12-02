#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

CONTAINER_BUILDER=${CONTAINER_BUILDER:-docker}
CERT_MANAGER_VERSION=${CERT_MANAGER_VERSION:-v1.16.3}
CLUSTER_NAME="mpc-dev-env"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if required tools are installed
check_prerequisites() {
    log "Checking prerequisites..."
    
    if ! command -v kind &> /dev/null; then
        error "kind is not installed. Please install kind first."
        echo "Install with: go install sigs.k8s.io/kind@v0.20.0"
        exit 1
    fi
    
    if ! command -v kubectl &> /dev/null; then
        error "kubectl is not installed. Please install kubectl first."
        exit 1
    fi
        
    log "All prerequisites are installed"
}

# Create kind cluster
create_cluster() {
    log "Creating kind cluster '$CLUSTER_NAME'..."
    
    # Check if cluster already exists
    if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
        warn "Cluster '$CLUSTER_NAME' already exists. Deleting..."
        kind delete cluster --name "$CLUSTER_NAME"
    fi
    
    # Create cluster with custom config
    kind create cluster --name "$CLUSTER_NAME"
    
    log "Cluster created successfully"
}

# Install Cert Manager
install_cert_manager() {
  kubectl apply --server-side -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
  kubectl wait --for=condition=Available deployment --all -n cert-manager --timeout=300s
}

# Install Tekton Pipelines
install_tekton_pipelines() {
    log "Installing Tekton Pipelines..."
    kubectl apply --filename https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml 

    log "Waiting for Tekton Pipelines to be ready..."
    kubectl wait --for=condition=Available deployment --all --timeout 300s -n tekton-pipelines
    kubectl wait --for=condition=Available deployment --all --timeout 300s -n tekton-pipelines

    log "Tekton Pipelines installed successfully..."
}

build_and_install_mpc() {
  log "Building Multi-Platform Controller"

  ${CONTAINER_BUILDER} build \
    "${PROJECT_ROOT}/dependencies/multi-platform-controller/src" \
    -t multi-platform-controller:latest

  ${CONTAINER_BUILDER} build \
    "${PROJECT_ROOT}/dependencies/multi-platform-controller/src" \
    -f "${PROJECT_ROOT}/dependencies/multi-platform-controller/src/Dockerfile.otp" \
    -t multi-platform-otp-server:latest

  log "Loading Multi-Platform Controller's image into Kind cluster"
  kind load docker-image multi-platform-controller:latest --name "${CLUSTER_NAME}"
  kind load docker-image multi-platform-otp-server:latest --name "${CLUSTER_NAME}"
  
  log "Applying Multi-Platform Controller"
  kustomize build "${PROJECT_ROOT}/dependencies/multi-platform-controller/config" | \
    kubectl apply -f -

  log "Waiting for Multi-Platform Controller to be ready..."
  kubectl wait --for=condition=Available deployment --all --timeout 300s -n multi-platform-controller
  log "Multi-Platform Controller Installed"
}

# Main execution
main() {
    log "Starting MPC Dev Env cluster setup..."
    
    check_prerequisites
    create_cluster
    install_cert_manager
    install_tekton_pipelines
    build_and_install_mpc
    
    log "Setup completed! Cluster info:"
    kubectl cluster-info --context "kind-$CLUSTER_NAME"
    
    log "To use this cluster, run: kubectl config use-context kind-$CLUSTER_NAME"
    log "To delete this cluster, run: kind delete cluster --name $CLUSTER_NAME"
}

# Cleanup function
cleanup() {
    if [ "$1" = "--cleanup" ] || [ "$1" = "-c" ]; then
        log "Cleaning up cluster '$CLUSTER_NAME'..."
        kind delete cluster --name "$CLUSTER_NAME" || true
        log "Cleanup completed"
        exit 0
    fi
}

# Handle cleanup argument
cleanup "$1"

# Run main function
main
