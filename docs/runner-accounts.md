# Signing in to Runners (design)

Logan, 7 Nov 2026: "our model should be you log in, connecting to the visor
runner (Visor.app) with its URL username and password with pluggable auth so
we could replace that in the fork, and then all of the servers it proxies /
reverse proxies for show up. In settings you could add and remove accounts
multiple accounts for servers but these aren't visor servers they are visor
runners which proxy for multiple visor servers." Native sessions over
localhost stay.

This is the enterprise fork's model brought home. There, each Visor server
runs in a sandbox that proxies its MCP requests, a backend reverse-proxies
clients to it and lists it, and a client signs in once (Okta) and sees every
server, with no way to remove one but signing out. Here the Runner is the
backend, and a client may hold several Runners.

## Decided (Logan, 7 Nov)

- **Visor.app is the Runner.** The Mac's Visor server and each container's
  are its child processes, their binaries in the notarized bundle. Settings
  says which it runs: the Mac's server, container servers, or both.
- **A Runner is reached by signing in alone**, never by a connection code:
  its URL, a username and a password, the sign-in pluggable so the fork puts
  Okta in its place.
- **One user per Runner** for now. Running sessions for several users
  through one Runner (as a service) may come later, and nothing here rules
  it out.
- **For one version only**, a server under a Runner can still be reached
  directly by its connection code, as today, so clients can move over. The
  version after it removes that: a Runner's servers are reached through the
  Runner alone.
- **Messages between servers go through the clients**, those of one Runner
  as any others: one path for all.
- **Reachable over HTTPS on the tailnet** (and the internet in the fork),
  not only where a port happens to be open: today the mini's co-tenant is
  reachable only on the tailnet, through two socat forwarders.

## Today

- A client holds **computers**, one per Visor server (`AgentServerRecord`):
  each added by its connection code (address, password, id), signed in to
  by its own authenticator (`password` or `none`; a fork registers more,
  `AgentServerAuthenticator`), and removed one at a time.
- The Runner fronts a container server at a port of its own (`front set`),
  the bytes passed through; the server still checks its own password.
- A server serves HTTPS only with a certificate it is given
  (`tlsIdentityPath`), and the client pins nothing.
- A fork can give the whole app one **account** (`VisorAccount`, set at
  launch): signed in, its servers are listed and added, marked as the
  account's (`fromAccount`), and signed in to by it; signed out, they go.
  That is the shape below, for one fork-made account.

## The model

- **An account is a Runner**: its URL, and a sign-in to it. Settings ›
  Accounts adds and removes accounts, any number.
- **Signed in, the Runner's servers appear**: the Mac's own server and each
  container server it runs, each a computer in the sidebar under the
  account. A server is not removed on its own, only with its account
  (removing it, or signing out). What a Runner stops running goes from the
  list; what it starts appears.
- **A server is reached only through its Runner**, which checks the
  client's session and passes the request on with a token of its own for
  that server. Servers no longer hold passwords for clients, and listen
  where only the Runner reaches them: the Mac's on loopback, a container's
  on Visor's container network.
- **Visor.app on the Mac** signs in to its own Runner at loopback, as any
  client does, so the Mac's window is one more client of the same model
  (it is given the Runner's user without asking for the password: it is
  the Runner's own process).

## Reaching a Runner: HTTPS everywhere, no SSH needed

One port, HTTPS on every path. What makes its certificate trusted differs
by path, and none of them needs SSH:

- **The tailnet:** a certificate from Tailscale for the Mac's MagicDNS name
  (`<mac>.<tailnet>.ts.net`, a real Let's Encrypt certificate, through the
  local Tailscale's LocalAPI, as `tailscale cert` gets it), renewed by the
  Runner. Publicly trusted, so the client checks it as any website's. The
  account's URL is `https://<mac>.<tailnet>.ts.net:<port>`. This is the
  default where Tailscale is on, with HTTPS certificates enabled for the
  tailnet.
- **The internet (the fork):** the company's front and its certificate, as
  now.
- **The LAN:** no public name, so the Runner makes its own certificate (a
  key in its secrets) and the client pins it: the first sign-in shows the
  certificate's fingerprint, the Runner's Settings shows the same, and the
  person confirms they match (trust on first use); a changed certificate is
  refused until confirmed again.
- **Loopback** (Visor.app on its own Mac): the same pinned certificate, or
  plain HTTP, which never leaves the Mac.

SSH stays an option for a Mac with no port open to the client (today's SSH
path), not a need.

## The Runner's side

| Request | What it does |
|---|---|
| `POST /runner/v1/sign-in` | The sign-in's proof (default: `{"username","password"}`) for a session token, its expiry and the account's name. |
| `POST /runner/v1/sign-out` | Ends the session. |
| `GET /runner/v1/servers` | The servers this session may reach: `id`, `name`, `kind` (`mac`, `container`), `state`, `version`. Answered again when it changes (an `ETag`; a live channel later). |
| `/runner/v1/servers/<id>/…` | That server's whole API, HTTP and its WebSocket, reverse-proxied: the client's session checked, the request passed on with the server's own token in place of it. |

- **Pluggable on the Runner too** (`RunnerAuth`): the default keeps the
  Runner's one user and its password hash in the Runner's secrets, set in
  Settings; a fork's checks its identity provider's token instead (an OIDC
  ID token from Okta, verified against the issuer's keys). Sessions are the
  Runner's own, either way.
- **A token per server**: the Runner gives each server it runs a token (as
  `visor-server password` sets one now, but held by the Runner alone) and
  adds it to what it passes on. A server's own `hello` and REST side are as
  they are.
- **It keeps its servers up**: it asks after each one it runs and starts it
  again when it stops answering (visor#261's `ServerWatch`, for every
  server rather than a front's).

## The client's side

- **`RunnerAccount`** (generalizing `VisorAccount`, which a fork can still
  set as the one account): an account's URL, pinned fingerprint (on the
  LAN), sign-in kind, name and session. Kept in the keychain as records are
  now.
- **`RunnerSignIn`**, registered as authenticators are: `password` (a form
  of URL, username and password) shipped; a fork's (`okta`: a web sign-in)
  in its build. A fork can make its kind the only one offered.
- **Each server is a record of the account's** (`fromAccount`, the account's
  id), its address the Runner's `…/servers/<id>` path. The record is not
  removable; Forget is on the account.
- **The sidebar** groups an account's servers under its name; Settings ›
  Accounts lists accounts with Sign Out and Remove.
- **The relay** is unchanged: the client reports every server it is
  connected to and carries messages between them.

## The version between (one version)

- A Runner's servers answer both ways: through the Runner by sign-in, and
  directly by their connection codes as today.
- A client that holds a code-added computer which is also an account's
  server shows it once, as the account's, and offers to forget the
  code-added record.
- The release notes say the next version removes the direct way.

## The version after

- The servers listen only where the Runner reaches them, and take only its
  token. Connection codes go from the Runner's menu and Settings.
- The Runner's port per server (`front set`) and the mini's socat
  forwarders go.
- A server run without a Runner (the Linux `visor-server` on its own,
  Windows) keeps its password and code, as now.

## Steps

1. This design.
2. The Runner's sign-in, its user and sessions, and `GET /runner/v1/servers`,
   with tests; nothing proxied yet.
3. HTTPS: the tailnet certificate, the LAN's own certificate and its
   fingerprint.
4. The reverse proxy by path, HTTP and WebSocket, with the per-server
   token; the Mac's server and a container's behind it, and the watch over
   them.
5. The client's accounts: Settings › Accounts, the sidebar's grouping, the
   records of an account's servers, trust on first use; the fork's
   `VisorAccount` as one such account. This ships as the version between.
6. The version after: the direct way removed.
