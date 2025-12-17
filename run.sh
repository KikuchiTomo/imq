#!/bin/bash

# IMQ Run Script
# Start all IMQ services (imq-core, imq-gui, gh webhook forward)

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
PID_FILE="${SCRIPT_DIR}/.imq.pid"

# PIDs of child processes
CORE_PID=""
GUI_PID=""

# Cleanup flag
CLEANUP_DONE=false

# Print colored message
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_core() {
    echo -e "${CYAN}[CORE]${NC} $1"
}

print_gui() {
    echo -e "${MAGENTA}[GUI]${NC} $1"
}

print_webhook() {
    echo -e "${YELLOW}[WEBHOOK]${NC} $1"
}

# Print banner
print_banner() {
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║    IMQ - Immediate Merge Queue         ║${NC}"
    echo -e "${BLUE}║         Starting Services...           ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
    echo ""
}

# Load environment variables from .env
load_env() {
    if [ ! -f "$ENV_FILE" ]; then
        print_error ".env file not found at: $ENV_FILE"
        print_info "Please run ./configure.sh first to set up your environment"
        exit 1
    fi

    print_info "Loading environment from: $ENV_FILE"

    # Export variables from .env
    set -a
    source "$ENV_FILE"
    set +a

    print_success "Environment loaded successfully"
}

# Check prerequisites
check_prerequisites() {
    print_info "Checking prerequisites..."

    # Check if swift is available
    if ! command -v swift &> /dev/null; then
        print_error "Swift is not installed"
        exit 1
    fi

    # Check if projects are built
    if [ ! -d "${SCRIPT_DIR}/imq-core/.build" ]; then
        print_warning "imq-core is not built. Building now..."
        cd "${SCRIPT_DIR}/imq-core"
        swift build
        cd "${SCRIPT_DIR}"
    fi

    if [ ! -d "${SCRIPT_DIR}/imq-gui/.build" ]; then
        print_warning "imq-gui is not built. Building now..."
        cd "${SCRIPT_DIR}/imq-gui"
        swift build
        cd "${SCRIPT_DIR}"
    fi

    print_success "All prerequisites met"
}

# Cleanup function
cleanup() {
    if [ "$CLEANUP_DONE" = true ]; then
        return
    fi
    CLEANUP_DONE=true

    echo ""
    print_info "Shutting down services..."

    # Kill all child processes
    if [ ! -z "$GUI_PID" ] && kill -0 "$GUI_PID" 2>/dev/null; then
        print_gui "Stopping GUI server (PID: $GUI_PID)..."
        kill "$GUI_PID" 2>/dev/null || true
    fi

    if [ ! -z "$CORE_PID" ] && kill -0 "$CORE_PID" 2>/dev/null; then
        print_core "Stopping Core server (PID: $CORE_PID)..."
        kill "$CORE_PID" 2>/dev/null || true
    fi

    # Wait for processes to terminate
    sleep 1

    # Force kill if still running
    for pid in $GUI_PID $CORE_PID; do
        if [ ! -z "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null || true
        fi
    done

    # Remove PID file
    rm -f "$PID_FILE"

    print_success "All services stopped"
    exit 0
}

# Set up signal handlers
trap cleanup SIGINT SIGTERM EXIT

# Start imq-core server
start_core() {
    print_core "Starting imq-core server on port ${IMQ_API_PORT:-8080}..."

    cd "${SCRIPT_DIR}/imq-core"

    # Export environment variables
    export IMQ_GITHUB_TOKEN
    export IMQ_GITHUB_REPO
    export IMQ_GITHUB_API_URL
    export IMQ_WEBHOOK_SECRET
    export IMQ_WEBHOOK_PROXY_URL
    export IMQ_TRIGGER_LABEL
    export IMQ_DATABASE_PATH
    export IMQ_DATABASE_POOL_SIZE
    export IMQ_API_HOST
    export IMQ_API_PORT
    export IMQ_LOG_LEVEL
    export IMQ_LOG_FORMAT
    export IMQ_ENVIRONMENT
    export IMQ_DEBUG

    # Start server
    swift run imq-server 2>&1 | while IFS= read -r line; do
        print_core "$line"
    done &

    CORE_PID=$!
    cd "${SCRIPT_DIR}"

    # Wait a bit to see if it crashes immediately
    sleep 2
    if ! kill -0 "$CORE_PID" 2>/dev/null; then
        print_error "Failed to start imq-core server"
        exit 1
    fi

    print_success "imq-core started (PID: $CORE_PID)"
}

# Start imq-gui server
start_gui() {
    print_gui "Starting imq-gui server on port ${IMQ_GUI_PORT:-8081}..."

    cd "${SCRIPT_DIR}/imq-gui"

    # Export environment variables
    export IMQ_GUI_HOST
    export IMQ_GUI_PORT
    export IMQ_GUI_API_URL
    export IMQ_GUI_WS_URL
    export IMQ_ENVIRONMENT
    export IMQ_DEBUG

    # Start server
    swift run imq-gui 2>&1 | while IFS= read -r line; do
        print_gui "$line"
    done &

    GUI_PID=$!
    cd "${SCRIPT_DIR}"

    # Wait a bit to see if it crashes immediately
    sleep 2
    if ! kill -0 "$GUI_PID" 2>/dev/null; then
        print_error "Failed to start imq-gui server"
        exit 1
    fi

    print_success "imq-gui started (PID: $GUI_PID)"
}

# Show webhook configuration
show_webhook_config() {
    echo ""
    if [ ! -z "${IMQ_WEBHOOK_PROXY_URL}" ]; then
        print_success "Webhook proxy configured: ${IMQ_WEBHOOK_PROXY_URL}"
        echo ""
        print_info "To receive webhooks, configure your GitHub repository:"
        echo ""
        echo -e "  ${YELLOW}1. Go to your repository settings:${NC}"
        if [ ! -z "${IMQ_GITHUB_REPO}" ]; then
            echo -e "     https://github.com/${IMQ_GITHUB_REPO}/settings/hooks"
        else
            echo -e "     https://github.com/OWNER/REPO/settings/hooks"
        fi
        echo ""
        echo -e "  ${YELLOW}2. Add a new webhook with:${NC}"
        echo -e "     ${GREEN}Payload URL:${NC} ${IMQ_WEBHOOK_PROXY_URL}/"
        echo -e "     ${GREEN}Content type:${NC} application/json"
        if [ ! -z "${IMQ_WEBHOOK_SECRET}" ]; then
            echo -e "     ${GREEN}Secret:${NC} (use value from IMQ_WEBHOOK_SECRET in .env)"
        fi
        echo -e "     ${GREEN}Events:${NC} Select 'Send me everything' or specific events"
        echo ""
        print_info "Make sure your reverse proxy forwards to: http://localhost:${IMQ_API_PORT:-8080}/"
    else
        print_warning "Webhook proxy URL is not configured"
        print_info "To receive webhooks, set IMQ_WEBHOOK_PROXY_URL in .env"
        echo ""
        echo -e "  Examples:"
        echo -e "    ${GREEN}IMQ_WEBHOOK_PROXY_URL=https://abc123.ngrok-free.app${NC}"
        echo -e "    ${GREEN}IMQ_WEBHOOK_PROXY_URL=https://smee.io/abc123${NC}"
        echo -e "    ${GREEN}IMQ_WEBHOOK_PROXY_URL=https://imq.your-domain.com${NC}"
    fi
    echo ""
}

# Save PIDs to file
save_pids() {
    cat > "$PID_FILE" << EOF
CORE_PID=$CORE_PID
GUI_PID=$GUI_PID
EOF
    print_info "PIDs saved to: $PID_FILE"
}

# Show service URLs
show_urls() {
    echo ""
    print_success "All services are running!"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  ${MAGENTA}GUI:${NC}      http://localhost:${IMQ_GUI_PORT:-8081}"
    echo -e "  ${CYAN}API:${NC}      http://localhost:${IMQ_API_PORT:-8080}"
    echo -e "  ${CYAN}WebSocket:${NC} ws://localhost:${IMQ_API_PORT:-8080}/ws/events"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    print_info "Press Ctrl+C to stop all services"
    echo ""
}

# Main function
main() {
    print_banner

    # Load environment
    load_env

    # Check prerequisites
    check_prerequisites

    echo ""

    # Start services
    start_core
    sleep 2  # Wait for core to initialize

    start_gui
    sleep 2  # Wait for gui to initialize

    # Save PIDs
    save_pids

    # Show URLs and webhook configuration
    show_urls
    show_webhook_config

    # Wait for all processes
    wait
}

# Run main function
main
