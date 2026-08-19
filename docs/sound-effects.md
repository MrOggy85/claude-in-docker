# Sound Effects

Claude Code can trigger sound effects on the host when events fire (task complete, notification).

Containers have no access to audio hardware, so a small HTTP server runs on the host and calls
`afplay` when the container requests it, reached via `host.docker.internal`.

## Setup

1. Drop `.mp3` or `.wav` files into `sound-effects/sounds/` (gitignored).
2. Start the server:
   ```bash
   ./sound-effects/host-sound-server.sh
   ```
   Or install it as a launchd service so it starts automatically:
   ```bash
   cp sound-effects/com.user.claude-sound-server.plist ~/Library/LaunchAgents/
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.user.claude-sound-server.plist
   launchctl kickstart -k gui/$(id -u)/com.user.claude-sound-server
   ```
   The plist assumes the repo is at `~/code/claude-in-docker`; edit `ProgramArguments` if not. To
   reload after editing, `launchctl bootout gui/$(id -u)/com.user.claude-sound-server` first.
3. Add hooks to your `settings.json` that `curl` the server:

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

The server defaults to port `4767`; override with `SOUND_PORT`. The firewall opens `SOUND_PORT`
outbound to the host by default, so sound works with no extra config. For *other* host ports use
`CLAUDE_HOST_OUTBOUND_PORTS` — see [Host-Outbound Ports](host-outbound-ports.md).

The server binds `0.0.0.0` (required — the container reaches the host over the Docker gateway) and
has **no authentication**: anything that can reach the port can play a file from
`sound-effects/sounds/`. That is the whole capability; see [Known Attack
Vectors](attack-vectors.md#host-bridges-on-host-outbound-ports-accepted-trade-off-opt-in) for how
the three host bridges compare.
