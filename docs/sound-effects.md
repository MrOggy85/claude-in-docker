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
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.user.claude-sound-server.plist
   launchctl kickstart -k gui/$(id -u)/com.user.claude-sound-server
   ```
   The plist assumes the repo lives at `~/code/claude-in-docker`; edit the path in
   `ProgramArguments` if yours is elsewhere. To reload after editing the plist,
   `bootout` first: `launchctl bootout gui/$(id -u)/com.user.claude-sound-server`.
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

`SOUND_PORT` is a special case of the general host-egress allowlist: the firewall
opens `SOUND_PORT` outbound to the host by default so sound works with zero extra
config. To reach *other* host ports from the container (a dev server, a database,
etc.), use `CLAUDE_HOST_OUTBOUND_PORTS` — see
[Host-Outbound Ports](host-outbound-ports.md).
