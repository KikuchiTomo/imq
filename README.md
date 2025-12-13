# IMQ - Immediate Merge Queue For GitHub

A local GitHub merge queue system that helps you manage and test pull requests before merging.

## Features

- **Queue Management**: Automatically queue and process pull requests
- **GitHub Integration**: Works with GitHub API and webhooks
- **Web GUI**: User-friendly web interface for monitoring and management
- **Real-time Updates**: WebSocket support for live status updates
- **Flexible Deployment**: Run in foreground or as a daemon service

## Prerequisites

- **Swift 5.9+**: [Install Swift](https://swift.org/download/)
- **GitHub CLI (gh)**: [Install GitHub CLI](https://cli.github.com/) (required for webhook mode)
- **GitHub Personal Access Token**: [Create a token](https://github.com/settings/tokens) with `repo` and `workflow` scopes

## Quick Start

### 1. Configure the Environment

Run the configuration script to set up your environment:

```bash
# Interactive mode (recommended for first-time setup)
./configure.sh

# Or use command-line arguments
./configure.sh --github-token ghp_xxxxxxxxxxxx --mode webhook
```

The configuration script will:
- Create a `.env` file with your settings
- Set up necessary directories
- Optionally build the projects
- Validate prerequisites

### 2. Start All Services

```bash
# Run in foreground (Ctrl+C to stop)
./run.sh
```

This will start:
- **imq-core**: Backend API server (default: `http://localhost:8080`)
- **imq-gui**: Web GUI (default: `http://localhost:8081`)
- **gh webhook forward**: Automatic webhook forwarding (if repository is configured)

### 3. Access the GUI

Open your browser and navigate to:

```
http://localhost:8081
```

## Running as a Daemon

Use the service management script to run IMQ as a background daemon:

```bash
# Start daemon
./svc.sh start

# Check status
./svc.sh status

# View logs
./svc.sh logs

# Follow logs in real-time
./svc.sh logs -f

# Restart all services
./svc.sh restart

# Stop daemon
./svc.sh stop
```

## Configuration

All configuration is managed through environment variables in the `.env` file:

### GitHub Settings

```bash
# Required: Your GitHub Personal Access Token
IMQ_GITHUB_TOKEN=ghp_xxxxxxxxxxxx

# Required for webhook mode: GitHub Repository (OWNER/REPO)
IMQ_GITHUB_REPO=octocat/hello-world

# Optional: GitHub API URL (for GitHub Enterprise)
IMQ_GITHUB_API_URL=https://api.github.com

# Optional: Integration mode (webhook or polling)
IMQ_GITHUB_MODE=webhook

# Optional: Polling interval in seconds (for polling mode)
IMQ_POLLING_INTERVAL=60
```

**Note**: When `IMQ_GITHUB_REPO` is set and `IMQ_GITHUB_MODE=webhook`, `run.sh` will automatically start `gh webhook forward` for the specified repository. No need to run it manually!

### Server Settings

```bash
# API Server (imq-core)
IMQ_API_HOST=0.0.0.0
IMQ_API_PORT=8080

# GUI Server (imq-gui)
IMQ_GUI_HOST=0.0.0.0
IMQ_GUI_PORT=8081
IMQ_GUI_API_URL=http://localhost:8080
IMQ_GUI_WS_URL=ws://localhost:8080/ws/events
```

### Database Settings

```bash
# SQLite database path (default: ~/.imq/imq.db)
IMQ_DATABASE_PATH=/path/to/imq.db

# Connection pool size
IMQ_DATABASE_POOL_SIZE=5
```

### Logging Settings

```bash
# Log level: trace, debug, info, warning, error, critical
IMQ_LOG_LEVEL=info

# Log format: json, pretty
IMQ_LOG_FORMAT=pretty
```

### Runtime Settings

```bash
# Environment: development, staging, production
IMQ_ENVIRONMENT=development

# Enable debug mode
IMQ_DEBUG=false
```

## Webhook Setup

IMQ supports two methods for receiving GitHub webhooks:

### 1. Local Development (Testing Only)

For local testing, IMQ can automatically use `gh webhook forward` to receive webhooks. This is enabled by default when you configure a repository in `.env`:

```bash
IMQ_GITHUB_REPO=octocat/hello-world
IMQ_GITHUB_MODE=webhook
```

When you run `./run.sh`, the webhook forwarder will start automatically. This requires:
- GitHub CLI (`gh`) installed and authenticated
- `gh-webhook` extension (auto-installed if needed)
- Admin access to the repository

**Note**: `gh webhook forward` is designed for testing only and not recommended for production use.

### 2. External Reverse Proxy (Recommended for Production)

For production or public deployments, use an external reverse proxy service. IMQ supports any proxy that can forward HTTPS requests to your local server.

#### Setting Up External Proxy

In your `.env` file:

```bash
# Set external proxy URL
IMQ_WEBHOOK_PROXY_URL=https://your-proxy-url.com

# Generate and set webhook secret for security
IMQ_WEBHOOK_SECRET=$(openssl rand -hex 32)

# Set trigger label (optional, default: A-merge)
IMQ_TRIGGER_LABEL=A-merge
```

When `IMQ_WEBHOOK_PROXY_URL` is set, `run.sh` will display instructions for configuring GitHub webhooks instead of starting `gh webhook forward`.

#### Option A: Using ngrok

[ngrok](https://ngrok.com/) provides secure tunneling to localhost.

1. Install ngrok:
   ```bash
   # macOS
   brew install ngrok

   # Or download from https://ngrok.com/download
   ```

2. Sign up and get your auth token from https://dashboard.ngrok.com/get-started/your-authtoken

3. Configure ngrok:
   ```bash
   ngrok config add-authtoken YOUR_AUTH_TOKEN
   ```

4. Start ngrok tunnel:
   ```bash
   ngrok http 8080
   ```

5. Copy the forwarding URL (e.g., `https://abc123.ngrok-free.app`) and add to `.env`:
   ```bash
   IMQ_WEBHOOK_PROXY_URL=https://abc123.ngrok-free.app
   ```

6. Start IMQ:
   ```bash
   ./run.sh
   ```

7. Configure GitHub webhook as shown in the terminal output:
   - Go to `https://github.com/OWNER/REPO/settings/hooks`
   - Add webhook with payload URL: `https://abc123.ngrok-free.app/webhook/github`
   - Content type: `application/json`
   - Secret: (copy from `IMQ_WEBHOOK_SECRET` in `.env`)
   - Events: Select "Send me everything" or specific events

**ngrok Tips**:
- Free tier: URLs change on restart, domain randomization
- Paid tier: Static domains, no randomization, better for long-term use
- Use `ngrok http 8080 --domain=your-static-domain.ngrok-free.app` with static domain

#### Option B: Using smee.io

[smee.io](https://smee.io/) is a free webhook payload delivery service.

1. Visit https://smee.io/ and click "Start a new channel"

2. Copy the webhook proxy URL (e.g., `https://smee.io/abc123`)

3. Install smee-client:
   ```bash
   npm install -g smee-client
   ```

4. Add proxy URL to `.env`:
   ```bash
   IMQ_WEBHOOK_PROXY_URL=https://smee.io/abc123
   ```

5. Start smee client to forward webhooks to IMQ:
   ```bash
   smee --url https://smee.io/abc123 --target http://localhost:8080/webhook/github
   ```

6. In a separate terminal, start IMQ:
   ```bash
   ./run.sh
   ```

7. Configure GitHub webhook:
   - Payload URL: `https://smee.io/abc123/webhook/github`
   - Content type: `application/json`
   - Events: Select "Send me everything"

**Note**: smee.io is for testing only. Channels are public and expire after inactivity.

#### Option C: Using Cloudflare Tunnel

[Cloudflare Tunnel](https://www.cloudflare.com/products/tunnel/) provides secure, production-grade tunneling.

1. Install cloudflared:
   ```bash
   # macOS
   brew install cloudflared

   # Or download from https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/install-and-setup/installation/
   ```

2. Authenticate:
   ```bash
   cloudflared tunnel login
   ```

3. Create a tunnel:
   ```bash
   cloudflared tunnel create imq-webhook
   ```

4. Create config file `~/.cloudflared/config.yml`:
   ```yaml
   tunnel: imq-webhook
   credentials-file: /path/to/credentials.json

   ingress:
     - hostname: imq.your-domain.com
       service: http://localhost:8080
     - service: http_status:404
   ```

5. Add DNS record:
   ```bash
   cloudflared tunnel route dns imq-webhook imq.your-domain.com
   ```

6. Add proxy URL to `.env`:
   ```bash
   IMQ_WEBHOOK_PROXY_URL=https://imq.your-domain.com
   ```

7. Start tunnel:
   ```bash
   cloudflared tunnel run imq-webhook
   ```

8. In a separate terminal, start IMQ:
   ```bash
   ./run.sh
   ```

9. Configure GitHub webhook:
   - Payload URL: `https://imq.your-domain.com/webhook/github`
   - Content type: `application/json`
   - Secret: (copy from `IMQ_WEBHOOK_SECRET` in `.env`)
   - Events: Select "Send me everything"

**Cloudflare Tunnel Benefits**:
- Production-grade reliability
- DDoS protection
- Custom domain support
- No exposed ports
- Free for personal use

### Webhook Security

When using external proxies, always:

1. **Set a webhook secret**:
   ```bash
   IMQ_WEBHOOK_SECRET=$(openssl rand -hex 32)
   ```

2. **Use the secret in GitHub webhook configuration**

3. **Use HTTPS** for all webhook URLs (all proxy services provide HTTPS)

4. **Limit webhook events** to only what you need (or use "Send me everything" for simplicity)

## Project Structure

```
imq/
├── configure.sh          # Configuration script
├── run.sh               # Start all services
├── svc.sh               # Daemon management script
├── .env.example         # Environment template
├── .env                 # Your configuration (git-ignored)
├── imq-core/            # Backend service
│   ├── Sources/
│   │   ├── IMQCore/     # Core library
│   │   ├── IMQCLI/      # CLI tool
│   │   └── IMQServer/   # API server
│   └── Package.swift
├── imq-gui/             # Web GUI
│   ├── Sources/
│   │   ├── IMQGUILib/   # GUI library
│   │   └── Run/         # Server executable
│   ├── Resources/       # Web assets
│   └── Package.swift
└── logs/                # Log files (git-ignored)
```

## Scripts Reference

### configure.sh

Initial setup and configuration.

```bash
./configure.sh [OPTIONS]

OPTIONS:
  -t, --github-token TOKEN              GitHub Personal Access Token
  -r, --repo OWNER/REPO                 GitHub repository (e.g., octocat/hello-world)
  -m, --mode MODE                       Integration mode (polling|webhook)
  -p, --api-port PORT                   API server port (default: 8080)
  -g, --gui-port PORT                   GUI server port (default: 8081)
  -e, --environment ENV                 Environment (development|staging|production)
  --webhook-proxy-url URL               External webhook proxy URL (e.g., https://abc.ngrok.io)
  --webhook-secret SECRET               Webhook secret for security (auto-generated if not provided)
  --trigger-label LABEL                 Trigger label for merge queue (default: A-merge)
  -b, --build                           Build projects after configuration
  -f, --force                           Force overwrite existing .env
  -i, --interactive                     Interactive mode
  -h, --help                            Show help

EXAMPLES:
  # Interactive mode (recommended)
  ./configure.sh

  # Basic webhook mode
  ./configure.sh -t ghp_xxxx -r owner/repo -m webhook

  # With external webhook proxy (ngrok, smee.io, etc.)
  ./configure.sh -t ghp_xxxx -r owner/repo --webhook-proxy-url https://abc.ngrok.io

  # With custom webhook secret
  ./configure.sh -t ghp_xxxx -r owner/repo --webhook-secret $(openssl rand -hex 32)

  # Polling mode
  ./configure.sh -t ghp_xxxx -r owner/repo -m polling
```

**Note**: When `--webhook-proxy-url` is set, IMQ will not use `gh webhook forward` and will instead expect webhooks from the external proxy.

### run.sh

Start all services in foreground.

```bash
./run.sh

# Services started:
# - imq-core (API server)
# - imq-gui (Web GUI)
# - gh webhook forward (automatically if IMQ_GITHUB_REPO is set)

# Press Ctrl+C to stop all services
```

**Note**: If `IMQ_GITHUB_REPO` is configured in `.env`, the webhook forwarder will start automatically. Otherwise, you'll see instructions on how to set it up.

### svc.sh

Daemon service management.

```bash
./svc.sh {start|stop|restart|status|logs}

COMMANDS:
  start      Start IMQ daemon
  stop       Stop IMQ daemon
  restart    Restart IMQ daemon
  status     Show service status
  logs       Show last 50 lines of logs
  logs -f    Follow logs in real-time
```

## Development

### Building Manually

```bash
# Build imq-core
cd imq-core
swift build

# Build imq-gui
cd imq-gui
swift build
```

### Running Individual Services

```bash
# Run imq-core server
cd imq-core
swift run imq-server

# Run imq-gui
cd imq-gui
swift run imq-gui

# Run imq CLI
cd imq-core
swift run imq --help
```

### Running Tests

```bash
# Run imq-core tests
cd imq-core
swift test

# Run imq-gui tests
cd imq-gui
swift test
```

## Troubleshooting

### Services won't start

1. Check if ports are already in use:
   ```bash
   lsof -i :8080  # Check API port
   lsof -i :8081  # Check GUI port
   ```

2. Check logs:
   ```bash
   ./svc.sh logs
   ```

3. Verify configuration:
   ```bash
   cat .env
   ```

### GitHub webhook forwarding fails

1. Ensure GitHub CLI is installed:
   ```bash
   gh --version
   ```

2. Authenticate with GitHub:
   ```bash
   gh auth login
   ```

3. Verify repository access:
   ```bash
   gh repo view OWNER/REPO
   ```

### Database issues

1. Check database file permissions:
   ```bash
   ls -la ~/.imq/imq.db
   ```

2. Reset database (WARNING: deletes all data):
   ```bash
   rm -f ~/.imq/imq.db
   ```

## License

See [LICENSE](LICENSE) file for details.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.
