#!/bin/bash

# IMQ Service Management Script
# Manage IMQ as a daemon service (start/stop/restart/status)

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_SCRIPT="${SCRIPT_DIR}/run.sh"
PID_FILE="${SCRIPT_DIR}/.imq.pid"
LOG_DIR="${SCRIPT_DIR}/logs"
LOG_FILE="${LOG_DIR}/imq.log"
DAEMON_PID_FILE="${SCRIPT_DIR}/.imq-daemon.pid"

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

# Check if run.sh exists
check_run_script() {
    if [ ! -f "$RUN_SCRIPT" ]; then
        print_error "run.sh not found at: $RUN_SCRIPT"
        exit 1
    fi

    if [ ! -x "$RUN_SCRIPT" ]; then
        print_error "run.sh is not executable. Run: chmod +x $RUN_SCRIPT"
        exit 1
    fi
}

# Create log directory
create_log_dir() {
    if [ ! -d "$LOG_DIR" ]; then
        mkdir -p "$LOG_DIR"
        print_info "Created log directory: $LOG_DIR"
    fi
}

# Start daemon
start_daemon() {
    print_info "Starting IMQ daemon..."

    # Check if already running
    if is_running; then
        print_warning "IMQ is already running"
        show_status
        exit 0
    fi

    # Create log directory
    create_log_dir

    # Start run.sh in background
    nohup "$RUN_SCRIPT" > "$LOG_FILE" 2>&1 &
    DAEMON_PID=$!

    # Save daemon PID
    echo "$DAEMON_PID" > "$DAEMON_PID_FILE"

    # Wait a bit and check if it's still running
    sleep 3

    if is_running; then
        print_success "IMQ daemon started successfully (PID: $DAEMON_PID)"
        print_info "Logs: $LOG_FILE"
        echo ""
        show_status
    else
        print_error "Failed to start IMQ daemon"
        print_info "Check logs at: $LOG_FILE"
        exit 1
    fi
}

# Stop daemon
stop_daemon() {
    print_info "Stopping IMQ daemon..."

    if ! is_running; then
        print_warning "IMQ is not running"
        cleanup_pid_files
        exit 0
    fi

    # Get daemon PID
    if [ -f "$DAEMON_PID_FILE" ]; then
        DAEMON_PID=$(cat "$DAEMON_PID_FILE")

        # Send SIGTERM to daemon (this will trigger cleanup in run.sh)
        if kill -0 "$DAEMON_PID" 2>/dev/null; then
            print_info "Sending SIGTERM to daemon (PID: $DAEMON_PID)..."
            kill "$DAEMON_PID" 2>/dev/null || true

            # Wait for graceful shutdown
            for i in {1..10}; do
                if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
                    break
                fi
                sleep 1
            done

            # Force kill if still running
            if kill -0 "$DAEMON_PID" 2>/dev/null; then
                print_warning "Graceful shutdown failed, forcing..."
                kill -9 "$DAEMON_PID" 2>/dev/null || true
            fi
        fi
    fi

    # Also kill any child processes from PID file
    if [ -f "$PID_FILE" ]; then
        source "$PID_FILE"

        for pid in $WEBHOOK_PID $GUI_PID $CORE_PID; do
            if [ ! -z "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                kill "$pid" 2>/dev/null || true
            fi
        done
    fi

    # Cleanup
    cleanup_pid_files

    print_success "IMQ daemon stopped"
}

# Restart daemon
restart_daemon() {
    print_info "Restarting IMQ daemon..."
    stop_daemon
    sleep 2
    start_daemon
}

# Check if daemon is running
is_running() {
    if [ ! -f "$DAEMON_PID_FILE" ]; then
        return 1
    fi

    DAEMON_PID=$(cat "$DAEMON_PID_FILE")

    if kill -0 "$DAEMON_PID" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Show status
show_status() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  IMQ Service Status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if is_running; then
        DAEMON_PID=$(cat "$DAEMON_PID_FILE")
        print_success "Status: RUNNING"
        echo "  Daemon PID: $DAEMON_PID"

        # Show service PIDs if available
        if [ -f "$PID_FILE" ]; then
            source "$PID_FILE"
            echo ""
            echo "  Service PIDs:"

            if [ ! -z "$CORE_PID" ] && kill -0 "$CORE_PID" 2>/dev/null; then
                echo -e "    ${GREEN}✓${NC} imq-core:  $CORE_PID"
            else
                echo -e "    ${RED}✗${NC} imq-core:  not running"
            fi

            if [ ! -z "$GUI_PID" ] && kill -0 "$GUI_PID" 2>/dev/null; then
                echo -e "    ${GREEN}✓${NC} imq-gui:   $GUI_PID"
            else
                echo -e "    ${RED}✗${NC} imq-gui:   not running"
            fi

            if [ ! -z "$WEBHOOK_PID" ] && kill -0 "$WEBHOOK_PID" 2>/dev/null; then
                echo -e "    ${GREEN}✓${NC} webhook:   $WEBHOOK_PID"
            else
                echo "    - webhook:   not configured"
            fi
        fi

        # Load .env to show URLs
        if [ -f "${SCRIPT_DIR}/.env" ]; then
            set -a
            source "${SCRIPT_DIR}/.env"
            set +a

            echo ""
            echo "  Service URLs:"
            echo "    GUI: http://localhost:${IMQ_GUI_PORT:-8081}"
            echo "    API: http://localhost:${IMQ_API_PORT:-8080}"
        fi

        echo ""
        echo "  Log file: $LOG_FILE"
    else
        print_error "Status: STOPPED"
    fi

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

# Show logs
show_logs() {
    if [ ! -f "$LOG_FILE" ]; then
        print_warning "Log file not found: $LOG_FILE"
        exit 1
    fi

    # Follow logs if -f flag is provided
    if [ "$1" = "-f" ] || [ "$1" = "--follow" ]; then
        print_info "Following logs (Ctrl+C to stop)..."
        tail -f "$LOG_FILE"
    else
        # Show last 50 lines
        print_info "Last 50 lines of log:"
        tail -n 50 "$LOG_FILE"
    fi
}

# Cleanup PID files
cleanup_pid_files() {
    rm -f "$DAEMON_PID_FILE"
    rm -f "$PID_FILE"
}

# Show usage
usage() {
    cat << EOF
Usage: $0 {start|stop|restart|status|logs}

Manage IMQ as a daemon service.

COMMANDS:
    start       Start IMQ daemon
    stop        Stop IMQ daemon
    restart     Restart IMQ daemon
    status      Show service status
    logs        Show last 50 lines of logs
    logs -f     Follow logs in real-time

EXAMPLES:
    $0 start          # Start the daemon
    $0 status         # Check status
    $0 logs -f        # Follow logs
    $0 restart        # Restart all services
    $0 stop           # Stop the daemon

FILES:
    PID File:  $DAEMON_PID_FILE
    Log File:  $LOG_FILE

EOF
    exit 1
}

# Main function
main() {
    # Check run.sh
    check_run_script

    # Parse command
    case "${1:-}" in
        start)
            start_daemon
            ;;
        stop)
            stop_daemon
            ;;
        restart)
            restart_daemon
            ;;
        status)
            show_status
            ;;
        logs)
            show_logs "$2"
            ;;
        *)
            usage
            ;;
    esac
}

# Run main function
main "$@"
