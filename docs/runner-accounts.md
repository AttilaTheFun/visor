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

## Today

- A client holds **computers**, one per Visor server (`AgentServerRecord`):
  each added by its connection code (address, password, id), signed in to
  by its own authenticator (`password` or `none`; a fork registers more,
  `AgentServerAuthenticator`), and removed one at a time.
- The Runner fronts a container server at a port of its own (`front set`),
  the bytes passed through; the server still checks its own password.
- A fork can give the whole app one **account** (`VisorAccount`, set at
  launch): signed in, its servers are listed and added, marked as the
  account's (`fromAccount`), and signed in to by it; signed out, they go.
  That is the shape below, for one fork-made account.

## The model

- **An account is a Runner**: its URL, and a sign-in to it. The default
  sign-in is a username and password; a fork registers its own (Okta) in
  their place. Settings › Accounts adds and removes accounts, any number.
- **Signed in, the Runner's servers appear**: the Mac's own server and each
  container server it runs, each a computer in the sidebar under the
  account. A server is not removed on its own, only with its account
  (removing it, or signing out). What a Runner stops running goes from the
  list; what it starts appears.
- **A server is reached only through its Runner**, which checks the
  client's session and passes the request on with a token of its own for
  that server. Servers no longer hold passwords for clients.
- **Native sessions over localhost stay**: Visor.app on a Mac shows its own
  server without signing in (`OwnServer`), at loopback.
- **A computer added by its code today keeps working**, as now, until it is
  removed: a code-added server and an account's sit side by side.

## The Runner's side

One port, HTTPS with the Runner's own identity (pinned by the client, as a
connection code pins a server's today):

| Request | What it does |
|---|---|
| `POST /runner/v1/sign-in` | The sign-in's proof (default: `{"username","password"}`) for a session token, its expiry and the account's name. |
| `POST /runner/v1/sign-out` | Ends the session. |
| `GET /runner/v1/servers` | The servers this session may reach: `id`, `name`, `kind` (`mac`, `container`), `state`, `version`. Answered again when it changes (an `ETag`; a live channel later). |
| `/runner/v1/servers/<id>/…` | That server's whole API, HTTP and its WebSocket, reverse-proxied: the client's session checked, the request passed on with the server's own token in place of it. |

- **Pluggable on the Runner too** (`RunnerAuth`): the default keeps users
  and their password hashes in the Runner's secrets (`visor-runner-agent
  user add <name>`, the password on standard input); a fork's checks its
  identity provider's token instead (an OIDC ID token from Okta, verified
  against the issuer's keys). Sessions are the Runner's own, either way.
- **A token per server**: the Runner gives each server it runs a token
  (`visor-server password`, as now, but held by the Runner alone) and adds
  it to what it passes on. The servers listen where only the Runner reaches
  them: the Mac's on loopback, a container's on Visor's container network.
  A server's own `hello` and REST side are as they are.
- **Who may reach what**: every user of a Runner reaches all its servers to
  begin with. A per-user list of servers is a later addition, and the fork
  may have it from its identity provider's groups.
- **The connection code becomes an invitation to the Runner**: its URL, its
  certificate's fingerprint, and a username. The QR code adds an account;
  the password is typed (or a one-time sign-in token rides in the code, to
  be decided).

## The client's side

- **`RunnerAccount`** (generalizing `VisorAccount`, which a fork can still
  set as the one account): an account's URL, fingerprint, sign-in kind,
  name and session. Kept in the keychain as records are now.
- **`RunnerSignIn`**, registered as authenticators are: `password` (a form
  of username and password) shipped; a fork's (`okta`: a web sign-in) in its
  build. A fork can make its kind the only one offered.
- **Each server is a record of the account's** (`fromAccount`, the account's
  id), its address the Runner's `…/servers/<id>` path. The record is not
  removable; Forget is on the account.
- **The sidebar** groups an account's servers under its name; Settings ›
  Accounts lists accounts with Sign Out and Remove.
- **The relay** is unchanged: the client reports every server it is
  connected to, account's or not, and carries messages between them.

## What retires

- The Runner's port per server (`front set`) and the socat forwarders: one
  port for all, the path naming the server. (visor#261's restart-on-death
  moves with it: the Runner asks after every server it runs.)
- Pairing a server by its own password, for servers a Runner runs. A
  server run without a Runner (the Linux `visor-server` on its own, Windows)
  keeps its password and code.

## Steps

1. This design, with Logan's answers to the questions below.
2. The Runner's sign-in, users and sessions, and `GET /runner/v1/servers`,
   with tests; nothing proxied yet.
3. The reverse proxy by path, HTTP and WebSocket, with the per-server
   token; the Mac's server and a container's behind it.
4. The client's accounts: Settings › Accounts, the sidebar's grouping, the
   records of an account's servers; the fork's `VisorAccount` as one such
   account.
5. The connection code as an invitation; the fronts and forwarders retired
   on the mini.

## Questions for Logan

1. **One user or several** per Runner? Proposed: several (`user add`), as a
   Mac may be shared and the fork has many.
2. **The invitation**: a username in the code and the password typed, or a
   one-time sign-in token in the code as well (scan and done, once)?
3. **The relay between servers of one Runner**: through the clients, as
   between any servers (proposed, as you said for messages), or through the
   Runner directly when both ends are its own?
4. **An account's servers on the Mac itself**: the Mac's Visor.app signs in
   to its own Runner at loopback (one model everywhere), or keeps showing
   its own server alone as now (`OwnServer`) with container servers only
   through an account?
