# IMQ - Immediate Merge Queue For GitHub

A lightweight, local GitHub merge queue system that automates pull request testing and merging through label-based triggers and configurable checks.

## Features

- **Automated Queue Management**: Add PRs to the merge queue by applying a trigger label (default: `A-merge`)
- **Configurable Checks**: Run GitHub Actions workflows, status checks, or mergeable validation before merging
- **Real-time Monitoring**: Web-based GUI with live WebSocket updates for queue status
- **Smart Processing**: Automatically updates PR branches and merges when checks pass
- **Flexible Deployment**: Run in foreground or as a background daemon service
- **Secure Webhook Integration**: HMAC-SHA256 signature verification for GitHub webhooks
- **SQLite Database**: Lightweight, zero-configuration persistence with connection pooling

## Prerequisites

- **Swift 5.9+**: [Install Swift](https://swift.org/download/)
- **GitHub Personal Access Token**: [Create a token](https://github.com/settings/tokens) with `repo` and `workflow` scopes
- **Webhook Proxy**: External service to forward GitHub webhooks to your local server (ngrok, smee.io, Cloudflare Tunnel, etc.)

## Installation

### 1. Clone the Repository

```bash
git clone https://github.com/yourusername/imq.git
cd imq
```

### 2. Configure Environment

Run the interactive configuration script:

```bash
./configure.sh
```

Or use command-line arguments:

```bash
./configure.sh \
  --github-token ghp_xxxxxxxxxxxx \
  --repo owner/repository \
  --webhook-proxy-url https://your-proxy-url.com \
  --build
```

This creates a `.env` file with your settings and optionally builds the projects.

### 3. Set Up Webhook Proxy

IMQ requires an external proxy to receive GitHub webhooks. Choose one:

#### Option A: ngrok (Recommended for Testing)

```bash
# Install ngrok
brew install ngrok

# Authenticate
ngrok config add-authtoken YOUR_AUTH_TOKEN

# Start tunnel
ngrok http 8080

# Copy the HTTPS URL (e.g., https://abc123.ngrok-free.app)
# Add to .env: IMQ_WEBHOOK_PROXY_URL=https://abc123.ngrok-free.app
```

#### Option B: smee.io (Quick Testing)

```bash
# Get a channel at https://smee.io
# Install smee-client
npm install -g smee-client

# Start forwarding
smee --url https://smee.io/abc123 --target http://localhost:8080/webhook/github

# Add to .env: IMQ_WEBHOOK_PROXY_URL=https://smee.io/abc123
```

#### Option C: Cloudflare Tunnel (Production)

```bash
# Install cloudflared
brew install cloudflared

# Authenticate
cloudflared tunnel login

# Create tunnel
cloudflared tunnel create imq-webhook

# Configure tunnel (see full instructions in Configuration section below)
# Add to .env: IMQ_WEBHOOK_PROXY_URL=https://imq.your-domain.com
```

### 4. Configure GitHub Webhook

Go to your repository settings on GitHub:

1. Navigate to `https://github.com/OWNER/REPO/settings/hooks`
2. Click "Add webhook"
3. Set **Payload URL**: Your webhook proxy URL (e.g., `https://abc123.ngrok-free.app/`)
4. Set **Content type**: `application/json`
5. Set **Secret**: Copy from `IMQ_WEBHOOK_SECRET` in your `.env` file
6. Select events: Choose "Send me everything" or specific events (pull_request, pull_request_review, check_suite, check_run, status)
7. Click "Add webhook"

## Usage

### Start IMQ

#### Foreground Mode

```bash
./run.sh
```

This starts both the API server (port 8080) and web GUI (port 8081). Press Ctrl+C to stop.

#### Daemon Mode

```bash
# Start as background service
./svc.sh start

# Check status
./svc.sh status

# View logs
./svc.sh logs

# Follow logs in real-time
./svc.sh logs -f

# Restart services
./svc.sh restart

# Stop daemon
./svc.sh stop
```

### Access the Web GUI

Open your browser and navigate to:

```
http://localhost:8081
```

The GUI displays:
- Current queue status
- Pending pull requests
- Processing status in real-time
- Check results

### Using the Merge Queue

1. **Add PR to Queue**: Apply the trigger label (default: `A-merge`) to a pull request
2. **Automatic Processing**: IMQ will:
   - Detect the label via webhook
   - Add the PR to the queue
   - Execute configured checks (if any)
   - Update the PR branch with the latest base branch
   - Merge the PR when checks pass
   - Post status comments on the PR
3. **Remove from Queue**: Remove the trigger label or close the PR

### Configure Checks

Access the configuration page in the web GUI or update via API to set up checks:

```json
{
  "checkConfigurations": [
    {
      "name": "CI Tests",
      "type": "github_actions",
      "workflowName": "ci.yml",
      "timeout": 600
    },
    {
      "name": "Status Checks",
      "type": "github_status"
    },
    {
      "name": "Mergeable",
      "type": "mergeable"
    }
  ]
}
```

**Check Types:**
- `github_actions`: Trigger and wait for a GitHub Actions workflow
- `github_status`: Wait for status checks to pass
- `mergeable`: Verify PR is in mergeable state

## Configuration Reference

All settings are configured via environment variables in the `.env` file.

### Essential Settings

```bash
# GitHub credentials
IMQ_GITHUB_TOKEN=ghp_xxxxxxxxxxxx
IMQ_GITHUB_REPO=owner/repository

# Webhook configuration
IMQ_WEBHOOK_PROXY_URL=https://your-proxy-url.com
IMQ_WEBHOOK_SECRET=your-webhook-secret

# Trigger label
IMQ_TRIGGER_LABEL=A-merge
```

### Server Settings

```bash
# API server
IMQ_API_HOST=0.0.0.0
IMQ_API_PORT=8080

# Web GUI
IMQ_GUI_HOST=0.0.0.0
IMQ_GUI_PORT=8081
IMQ_GUI_API_URL=http://localhost:8080
IMQ_GUI_WS_URL=ws://localhost:8080/ws/events
```

### Database Settings

```bash
# SQLite database path (default: ~/.imq/imq.db)
IMQ_DATABASE_PATH=/path/to/imq.db

# Connection pool size (default: 5)
IMQ_DATABASE_POOL_SIZE=5
```

### Logging Settings

```bash
# Log level: trace, debug, info, warning, error, critical
IMQ_LOG_LEVEL=info

# Log format: json, pretty
IMQ_LOG_FORMAT=pretty
```

### Advanced Webhook Setup

#### Cloudflare Tunnel (Production Setup)

For production deployments, Cloudflare Tunnel provides reliable, secure tunneling:

1. **Install cloudflared**:
   ```bash
   brew install cloudflared
   ```

2. **Authenticate**:
   ```bash
   cloudflared tunnel login
   ```

3. **Create tunnel**:
   ```bash
   cloudflared tunnel create imq-webhook
   ```

4. **Create config** (`~/.cloudflared/config.yml`):
   ```yaml
   tunnel: imq-webhook
   credentials-file: /path/to/credentials.json

   ingress:
     - hostname: imq.your-domain.com
       service: http://localhost:8080
     - service: http_status:404
   ```

5. **Add DNS record**:
   ```bash
   cloudflared tunnel route dns imq-webhook imq.your-domain.com
   ```

6. **Update `.env`**:
   ```bash
   IMQ_WEBHOOK_PROXY_URL=https://imq.your-domain.com
   ```

7. **Start tunnel**:
   ```bash
   cloudflared tunnel run imq-webhook
   ```

#### Webhook Security

Always set a webhook secret for security:

```bash
# Generate a secure secret
IMQ_WEBHOOK_SECRET=$(openssl rand -hex 32)
```

Add this secret to your GitHub webhook configuration. IMQ verifies all incoming webhooks using HMAC-SHA256 signatures.

## Command Reference

### configure.sh

Initial setup and configuration.

```bash
./configure.sh [OPTIONS]

OPTIONS:
  -t, --github-token TOKEN       GitHub Personal Access Token
  -r, --repo OWNER/REPO          GitHub repository
  -p, --api-port PORT            API server port (default: 8080)
  -g, --gui-port PORT            GUI server port (default: 8081)
  --webhook-proxy-url URL        External webhook proxy URL
  --webhook-secret SECRET        Webhook secret (auto-generated if not provided)
  --trigger-label LABEL          Trigger label (default: A-merge)
  -b, --build                    Build projects after configuration
  -f, --force                    Force overwrite existing .env
  -i, --interactive              Interactive mode (default)
  -h, --help                     Show help
```

### run.sh

Start all services in foreground mode.

```bash
./run.sh

# Press Ctrl+C to stop
```

### svc.sh

Manage IMQ as a background daemon.

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

## Troubleshooting

### Services Won't Start

1. **Check if ports are in use**:
   ```bash
   lsof -i :8080  # API port
   lsof -i :8081  # GUI port
   ```

2. **Check logs**:
   ```bash
   ./svc.sh logs
   # or
   tail -f logs/imq-core.log
   tail -f logs/imq-gui.log
   ```

3. **Verify configuration**:
   ```bash
   cat .env
   ```

### Webhooks Not Received

1. **Verify webhook proxy is running** (ngrok, smee, cloudflared)
2. **Check GitHub webhook delivery status** in repository settings
3. **Verify webhook secret** matches between `.env` and GitHub
4. **Check webhook URL** is correctly set in GitHub

### Database Issues

1. **Check file permissions**:
   ```bash
   ls -la ~/.imq/imq.db
   ```

2. **Reset database** (WARNING: deletes all data):
   ```bash
   rm -f ~/.imq/imq.db
   # Restart IMQ to recreate schema
   ./svc.sh restart
   ```

### PRs Not Processing

1. **Verify trigger label** matches configuration (`IMQ_TRIGGER_LABEL`)
2. **Check queue processing** in web GUI
3. **Review logs** for processing errors
4. **Verify GitHub token** has required permissions (`repo`, `workflow`)

## License

MIT License

Copyright (c) 2025 IMQ Contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Disclaimer

This software is provided for automating GitHub merge queue workflows. Users are responsible for:

- **Security**: Properly securing webhook secrets and GitHub tokens
- **GitHub API Usage**: Complying with GitHub's API rate limits and terms of service
- **Data Loss**: Maintaining backups of important data; the authors are not liable for any data loss
- **Merge Operations**: Reviewing and testing merge operations; automated merging may have unintended consequences

**Use at your own risk.** This software is designed for development and testing environments. For production use, thoroughly test in a controlled environment first.

## Support

- **Issues**: Report bugs or request features at [GitHub Issues](https://github.com/yourusername/imq/issues)
- **Documentation**: See this README for complete usage instructions
- **Community**: Contributions and feedback welcome
