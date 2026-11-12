# The rerun through MultiPass, 12 Nov 2026

The same end-to-end test in a fresh leased macOS VM (cbd52f7e), with MultiPass in place of the SSH tunnel. The container agent's agent-wrapper ran in a network namespace of its own, with no network but multipass-client's relay socket. It reached Visor's driver and dispatcher as `visor.multipass.internal:7434` through Shireworks' relay and MultiPass's dial-in (multipass#15), with Visor giving container runners that address (visor#365). Echo harness, no model.

- `1-native-agent.png`: the native agent's exchange.
- `2-container-agent-through-multipass.png`: the container agent's exchange through MultiPass, with both sessions listed.
- `visor-server.log`: Visor's server (the VM's clock, UTC−5).
- `multipass-agent.log`: MultiPass's relay listener, with each dial-in.
- `shireworks-runner.log`: Shireworks' runner, the container agent's own log, and how the container was set up.
