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
    -t, --github-token TOKEN    GitHub Personal Access Token
    -r, --repo OWNER/REPO       GitHub repository (e.g., octocat/hello-world)
    -m, --mode MODE            GitHub integration mode (polling|webhook, default: webhook)
    -p, --api-port PORT        API server port (default: 8080)
    -g, --gui-port PORT        GUI server port (default: 8081)
    -e, --environment ENV      Environment (development|staging|production, default: development)
    -b, --build                Build projects after configuration
    -f, --force                Force overwrite existing .env file
    -i, --interactive          Interactive mode (default if no options provided)
    -h, --help                 Show this help message

EXAMPLES:
    # Interactive mode
    $0

    # Non-interactive mode with arguments
    $0 --github-token ghp_xxxxxxxxxxxx --repo owner/repo --mode webhook

    # With custom ports
    $0 -t ghp_xxxx -r owner/repo -p 9080 -g 9081

    # Force overwrite and build
    $0 -t ghp_xxxx -r owner/repo -f -b

EOF
    exit 1
}

# Parse command line arguments
GITHUB_TOKEN=""
GITHUB_REPO=""
GITHUB_MODE="webhook"
API_PORT="8080"
GUI_PORT="8081"
ENVIRONMENT="development"
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
        -m|--mode)
            GITHUB_MODE="$2"
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

    # Check if gh command is available
    if ! command -v gh &> /dev/null; then
        print_warning "GitHub CLI (gh) is not installed"
        print_info "For webhook mode, you need GitHub CLI to forward webhooks"
        print_info "Install it from: https://cli.github.com/"
        echo ""
        read -p "Continue anyway? [y/N]: " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    else
        print_success "GitHub CLI (gh) is installed"
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

    # GitHub Mode
    echo ""
    echo "GitHub Integration Mode:"
    echo "  1) webhook (recommended) - Uses gh webhook forward"
    echo "  2) polling - Polls GitHub API periodically"
    read -p "Select mode [1]: " MODE_CHOICE
    MODE_CHOICE=${MODE_CHOICE:-1}
    if [ "$MODE_CHOICE" = "2" ]; then
        GITHUB_MODE="polling"
    else
        GITHUB_MODE="webhook"
    fi

    # GitHub Repository (required for webhook mode)
    if [ "$GITHUB_MODE" = "webhook" ]; then
        echo ""
        while [ -z "$GITHUB_REPO" ]; do
            read -p "Enter your GitHub repository (OWNER/REPO): " GITHUB_REPO
            if [ -z "$GITHUB_REPO" ]; then
                print_warning "GitHub repository is required for webhook mode!"
            elif [[ ! "$GITHUB_REPO" =~ ^[^/]+/[^/]+$ ]]; then
                print_warning "Invalid repository format. Use OWNER/REPO (e.g., octocat/hello-world)"
                GITHUB_REPO=""
            fi
        done
    fi

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

    if [[ ! "$GITHUB_MODE" =~ ^(polling|webhook)$ ]]; then
        print_error "Invalid mode: $GITHUB_MODE. Must be 'polling' or 'webhook'"
        usage
    fi

    if [ "$GITHUB_MODE" = "webhook" ] && [ -z "$GITHUB_REPO" ]; then
        print_error "GitHub repository is required for webhook mode. Use -r or --repo"
        usage
    fi

    if [ ! -z "$GITHUB_REPO" ] && [[ ! "$GITHUB_REPO" =~ ^[^/]+/[^/]+$ ]]; then
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
IMQ_GITHUB_MODE=${GITHUB_MODE}
IMQ_POLLING_INTERVAL=60

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
    echo "  GitHub Mode:     ${GITHUB_MODE}"
    if [ ! -z "$GITHUB_REPO" ]; then
        echo "  GitHub Repo:     ${GITHUB_REPO}"
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
        echo "     ${GREEN}cd imq-core && swift build && cd ..${NC}"
        echo "     ${GREEN}cd imq-gui && swift build && cd ..${NC}"
        echo ""
    fi

    echo "  1. Start all services:"
    echo "     ${GREEN}./run.sh${NC}"
    if [ "$GITHUB_MODE" = "webhook" ] && [ ! -z "$GITHUB_REPO" ]; then
        echo "     (This will automatically start webhook forwarding for ${GITHUB_REPO})"
    fi
    echo ""
    echo "  2. Or run as daemon:"
    echo "     ${GREEN}./svc.sh start${NC}"
    echo ""
    echo "  3. Access the GUI:"
    echo "     ${GREEN}http://localhost:${GUI_PORT}${NC}"
    echo ""

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

# Run main function
main
