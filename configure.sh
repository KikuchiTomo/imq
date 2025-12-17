#!/bin/bash

# IMQ Configuration Script
# This script sets up the IMQ environment by creating .env file
# and configuring necessary settings

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
ENV_EXAMPLE="${SCRIPT_DIR}/.env.example"

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

# Print banner
print_banner() {
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║  IMQ - Immediate Merge Queue Setup    ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
    echo ""
}

# Show usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Setup IMQ environment by creating .env file and configuring settings.

OPTIONS:
    -t, --github-token TOKEN              GitHub Personal Access Token
    -r, --repo OWNER/REPO                 GitHub repository (e.g., octocat/hello-world)
    -p, --api-port PORT                   API server port (default: 8080)
    -g, --gui-port PORT                   GUI server port (default: 8081)
    -e, --environment ENV                 Environment (development|staging|production, default: development)
    --webhook-proxy-url URL               External webhook proxy URL (e.g., https://abc.ngrok.io)
    --webhook-secret SECRET               Webhook secret for security (auto-generated if not provided)
    --trigger-label LABEL                 Trigger label for merge queue (default: A-merge)
    -b, --build                           Build projects after configuration
    -f, --force                           Force overwrite existing .env file
    -i, --interactive                     Interactive mode (default if no options provided)
    -h, --help                            Show this help message

EXAMPLES:
    # Interactive mode
    $0

    # Non-interactive mode with arguments
    $0 --github-token ghp_xxxxxxxxxxxx --repo owner/repo

    # With custom ports
    $0 -t ghp_xxxx -r owner/repo -p 9080 -g 9081

    # With external webhook proxy (ngrok, smee.io, etc.)
    $0 -t ghp_xxxx -r owner/repo --webhook-proxy-url https://abc.ngrok.io

    # With webhook secret
    $0 -t ghp_xxxx -r owner/repo --webhook-secret $(openssl rand -hex 32)

    # Force overwrite and build
    $0 -t ghp_xxxx -r owner/repo -f -b

EOF
    exit 1
}

# Parse command line arguments
GITHUB_TOKEN=""
GITHUB_REPO=""
API_PORT="8080"
GUI_PORT="8081"
ENVIRONMENT="development"
WEBHOOK_PROXY_URL=""
WEBHOOK_SECRET=""
TRIGGER_LABEL=""
BUILD_AFTER_CONFIG=false
FORCE_OVERWRITE=false
INTERACTIVE_MODE=false

# If no arguments, use interactive mode
if [ $# -eq 0 ]; then
    INTERACTIVE_MODE=true
fi

while [[ $# -gt 0 ]]; do
    case $1 in
        -t|--github-token)
            GITHUB_TOKEN="$2"
            shift 2
            ;;
        -r|--repo)
            GITHUB_REPO="$2"
            shift 2
            ;;
        -p|--api-port)
            API_PORT="$2"
            shift 2
            ;;
        -g|--gui-port)
            GUI_PORT="$2"
            shift 2
            ;;
        -e|--environment)
            ENVIRONMENT="$2"
            shift 2
            ;;
        --webhook-proxy-url)
            WEBHOOK_PROXY_URL="$2"
            shift 2
            ;;
        --webhook-secret)
            WEBHOOK_SECRET="$2"
            shift 2
            ;;
        --trigger-label)
            TRIGGER_LABEL="$2"
            shift 2
            ;;
        -b|--build)
            BUILD_AFTER_CONFIG=true
            shift
            ;;
        -f|--force)
            FORCE_OVERWRITE=true
            shift
            ;;
        -i|--interactive)
            INTERACTIVE_MODE=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            print_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Main configuration function
main() {
    print_banner

    # Check if .env already exists
    if [ -f "$ENV_FILE" ] && [ "$FORCE_OVERWRITE" = false ]; then
        print_warning ".env file already exists at: $ENV_FILE"
        read -p "Do you want to overwrite it? [y/N]: " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_info "Configuration cancelled. Use -f or --force to overwrite."
            exit 0
        fi
    fi

    # Check prerequisites
    check_prerequisites

    # Interactive mode or validate arguments
    if [ "$INTERACTIVE_MODE" = true ]; then
        interactive_configuration
    else
        validate_arguments
    fi

    # Create .env file
    create_env_file

    # Create necessary directories
    create_directories

    # Show configuration summary
    show_summary

    # Build projects if requested
    if [ "$BUILD_AFTER_CONFIG" = true ]; then
        build_projects
    fi

    # Show next steps
    show_next_steps

    print_success "Configuration completed successfully!"
}

# Check prerequisites
check_prerequisites() {
    print_info "Checking prerequisites..."

    # Check if .env.example exists
    if [ ! -f "$ENV_EXAMPLE" ]; then
        print_error ".env.example not found at: $ENV_EXAMPLE"
        exit 1
    fi

    # Check if swift is available
    if ! command -v swift &> /dev/null; then
        print_error "Swift is not installed"
        print_info "Install Swift from: https://swift.org/download/"
        exit 1
    else
        SWIFT_VERSION=$(swift --version | head -n 1)
        print_success "Swift is installed: $SWIFT_VERSION"
    fi

    echo ""
}

# Interactive configuration
interactive_configuration() {
    print_info "Starting interactive configuration..."
    echo ""

    # GitHub Token
    while [ -z "$GITHUB_TOKEN" ]; do
        read -p "Enter your GitHub Personal Access Token: " GITHUB_TOKEN
        if [ -z "$GITHUB_TOKEN" ]; then
            print_warning "GitHub token is required!"
        fi
    done

    # Validate token format
    if [[ ! "$GITHUB_TOKEN" =~ ^(ghp_|github_pat_|ghs_) ]]; then
        print_warning "Token format seems invalid (should start with ghp_, github_pat_, or ghs_)"
        read -p "Continue anyway? [y/N]: " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi

    # GitHub Repository
    echo ""
    while [ -z "$GITHUB_REPO" ]; do
        read -p "Enter your GitHub repository (OWNER/REPO): " GITHUB_REPO
        if [ -z "$GITHUB_REPO" ]; then
            print_warning "GitHub repository is required!"
        elif [[ ! "$GITHUB_REPO" =~ ^[^/]+/[^/]+$ ]]; then
            print_warning "Invalid repository format. Use OWNER/REPO (e.g., octocat/hello-world)"
            GITHUB_REPO=""
        fi
    done

    # Webhook proxy configuration
    echo ""
    echo "Webhook Proxy URL (required for receiving webhooks):"
    echo "Examples:"
    echo "  - ngrok: https://abc123.ngrok-free.app"
    echo "  - smee.io: https://smee.io/abc123"
    echo "  - Cloudflare Tunnel: https://imq.your-domain.com"
    echo ""
    read -p "Enter your webhook proxy URL (or leave empty to configure later): " WEBHOOK_PROXY_URL

    # Webhook secret
    echo ""
    read -p "Generate webhook secret for security? [Y/n]: " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        WEBHOOK_SECRET=$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | xxd -p -c 32)
        print_success "Webhook secret generated"
    fi

    # Trigger label
    echo ""
    read -p "Trigger label for merge queue [A-merge]: " INPUT_TRIGGER_LABEL
    TRIGGER_LABEL=${INPUT_TRIGGER_LABEL:-A-merge}

    # API Port
    echo ""
    read -p "API Server port [${API_PORT}]: " INPUT_API_PORT
    API_PORT=${INPUT_API_PORT:-$API_PORT}

    # GUI Port
    read -p "GUI Server port [${GUI_PORT}]: " INPUT_GUI_PORT
    GUI_PORT=${INPUT_GUI_PORT:-$GUI_PORT}

    # Environment
    echo ""
    echo "Environment:"
    echo "  1) development (default)"
    echo "  2) staging"
    echo "  3) production"
    read -p "Select environment [1]: " ENV_CHOICE
    ENV_CHOICE=${ENV_CHOICE:-1}
    case $ENV_CHOICE in
        2) ENVIRONMENT="staging" ;;
        3) ENVIRONMENT="production" ;;
        *) ENVIRONMENT="development" ;;
    esac

    # Build after config
    echo ""
    read -p "Build projects after configuration? [Y/n]: " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        BUILD_AFTER_CONFIG=true
    fi

    echo ""
}

# Validate non-interactive arguments
validate_arguments() {
    if [ -z "$GITHUB_TOKEN" ]; then
        print_error "GitHub token is required. Use -t or --github-token"
        usage
    fi

    if [ -z "$GITHUB_REPO" ]; then
        print_error "GitHub repository is required. Use -r or --repo"
        usage
    fi

    if [[ ! "$GITHUB_REPO" =~ ^[^/]+/[^/]+$ ]]; then
        print_error "Invalid repository format: $GITHUB_REPO. Must be OWNER/REPO"
        usage
    fi

    if ! [[ "$API_PORT" =~ ^[0-9]+$ ]] || [ "$API_PORT" -lt 1 ] || [ "$API_PORT" -gt 65535 ]; then
        print_error "Invalid API port: $API_PORT. Must be between 1 and 65535"
        usage
    fi

    if ! [[ "$GUI_PORT" =~ ^[0-9]+$ ]] || [ "$GUI_PORT" -lt 1 ] || [ "$GUI_PORT" -gt 65535 ]; then
        print_error "Invalid GUI port: $GUI_PORT. Must be between 1 and 65535"
        usage
    fi

    if [[ ! "$ENVIRONMENT" =~ ^(development|staging|production)$ ]]; then
        print_error "Invalid environment: $ENVIRONMENT. Must be 'development', 'staging', or 'production'"
        usage
    fi

    # Validate webhook proxy URL format if provided
    if [ ! -z "$WEBHOOK_PROXY_URL" ] && [[ ! "$WEBHOOK_PROXY_URL" =~ ^https?:// ]]; then
        print_error "Invalid webhook proxy URL: $WEBHOOK_PROXY_URL. Must start with http:// or https://"
        usage
    fi

    # Auto-generate webhook secret if not provided
    if [ -z "$WEBHOOK_SECRET" ]; then
        WEBHOOK_SECRET=$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | xxd -p -c 32)
        print_info "Auto-generated webhook secret for security"
    fi

    # Set default trigger label if not provided
    if [ -z "$TRIGGER_LABEL" ]; then
        TRIGGER_LABEL="A-merge"
    fi
}

# Create .env file
create_env_file() {
    print_info "Creating .env file..."

    cat > "$ENV_FILE" << EOF
# ========================================
# IMQ - Immediate Merge Queue Configuration
# ========================================
# Generated by configure.sh on $(date)

# ========================================
# GitHub Configuration
# ========================================
IMQ_GITHUB_TOKEN=${GITHUB_TOKEN}
IMQ_GITHUB_REPO=${GITHUB_REPO}
IMQ_GITHUB_API_URL=https://api.github.com

# ========================================
# Webhook Configuration
# ========================================
IMQ_WEBHOOK_SECRET=${WEBHOOK_SECRET}
IMQ_WEBHOOK_PROXY_URL=${WEBHOOK_PROXY_URL}
IMQ_TRIGGER_LABEL=${TRIGGER_LABEL:-A-merge}

# ========================================
# Database Configuration
# ========================================
# Using default: ~/.imq/imq.db
# IMQ_DATABASE_PATH=
IMQ_DATABASE_POOL_SIZE=5

# ========================================
# API Server Configuration (imq-core)
# ========================================
IMQ_API_HOST=0.0.0.0
IMQ_API_PORT=${API_PORT}

# ========================================
# GUI Configuration (imq-gui)
# ========================================
IMQ_GUI_HOST=0.0.0.0
IMQ_GUI_PORT=${GUI_PORT}
IMQ_GUI_API_URL=http://localhost:${API_PORT}
IMQ_GUI_WS_URL=ws://localhost:${API_PORT}/ws/events

# ========================================
# Logging Configuration
# ========================================
IMQ_LOG_LEVEL=info
IMQ_LOG_FORMAT=pretty

# ========================================
# Runtime Configuration
# ========================================
IMQ_ENVIRONMENT=${ENVIRONMENT}
IMQ_DEBUG=false
EOF

    chmod 600 "$ENV_FILE"  # Protect sensitive file
    print_success ".env file created at: $ENV_FILE"
}

# Create necessary directories
create_directories() {
    print_info "Creating necessary directories..."

    # Create ~/.imq directory for database
    IMQ_DIR="${HOME}/.imq"
    if [ ! -d "$IMQ_DIR" ]; then
        mkdir -p "$IMQ_DIR"
        print_success "Created directory: $IMQ_DIR"
    else
        print_info "Directory already exists: $IMQ_DIR"
    fi

    # Create logs directory (optional)
    LOGS_DIR="${SCRIPT_DIR}/logs"
    if [ ! -d "$LOGS_DIR" ]; then
        mkdir -p "$LOGS_DIR"
        print_success "Created directory: $LOGS_DIR"
    fi
}

# Build projects
build_projects() {
    print_info "Building projects..."
    echo ""

    # Build imq-core
    print_info "Building imq-core..."
    cd "${SCRIPT_DIR}/imq-core"
    if swift build; then
        print_success "imq-core built successfully"
    else
        print_error "Failed to build imq-core"
        exit 1
    fi

    # Build imq-gui
    print_info "Building imq-gui..."
    cd "${SCRIPT_DIR}/imq-gui"
    if swift build; then
        print_success "imq-gui built successfully"
    else
        print_error "Failed to build imq-gui"
        exit 1
    fi

    cd "${SCRIPT_DIR}"
    echo ""
}

# Show configuration summary
show_summary() {
    echo ""
    print_info "Configuration Summary:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  GitHub Repo:     ${GITHUB_REPO}"
    if [ ! -z "$WEBHOOK_PROXY_URL" ]; then
        echo "  Webhook Proxy:   ${WEBHOOK_PROXY_URL}"
    else
        echo "  Webhook Proxy:   (not configured - set IMQ_WEBHOOK_PROXY_URL in .env)"
    fi
    if [ ! -z "$TRIGGER_LABEL" ]; then
        echo "  Trigger Label:   ${TRIGGER_LABEL}"
    fi
    echo "  API Port:        ${API_PORT}"
    echo "  GUI Port:        ${GUI_PORT}"
    echo "  Environment:     ${ENVIRONMENT}"
    echo "  Database:        ~/.imq/imq.db"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

# Show next steps
show_next_steps() {
    echo ""
    print_info "Next Steps:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [ "$BUILD_AFTER_CONFIG" = false ]; then
        echo "  1. Build the projects:"
        echo -e "     ${GREEN}make build${NC}"
        echo ""
    fi

    echo "  1. Start all services:"
    echo -e "     ${GREEN}./run.sh${NC}"
    if [ ! -z "$WEBHOOK_PROXY_URL" ]; then
        echo "     (Webhook proxy configured: ${WEBHOOK_PROXY_URL})"
    else
        echo "     (Configure IMQ_WEBHOOK_PROXY_URL in .env to receive webhooks)"
    fi
    echo ""
    echo "  2. Or run as daemon:"
    echo -e "     ${GREEN}./svc.sh start${NC}"
    echo ""
    echo "  3. Access the GUI:"
    echo -e "     ${GREEN}http://localhost:${GUI_PORT}${NC}"
    echo ""

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

# Run main function
main
