# agent_protocol end to end, 12 Nov 2026

The proof of visor#362's end-to-end test in a leased macOS VM (Shireworks lease 543ac6bd, macOS 27.0.1). One native agent run by Visor.app's native runner and one container agent run by Shireworks' runner, both answering through the Visor client. The harness was echo, with no model.

- `1-native-agent.png`: the native agent's exchange.
- `2-container-agent.png`: the container agent's exchange, with both sessions listed.
- `3-container-agent-stopped.png`: the container agent stopped from the client.
- `4-inspector-stale.png`: the inspector still showing the Container agent with the Native agent selected (visor#363).
- `visor-server.log`: Visor's server, from the VM's unified log (the VM's clock, UTC−5).
- `shireworks-runner.log`: Shireworks' runner and the container agent's own log, as Shireworks sent them.

Each screenshot is cropped to Visor's window. This branch holds only the proof and is never merged.
