# Sound Effects

Claude Code can trigger sound effects on the host machine when events fire (task complete, notification, etc.).

## Why a host-side server?

Docker containers have no access to audio hardware. The workaround is a small HTTP server running on the host that calls `afplay` when the container makes a request to it. The container reaches the host via `host.docker.internal`.

## Setup

1. Drop your `.mp3` or `.wav` files into `sound-effects/sounds/` (gitignored).
2. Start the sound server on your host:
   ```bash
   ./sound-effects/host-sound-server.sh
   ```
   Or install it as a launchd service so it starts automatically:
   ```bash
   cp sound-effects/com.user.claude-sound-server.plist ~/Library/LaunchAgents/
   launchctl load ~/Library/LaunchAgents/com.user.claude-sound-server.plist
   ```
3. Add hooks to your `settings.json` that `curl` the server (see example below).

## settings.json example

```json
"hooks": {
  "Stop": [
    {
      "hooks": [
        {
          "type": "command",
          "command": "curl -s --max-time 1 -o /dev/null http://host.docker.internal:4767/play/blip_2.mp3 || true"
        }
      ]
    }
  ],
  "SubagentStop": [
    {
      "hooks": [
        {
          "type": "command",
          "command": "curl -s --max-time 1 -o /dev/null http://host.docker.internal:4767/play/PeasantJobDone.wav || true"
        }
      ]
    }
  ],
  "Notification": [
    {
      "hooks": [
        {
          "type": "command",
          "command": "curl -s --max-time 1 -o /dev/null http://host.docker.internal:4767/play/item-collected.mp3 || true"
        }
      ]
    }
  ]
}
```

The server defaults to port `4767`. Override with the `SOUND_PORT` environment variable.
