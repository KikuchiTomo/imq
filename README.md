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
- **Webhook Proxy**: Reverse proxy service to forward GitHub webhooks to your local server (e.g., ngrok, smee.io, Cloudflare Tunnel)

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

This creates a `.env` file with your settings.

### 3. Set Up Webhook Proxy

IMQ requires a reverse proxy to forward GitHub webhooks to your local server. Set up your preferred reverse proxy service and configure it to forward requests to `http://localhost:8080/webhook/github`.

Update your `.env` file with the proxy URL:

```bash
IMQ_WEBHOOK_PROXY_URL=https://your-proxy-url.com
```

### 4. Configure GitHub Webhook

Go to your repository settings on GitHub:

1. Navigate to `https://github.com/OWNER/REPO/settings/hooks`
2. Click "Add webhook"
3. Set **Payload URL**: Your webhook proxy URL
4. Set **Content type**: `application/json`
5. Set **Secret**: Copy from `IMQ_WEBHOOK_SECRET` in your `.env` file
6. Select events: "Send me everything" or specific events (pull_request, pull_request_review, check_suite, check_run, status)
7. Click "Add webhook"

## Usage

### Start IMQ

**Foreground mode:**
```bash
./run.sh
```

**Daemon mode:**
```bash
./svc.sh start    # Start
./svc.sh status   # Check status
./svc.sh logs     # View logs
./svc.sh stop     # Stop
```

### Access the Web GUI

Open your browser and navigate to `http://localhost:8081`

### Using the Merge Queue

1. **Add PR to Queue**: Apply the trigger label (default: `A-merge`) to a pull request
2. **Automatic Processing**: IMQ will detect the label, add the PR to queue, execute configured checks, update the PR branch, and merge when checks pass
3. **Remove from Queue**: Remove the trigger label or close the PR

### Configure Checks

Access the configuration page in the web GUI to set up checks:

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

## Configuration

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

## License

MIT License - See [LICENSE](LICENSE) file for details.

## Disclaimer

This software is provided for automating GitHub merge queue workflows. Users are responsible for:

- **Security**: Properly securing webhook secrets and GitHub tokens
- **GitHub API Usage**: Complying with GitHub's API rate limits and terms of service
- **Data Loss**: Maintaining backups of important data; the authors are not liable for any data loss
- **Merge Operations**: Reviewing and testing merge operations; automated merging may have unintended consequences

**Use at your own risk.** This software is designed for development and testing environments. For production use, thoroughly test in a controlled environment first.
