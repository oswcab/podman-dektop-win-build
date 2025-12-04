#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

CONTAINER_BUILDER=${CONTAINER_BUILDER:-docker}
CERT_MANAGER_VERSION=${CERT_MANAGER_VERSION:-v1.16.3}
CLUSTER_NAME="konflux-dev-env"
SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
PROJECT_ROOT="$(realpath "$SCRIPT_DIR/..")"
KONFLUX_DIR="${PROJECT_ROOT}/dependencies/konflux-ci/src"
INSTALL_KONFLUX=false
# Start with cleanup disabled, enable after cluster is created
CLEANUP_ON_EXIT=false
# Allow user to override cleanup behavior
CLEANUP_ON_INTERRUPT_OVERRIDE=""

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

fatal() {
    error "$1"
    exit 1
}

# Trap handler for cleanup on interrupt
trap_handler() {
    echo ""
    warn "Interrupt signal received"
    if [ "$CLEANUP_ON_EXIT" = true ]; then
        cleanup
    else
        warn "Cluster '$CLUSTER_NAME' was not fully created"
        warn "You may want to clean up manually with: kind delete cluster --name $CLUSTER_NAME"
    fi
    exit 130
}

# Set up trap for interrupt signals
trap trap_handler INT TERM

# Check if required tools are installed
check_prerequisites() {
    log "Checking prerequisites..."

    if ! command -v kind &>/dev/null; then
        error "kind is not installed. Please install kind first."
        fatal "Install with: go install sigs.k8s.io/kind@v0.20.0"
    fi

    if ! command -v kubectl &>/dev/null; then
        fatal "kubectl is not installed. Please install kubectl first."
    fi

    if ! command -v git &>/dev/null; then
        fatal "git is not installed. Please install git first."
    fi

    if ! command -v openssl &>/dev/null; then
        fatal "openssl is not installed. Please install openssl first."
    fi

    if ! command -v kustomize &>/dev/null; then
        error "kustomize is not installed. Please install kustomize first."
        fatal "Install with: go install sigs.k8s.io/kustomize/kustomize/v5@latest"
    fi

    log "All prerequisites are installed"
}

# Configure inotify limits for Kubernetes
configure_inotify_limits() {
    log "Configuring inotify limits..."

    # Check current limits
    local current_instances
    local current_watches
    current_instances=$(sysctl -n fs.inotify.max_user_instances)
    current_watches=$(sysctl -n fs.inotify.max_user_watches)

    if ((current_watches < 524288)) || ((current_instances < 512)); then
        warn "Current inotify limits are too low"
        log "Attempting to increase limits (may require sudo)..."
        sudo sysctl -w fs.inotify.max_user_watches=524288
        sudo sysctl -w fs.inotify.max_user_instances=512
        log "inotify limits configured"
    fi
}

# Cleanup function
cleanup() {
    log "Cleaning up cluster '$CLUSTER_NAME'..."
    kind delete cluster --name "$CLUSTER_NAME" || true
    log "Cleanup completed"
}

# Create kind cluster
create_cluster() {
    log "Creating kind cluster '$CLUSTER_NAME'..."

    # Check if cluster already exists
    if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
        warn "Cluster '$CLUSTER_NAME' already exists. Deleting..."
        cleanup
    fi

    # Create cluster with custom config
    kind create cluster --name "$CLUSTER_NAME" --config "${SCRIPT_DIR}/kind-config.yaml"

    # Enable cleanup on interrupt now that cluster exists (unless user disabled it)
    if [ "$CLEANUP_ON_INTERRUPT_OVERRIDE" != "no" ]; then
        CLEANUP_ON_EXIT=true
    fi

    log "Cluster created successfully"
}

check_konflux_dir() {
    if [[ ! -d "$KONFLUX_DIR" ]]; then
        error "Konflux repository not found at $KONFLUX_DIR"
        fatal "Please run: git submodule update --init --recursive"
    fi
}

# Install Konflux Dependencies (modified to skip Kyverno and Smee)
install_konflux_dependencies() {
    log "Installing Konflux dependencies..."

    check_konflux_dir
    pushd "$KONFLUX_DIR" >/dev/null

    # Install cert-manager first and wait for it to be ready
    # Other components depend on cert-manager's validating webhook
    log "Installing cert-manager..."
    kubectl apply --server-side -k "dependencies/cert-manager"

    log "Waiting for cert-manager to be ready..."
    kubectl wait --for=condition=Available deployment --all -n cert-manager --timeout=300s

    # Install trust-manager and cluster-issuer (depend on cert-manager)
    log "Installing trust-manager..."
    kubectl apply --server-side -k "dependencies/trust-manager"

    log "Waiting for trust-manager to be ready..."
    kubectl wait --for=condition=Available deployment --all -n cert-manager --timeout=300s

    log "Installing cluster-issuer..."
    kubectl apply --server-side -k "dependencies/cluster-issuer"

    # Install Tekton Operator and wait for it to set up the infrastructure
    log "Installing tekton-operator..."
    kubectl apply --server-side -k "dependencies/tekton-operator"

    log "Waiting for Tekton operator to be ready..."
    kubectl wait --for=condition=Available deployment --all -n tekton-operator --timeout=300s

    # Wait for tekton-pipelines namespace to be created by the operator
    log "Waiting for tekton-pipelines namespace to be created..."
    while ! kubectl get namespace tekton-pipelines &>/dev/null; do
        sleep 2
    done
    log "tekton-pipelines namespace is ready"

    # Now install Tekton configuration (depends on tekton-pipelines namespace)
    # Use --force-conflicts because the operator creates a default TektonConfig
    log "Installing tekton-config..."
    kubectl apply --server-side --force-conflicts -k "dependencies/tekton-config"

    # Wait for Tekton Pipelines to be fully ready (including webhook)
    log "Waiting for Tekton Pipelines deployments to be created..."
    # Wait for the webhook deployment to exist (key indicator that pipelines are being deployed)
    while ! kubectl get deployment tekton-pipelines-webhook -n tekton-pipelines &>/dev/null; do
        sleep 2
    done

    log "Waiting for Tekton Pipelines to be ready..."
    kubectl wait --for=condition=Available deployment --all -n tekton-pipelines --timeout=300s

    log "Waiting for Tekton Pipelines webhook to be ready..."
    kubectl wait --for=condition=Available deployment tekton-pipelines-webhook -n tekton-pipelines --timeout=300s

    # Give the webhook a few extra seconds to be fully operational
    log "Allowing webhook endpoints to stabilize..."
    sleep 10

    # Install remaining dependencies (skipping Dex for now - requires oauth2-proxy-client-secret)
    local deps=(
        "pipelines-as-code"
        "tekton-chains-rbac"
        "registry"
        "pre-deployment-pvc-binding"
        "konflux-info"
    )

    for dep in "${deps[@]}"; do
        log "Installing $dep..."
        kubectl apply --server-side -k "dependencies/$dep"
    done

    # Note: Dex is skipped because it requires oauth2-proxy-client-secret which is not
    # created by the dependencies. Dex is primarily for UI authentication which may not
    # be needed for MPC development.

    popd >/dev/null
    log "Konflux dependencies installed successfully"
}

# Install Konflux core components (optional - without UI)
install_konflux() {
    if [ "$INSTALL_KONFLUX" = false ]; then
        log "Skipping Konflux core components installation..."
        log "To install Konflux components, run with: --with-konflux flag"
        return
    fi

    log "Installing Konflux core components (excluding UI)..."
    check_konflux_dir
    pushd "$KONFLUX_DIR" >/dev/null

    # Deploy Konflux core components (excluding UI)
    log "Deploying Application API CRDs..."
    kubectl apply -k "konflux-ci/application-api"

    log "Setting up RBAC permissions..."
    kubectl apply -k "konflux-ci/rbac"

    log "Deploying Enterprise Contract..."
    kubectl apply -k "konflux-ci/enterprise-contract"

    log "Deploying Release Service..."
    kubectl apply -k "konflux-ci/release" --server-side

    log "Deploying Build Service..."
    kubectl apply -k "konflux-ci/build-service"

    log "Deploying Integration Service..."
    kubectl apply -k "konflux-ci/integration"

    log "Setting up Namespace Lister..."
    kubectl apply -k "konflux-ci/namespace-lister"

    popd >/dev/null
    log "Konflux core components installed successfully (UI skipped)"
}

build_and_install_mpc() {
    log "Building Multi-Platform Controller"

    local mpc_image="multi-platform-controller:latest"
    local otp_image="multi-platform-otp-server:latest"
    local mpc_dir
    mpc_dir="${PROJECT_ROOT}/dependencies/multi-platform-controller"
    local mpc_src="${mpc_dir}/src"
    local map_cfg="${mpc_dir}/config"

    ${CONTAINER_BUILDER} build "${mpc_src}" -t "${mpc_image}"

    ${CONTAINER_BUILDER} build "${mpc_src}" -f "${mpc_src}/Dockerfile.otp" -t "${otp_image}"

    log "Loading Multi-Platform Controller's image into Kind cluster"

    # When using podman, images are tagged with localhost/ prefix
    # Load the images with their actual names from the builder
    if [[ "${CONTAINER_BUILDER}" == "podman" ]]; then
        kind load docker-image "localhost/${mpc_image}" --name "${CLUSTER_NAME}"
        kind load docker-image "localhost/${otp_image}" --name "${CLUSTER_NAME}"
    else
        kind load docker-image "${mpc_image}" --name "${CLUSTER_NAME}"
        kind load docker-image "${otp_image}" --name "${CLUSTER_NAME}"
    fi

    log "Applying Multi-Platform Controller"

    # When using podman, patch the deployment to use localhost/ prefix
    if [[ "${CONTAINER_BUILDER}" == "podman" ]]; then
        kustomize build "${map_cfg}" |
            sed -e "s|image: ${mpc_image}|image: localhost/${mpc_image}|g" \
                -e "s|image: ${otp_image}|image: localhost/${otp_image}|g" |
            kubectl apply -f -
    else
        kustomize build "${map_cfg}" | kubectl apply -f -
    fi

    log "Waiting for Multi-Platform Controller to be ready..."
    kubectl wait --for=condition=Available deployment --all --timeout 300s -n multi-platform-controller
    log "Multi-Platform Controller Installed"
}

# Main execution
main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
        --cleanup | -c)
            cleanup
            exit 0
            ;;
        --with-konflux | -k)
            INSTALL_KONFLUX=true
            shift
            ;;
        --no-cleanup-on-interrupt | -n)
            CLEANUP_ON_INTERRUPT_OVERRIDE="no"
            shift
            ;;
        --help | -h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --cleanup, -c                  Delete the kind cluster"
            echo "  --with-konflux, -k             Install Konflux core components (excluding UI)"
            echo "  --no-cleanup-on-interrupt, -n  Don't delete cluster on Ctrl-C (for debugging)"
            echo "  --help, -h                     Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0                             # Install MPC with Tekton only"
            echo "  $0 --with-konflux              # Install MPC with Konflux core components"
            echo "  $0 --no-cleanup-on-interrupt   # Keep cluster if interrupted"
            echo "  $0 --cleanup                   # Delete the cluster"
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            echo "Run '$0 --help' for usage information"
            exit 1
            ;;
        esac
    done

    log "Starting Konflux Dev Env cluster setup..."
    check_prerequisites
    configure_inotify_limits
    create_cluster
    install_konflux_dependencies
    install_konflux
    build_and_install_mpc

    log "Setup completed! Cluster info:"
    kubectl cluster-info --context "kind-$CLUSTER_NAME"

    log ""
    log "====================================="
    log "  Development Environment Ready"
    log "====================================="
    log ""
    log "Components installed:"
    log "  - Tekton Pipelines (via Operator)"
    log "  - Tekton Chains"
    log "  - Pipelines as Code"
    log "  - Container Registry: localhost:8888"
    if [ "$INSTALL_KONFLUX" = true ]; then
        log "  - Konflux core components (application-api, build-service, integration, etc.)"
    fi
    log "  - Multi-Platform Controller"
    log ""
    log "To use this cluster: kubectl config use-context kind-$CLUSTER_NAME"
    log "To delete this cluster: kind delete cluster --name $CLUSTER_NAME"
    log ""
    if [ "$INSTALL_KONFLUX" = false ]; then
        log "Note: Konflux core services not installed (use --with-konflux to install)"
    fi
    log "Note: Konflux UI and Dex are not installed"
    log "      For full Konflux with UI, run: ${KONFLUX_DIR}/deploy-konflux.sh"
}

# Run main function
main "$@"
