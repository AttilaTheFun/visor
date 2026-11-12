# agent_protocol end to end

One command, from your own terminal on a Mac with `sw`, `gh` and python3:

```sh
tools/e2e/agent_protocol_e2e.sh            # asks for a Claude token (from `claude setup-token`), not echoed
tools/e2e/agent_protocol_e2e.sh --dry-run  # the echo harness and a dummy token: no model
```

It tests the flow docs/runners.md describes, as the night of 12 Nov 2026 tested it by hand (visor#362 and #365):

1. **The VM.** It leases a macOS VM (`xcode_27_2`) and sets it up (`vm_setup.sh`):
   - Visor.app, from the latest unexpired `apps-mac` artifact of visor's CI on main. Dispatch `run: verify` on main if there is none.
   - MultiPass, built there from its source, serving the relay on 7470 with the dial-in `visor.multipass.internal:7434`.
   - Claude Code, unless it's a dry run.
   - Visor's agent_protocol driver and dispatcher on 7434. Containers are given `http://visor.multipass.internal:7434`.
2. **The native agent.** A job for a native runner is claimed by Visor's own runner. It answers "Reply with exactly: native ok" and a second message (`vm_agents.py`, over Visor's socket file).
3. **The container half** comes from Shireworks' `tools/e2e/container_half.sh`, fetched from GitHub. It puts Shireworks.app and its runner in the VM, leases the Linux container, and sets up `sw relay` and the container agent's environment.
4. **The container agent.** A job for a container runner is claimed by Shireworks' runner. Its agent-wrapper runs with no network but multipass-client's relay socket and answers the same way.
5. **The proof.** Screenshots of Visor's window, the native and container agents' replies (`native.json`, `container.json`), and Visor's and MultiPass's logs go to the proof folder. Both agents are ended, and it checks that the dispatcher logged both as completed and that MultiPass logged the container's dial-in.
6. **The end.** The container half's cleanup runs, the VM is released, and the temporary folder is removed, however the script ends.

**The token:**
- It is read without echo and goes only into the two agents' environments, over ssh's standard input.
- In the VM, `launchctl setenv` puts it in the desktop session's environment, which Visor.app and its agents inherit. The container half has it the same way.
- It is never written to a file, a log or an image. It is gone when the VM and the container are.

Visor's own password in the VM is made by the script, given to Visor.app as `VISOR_SETUP_PASSWORD`, and never shown.
