# Visor Client on the Mac

Visor Client (applications/visor_macos, `com.LoganShire.VisorClient.macOS`)
is the iPhone's client built for the Mac, released beside Visor.app as its
own asset, `Visor-Client-<version>-macos.zip` (Logan, 21 Nov 2026). It's a
client alone, for a Mac that runs no server and no sessions: it reaches
your computers, and keeps nothing outside its sandbox's container.

## The sandbox

Its entitlements (applications/visor_macos, `app.entitlements` and
`app.ci.entitlements`; tests/visor_macos_tests holds them to this list):

- `com.apple.security.app-sandbox`;
- `com.apple.security.network.client`: its computers, over HTTP, HTTPS and
  WebSockets, out alone;
- `com.apple.security.device.audio-input`: dictation;
- `com.apple.security.files.user-selected.read-only`: attachments, and a
  session archive to import, as the person picks or drops them;
- in the build CI publishes, which the Developer ID profile signs:
  `com.apple.developer.aps-environment` (push) and its own keychain access
  group, `<team>.com.LoganShire.VisorClient.macOS`, with the application
  identifier beside it.

What that leaves out of the client, on this app alone:

- **SSH.** The tunnel listens on 127.0.0.1, which the sandbox refuses an
  app without `com.apple.security.network.server`: its computers are
  reached over HTTP and HTTPS (a LAN address, a VPN's, a front of your own).
  A connection code's SSH path is passed by.
- **Save… for an exported session.** A save panel needs
  `com.apple.security.files.user-selected.read-write`: the archive is
  shared instead (Share…).
- **Anything of a server's**: no socket file, launchd job, `~/.visor`,
  `~/.ssh`, `security` or `launchctl`. The client's code has none; Visor.app's
  server is in applications/visor_mac, which this app doesn't link.

Everything it writes is in `~/Library/Containers/com.LoganShire.VisorClient.macOS`:
its defaults, the message cache (Application Support), URLSession's caches
and its windows' saved state. Its secrets (its computers, their passwords)
are in the data-protection keychain under its own group, in the build CI
publishes; a build signed ad hoc, which has no group, keeps them in the
login keychain.

## Forget Everything

Settings › Forget Everything… (Visor Client alone) forgets each computer,
deletes every keychain item under the app's service (its group's and the
login keychain's), resets its defaults, deletes its folders in its
container's Library, and quits. The sessions stay on the computers.

## Uninstalling

1. In Visor Client, Settings › Forget Everything… (it quits).
2. Move Visor Client.app to the Trash.
3. Remove its container, and macOS's privacy answers for it
   (notifications, microphone, speech recognition, local network):

   ```sh
   rm -rf ~/Library/Containers/com.LoganShire.VisorClient.macOS
   tccutil reset All com.LoganShire.VisorClient.macOS
   ```

Its push registration, Launch Services entry and notification settings go
when the app is deleted.

## Signing

CI signs it as Visor.app (tools/ci/sign_builds.sh: Developer ID, notarized
and stapled, no disk image), with a Developer ID provisioning profile for
`com.LoganShire.VisorClient.macOS` in `APPLE_PROFILES`. The profile must
grant:

- `com.apple.application-identifier`: `<team>.com.LoganShire.VisorClient.macOS`
  (an explicit App ID, not a wildcard);
- `com.apple.developer.team-identifier`: `<team>`;
- `keychain-access-groups`: `<team>.*` (a Developer ID profile's own);
- `com.apple.developer.aps-environment`: `production` (the App ID's Push
  Notifications capability).

The sandbox's, the network's, the microphone's and the files' entitlements
are no profile's to grant.
