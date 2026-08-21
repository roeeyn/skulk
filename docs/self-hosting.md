# Self-hosting skulkd

`skulkd` is the relay. It is one Elixir application, it holds everything in memory, and it
writes nothing to disk. There is no database to provision, no migration to run, and no
backup to take — a restart deletes every room, on purpose (§20).

This document covers running it locally, running it from the container image, and putting
it behind TLS on a server you control.

> ## ⚠️ Read this before you put one on the internet
>
> **The relay reads every message.** End-to-end encryption lands at M3 and has not
> shipped. Message text arrives in plaintext, is stored in plaintext, and is replayed in
> plaintext. Room passwords reach the relay too, which hashes them with argon2id — but a
> hostile or compromised relay sees the password itself first.
>
> **There is no rate limiting, by design** (§19). No token buckets, no per-IP counters, no
> cooldowns, no bans. A relay you can reach is a relay anyone can reach, and nothing in it
> will slow down password guessing, room floods, connection floods, or a denial of service
> attempt. The bounds below cap what the relay will *hold*; they do not cap what an
> attacker may *try*.
>
> **It has never been audited.**
>
> Two mitigations are real, and both are behavioural rather than technical:
>
> 1. **Accept the generated passphrase.** Six words is about 77 bits, which puts guessing
>    out of reach. A twelve-character password you invented may not be.
> 2. **Do not post room ids anywhere public.** The id is a locator, not a credential, and
>    without rate limiting a known id is a target that can be attacked as fast as your
>    bandwidth allows.
>
> [**SECURITY.md**](../SECURITY.md) is the threat model in full. If you have not read it,
> read it before this.

---

## What you are actually running

| | |
| --- | --- |
| **Process** | one BEAM node, one GenServer per room |
| **State** | memory only — no disk, no database, no backup, no recovery |
| **Ports** | one HTTP port (default `4000`), serving `/healthz` and `/v1/ws` |
| **Restart** | destroys every room. There is no graceful drain, because there is nothing to drain to |
| **Memory** | plan for the global history bound plus overhead: `512 MiB` of retained history by default, so a 1 GiB host is tight and 2 GiB is comfortable. Lower `SKULKD_MAX_TOTAL_HISTORY_BYTES` if that is not the machine you have |
| **Logs** | connection and room lifecycle events. Room ids appear as a truncated digest and never in full (§18.1); message text never appears at all |

---

## 1. Locally, from source

Requires [Elixir](https://elixir-lang.org) 1.18+ and Erlang/OTP 27.

```console
$ cd skulkd
$ mix deps.get
$ mix run --no-halt
18:08:23.568 [info] Running Skulkd.Router with Bandit at 0.0.0.0:4000 (http)
```

```console
$ curl http://localhost:4000/healthz
{"protocol_version":0,"status":"ok"}
```

Then point a client at it. `ws://` is accepted here **only** because `localhost` is a
loopback address:

```console
$ ./bin/skulk create --server ws://localhost:4000/v1/ws
```

`task relay` does the same thing, and `task relay PORT=4001` runs a second one.

## 2. Locally, from the image

```console
$ docker build -t skulkd .
$ docker run --rm -p 4000:4000 skulkd
```

Same `/healthz`, same `--server ws://localhost:4000/v1/ws`. The image runs as an
unprivileged user, carries no shell toolchain, and has Erlang distribution switched off.

To change bounds, copy the example configuration and pass it in:

```console
$ cp skulkd/skulkd.env.example skulkd.env
$ $EDITOR skulkd.env
$ docker run --rm -p 4000:4000 --env-file skulkd.env skulkd
```

`docker compose`, if you prefer it:

```yaml
services:
  skulkd:
    image: skulkd
    build: .
    restart: unless-stopped
    # Loopback only. The reverse proxy on this host reaches it; nothing else does.
    # Drop the `127.0.0.1:` prefix ONLY if you mean to expose it directly, and read
    # the warning at the top of this file again first.
    ports:
      - "127.0.0.1:4000:4000"
    env_file:
      - skulkd.env
```

## 3. On a server, behind TLS

This is the deployment §7.4 requires documenting, and the only one a client will send a
password over: **skulk refuses to send a password over `ws://` to anything but a loopback
address.** A remote relay must be `wss://` or the client will not talk to it.

The relay does not terminate TLS. Put a reverse proxy in front of it.

### Step 1 — bind the relay to loopback

So that the proxy is the only thing that can reach it, and the relay is not
simultaneously listening on a public interface with no TLS:

```console
SKULKD_BIND=127.0.0.1:4000
```

Verify from the server that the public interface is closed:

```console
$ curl --max-time 3 http://<your-public-ip>:4000/healthz
curl: (28) Connection timed out
```

### Step 2 — terminate TLS

**Caddy** is the shortest correct answer. It obtains and renews certificates itself, and
proxies WebSocket upgrades without being told to:

```caddy
relay.example.com {
    reverse_proxy 127.0.0.1:4000
}
```

**nginx**, if that is what you already run. Three details here are not optional:

```nginx
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name relay.example.com;

    ssl_certificate     /etc/letsencrypt/live/relay.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/relay.example.com/privkey.pem;

    # Your proxy's access log records who connected and when — metadata the relay
    # itself does not keep. That is a decision, so make it deliberately.
    # access_log off;

    location / {
        proxy_pass http://127.0.0.1:4000;

        # (1) WebSocket upgrade. Without these three lines the handshake fails and
        # every client reports a connection error against a relay that looks healthy.
        proxy_http_version 1.1;
        proxy_set_header Upgrade    $http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_set_header Host              $host;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # (2) nginx closes an idle upstream connection after 60 seconds by default.
        # A skulk client pings every 2 minutes, so the default silently disconnects
        # every reading-but-not-typing user roughly once a minute. 600s matches the
        # relay's own WebSocket idle timeout.
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
    }
}
```

(3) Serve **the whole host**, or at least both `/v1/ws` and `/healthz`. A `location /v1/ws`
block alone leaves you with no way to check the relay through the proxy.

### Step 3 — check it end to end

```console
$ curl https://relay.example.com/healthz
{"protocol_version":0,"status":"ok"}

$ ./bin/skulk create --server wss://relay.example.com/v1/ws
```

If `/healthz` answers but the client cannot connect, the upgrade headers are the first
thing to look at — that is failure mode (1) above, and it looks exactly like a healthy
relay from outside.

### What TLS here does and does not buy you

It stops someone on the network path from reading messages, and it satisfies the client's
own refusal to send a password over an unencrypted connection to a remote host.

It does **not** protect anything from the relay, or from whatever terminates the TLS. Your
proxy sees plaintext. So does a hosted tunnel — an ngrok or Cloudflare endpoint terminates
TLS at its own edge, which makes that provider a second party inside the trust boundary,
reading every message and every password exactly as the relay does. That may be an
acceptable trade for trying skulk out with a friend. It is not a private conversation, and
it will not become one until M3 ships.

---

## Configuration

Every setting is an environment variable, documented one by one with its default in
[`skulkd/skulkd.env.example`](../skulkd/skulkd.env.example) — copy that file rather than
this table.

Six of §8's eleven bounds are settings — the other two variables in that table come from
§7.4 and §21. The remaining five §8 bounds have no variable on purpose: maximum message
size and maximum frame size are compile-time halves of a contract the Go client holds the
other half of, and the room-ID and password length limits are protocol validation rather
than deployment policy. Changing either kind on one relay produces a relay that disagrees
with every client. The end of `skulkd.env.example` says which is which, and why.

| Variable | Default | What it bounds |
| --- | --- | --- |
| `SKULKD_BIND` | `0.0.0.0:4000` | address and port. `127.0.0.1:4000` to sit behind a proxy |
| `SKULKD_ROOM_TTL_MS` | `432000000` (120h) | how long a room survives without an accepted message |
| `SKULKD_MAX_ROOMS` | `10000` | rooms alive at once |
| `SKULKD_MAX_MEMBERS_PER_ROOM` | `32` | participants in one room |
| `SKULKD_MAX_HISTORY_MESSAGES` | `1000` | messages retained per room |
| `SKULKD_MAX_HISTORY_BYTES` | `4194304` (4 MiB) | encoded history retained per room |
| `SKULKD_MAX_TOTAL_HISTORY_BYTES` | `536870912` (512 MiB) | encoded history across every room |
| `SKULKD_MAX_MEMBER_BACKLOG` | `500` | frames one client may fall behind before it is dropped |

Three things worth knowing about these:

- **A value that will not parse stops the boot**, naming the variable. A relay that starts
  having silently ignored a bound is worse than one that refuses to start, because you
  would believe the limit was in force.
- **The two per-room history bounds evict; the global one refuses.** A busy room keeps
  working and stops remembering its beginning. Past the global bound, chat fails with
  `server_capacity` — because the alternative is one busy room evicting another room's
  conversation.
- **Spec §7.4 spells these as command-line flags.** They are environment variables until
  M5 packages a binary that parses flags; see entry #2 in
  [`docs/deviations.md`](deviations.md).

---

## What it deliberately does not do

Each of these is a decision, not a gap:

- **Persist anything.** No disk, no database. A restart is a full reset (§20).
- **Rate limit anything.** See the warning at the top (§19).
- **List rooms.** There is no discovery endpoint and never will be (§9.1). `/healthz` is
  the entire non-WebSocket surface, and it says nothing about any room.
- **Moderate anything.** No admin, no kick, no approval, no ban (§26).
- **Cluster.** One node. The image ships with Erlang distribution switched off.

## Operating it

**Health.** `GET /healthz` returns `{"protocol_version":0,"status":"ok"}` and requires no
authentication. It is safe to expose and reveals nothing about rooms. The container image
uses it as its own `HEALTHCHECK`.

**Logs.** Room ids appear as a truncated digest, never in full (§18.1), and message text
never appears at all (§18.2). What a log does show is connection and room lifecycle
events, which is metadata about who was talking to your relay and when.

**Restarts.** There is nothing to drain and nothing to save. Everyone is disconnected,
every room is gone, and the clients will say so.

**Upgrades.** The relay and the client negotiate a protocol version, and a mismatch is
refused with `unsupported_protocol_version` — which looks like the application being
broken and is in fact the protocol working. **M2 and M3 are protocol version bumps**, so
when they land, relay and clients have to move together. Keep the image tag and the client
version in step; that lockstep is the reason this milestone exists at all
([entry #1 in `docs/deviations.md`](deviations.md)).
