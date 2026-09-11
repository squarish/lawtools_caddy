# lawtools_caddy

The HTTPS edge for the droplet that serves `lawtools.nz`.

Caddy is the only process on the box bound to ports 80 and 443. Every
application is a separate compose stack in its own repository, publishes no
ports at all, and is reached by container name over a shared Docker network.
Adding a site or a subdirectory is one small change to `sites/`.

```
Cloudflare ──443──▶ Caddy ──▶ nzsc_nginx:80 ──▶ nzsc_web:8000   (/nzsc)
   (proxied)      lawtools_caddy      │                          Django
                                      └──▶ static + media off a volume
                                      └──▶ nzsc_mcp:3000         (/nzsc/mcp)
```

## Layout

| Path | What |
|---|---|
| `Caddyfile` | Global options only — ACME, admin socket, Cloudflare trust. Imports `sites/`. |
| `sites/lawtools.nz.caddy` | One file per domain. This is where routing lives. |
| `compose.yml` | The Caddy service. Owns `:80` and `:443`. |
| `Makefile` | `make help` lists everything. |
| `.github/workflows/ci.yml` | Parses the config on every push, before it can reach the server. |

On the server this is cloned to `/home/jack/lawtools_caddy`, alongside
`/home/jack/nzsc-django` and any later siblings.

## Deploying a droplet from scratch

Start to finish on a new box. Two orderings matter, and both are called out
where they bite: the DNS record has to exist before the edge starts, and the
edge has to exist before an application stack can join it.

### 1. Prepare the box

A plain Ubuntu droplet ships with neither swap nor Docker. Only DigitalOcean's
Docker marketplace image has the second.

**Swap.** A 1 GB droplet has none, and a `docker compose build` that reaches the
ceiling is killed by the OOM reaper rather than slowed down — which reads as a
mysteriously failing build, not as a memory problem. Two gigabytes costs nothing
while unused:

```bash
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-swappiness.conf
sudo sysctl vm.swappiness=10
free -h
```

The `chmod 600` is not optional — `mkswap` refuses a world-readable file, and it
is right to: anything paged out is readable there. `swappiness=10` keeps swap as
headroom for builds rather than somewhere the kernel relocates a running
gunicorn to. The `fstab` line is what survives a reboot, which is exactly when
nobody is watching.

**Docker.**

```bash
docker compose version
```

If that prints a version, skip ahead. If it says `docker: command not found`:

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER
```

Then **open a new login shell.** Group membership is read at login, so until you
do, this one keeps getting `permission denied` on `/var/run/docker.sock`.

### 2. Point DNS at the droplet, unproxied

One A record: `lawtools.nz` → the droplet's IPv4, set to **DNS only** (grey
cloud).

This comes before the edge starts. Caddy proves it controls the domain over
plain HTTP on port 80, so the name has to resolve to the droplet and reach it
directly. Leaving Cloudflare's proxy off until step 5 also means that when
something breaks in between, there is one fewer thing it could be.

### 3. The edge

```bash
git clone https://github.com/squarish/lawtools_caddy.git /home/jack/lawtools_caddy
cd /home/jack/lawtools_caddy
cp .env.example .env
nano .env                                 # set ACME_EMAIL to an address you read

make bootstrap                            # creates the `edge` network and caddy_data volume
make up                                   # validates the config, then starts
make logs
```

`make bootstrap` creates two things by hand rather than letting compose manage
them:

- **the `edge` network** — it is shared with stacks in other repositories, so it
  cannot belong to any one of them;
- **the `caddy_data` volume** — it holds the certificates and the ACME account
  key. Declaring it external is what stops a stray `docker compose down -v`
  from deleting them. Let's Encrypt issues five certificates per domain per
  week, which is enough to recover from the accident once and not enough to
  recover from the habit.

**Never run `docker compose down -v` in this directory.** `make down` is safe.

Wait for the certificate before going further:

```bash
docker compose logs caddy | grep -i "certificate obtained"
```

At this point `https://lawtools.nz/` answers 404 and `https://lawtools.nz/nzsc/`
answers 502. Both are correct: the routing exists, the application behind it
does not yet.

### 4. The application stack

```bash
git clone https://github.com/squarish/nzsc-django.git /home/jack/nzsc-django
cd /home/jack/nzsc-django
cp .env.example .env
nano .env
docker compose up -d --build
docker compose logs -f web
```

The whole `.env` for this deployment is written out under [companion change
4](#4-composeyml-and-env) below — copy it from there rather than assembling one,
because four of its lines exist to override a default that is wrong here and
silent about it. `DJANGO_DEBUG=0` and `MCP_API_KEY` are the two that will not
wait: the first serves debug tracebacks to the public, the second can take nginx
down with it. That repository's `.env.example` documents every variable it
reads.

The `web` container's entrypoint waits for Postgres, migrates, and runs
`collectstatic` on boot, so there is no separate step for any of the three.
Watch that in `logs -f`: a first boot ends with a schema and no rows.

Creating the first account is a manual step, and loading the corpus is that
repository's business rather than the edge's — see its README.

```bash
docker compose exec web python manage.py createsuperuser
```

### 5. Verify the origin, before Cloudflare is a variable

```bash
curl -sI https://lawtools.nz/nzsc/ | head -1     # 200
curl -sI https://lawtools.nz/nzsc  | head -1     # 301, Location: /nzsc/
curl -sI https://lawtools.nz/      | head -1     # 404, deliberately
```

If those three are right, the edge is doing its job, and anything that breaks
after the next step is Cloudflare's doing. If `/nzsc/` gives 502, the app stack
is not on the `edge` network or is not running: `make ps` lists both.

### 6. Cloudflare, then the firewall

Both below. Do them in that order — the firewall rules are written in terms of
Cloudflare's address ranges, and applying them while the record is still grey
locks you out of your own origin.

## Cloudflare

Steps 2 to 5 above leave a working origin on a grey-cloud record. Two changes
remain, in this order:

1. Flip the record to **Proxied** (orange cloud).
2. **SSL/TLS → Overview → Full (strict)**.

That last setting is not optional. Under **Flexible**, Cloudflare speaks plain
HTTP to the origin; Django sees an insecure request, `SECURE_SSL_REDIRECT`
sends a 301 to `https://`, Cloudflare serves it from cache over HTTPS and
forwards to the origin over HTTP again, and the browser gives up with
`ERR_TOO_MANY_REDIRECTS`. **Full (strict)** verifies the real Let's Encrypt
certificate Caddy holds, which is the whole point of terminating TLS here.

Renewals keep working once proxied: Cloudflare exempts
`/.well-known/acme-challenge/` from *Always Use HTTPS*, so the HTTP-01
challenge still reaches the origin.

## The contract with an application stack

Any stack that wants to be served through this edge must:

1. **Publish no ports.** Delete the `ports:` block from its proxy service. If
   the app is reachable on the host's public IP, it is reachable in a way that
   skips TLS and skips the `X-Forwarded-Proto` chain.
2. **Join the `edge` network**, declared external:
   ```yaml
   networks:
     edge:
       external: true
       name: edge
   ```
   and add `edge` to the `networks:` list of the service Caddy proxies to.
3. **Have a stable `container_name`.** That name is the address in
   `sites/*.caddy`. The compose *service* name is not usable: several stacks
   will each have a service called `nginx`, and they would collide on a shared
   network.
4. **Accept a stripped path prefix**, if it lives in a subdirectory. See below.

## Companion changes needed in `squarish/nzsc-django`

These are not in this repository, but nothing works without them. Listed
worst-first: the third one is the trap. All four are on `main` in that repo —
a fresh clone has them, and there is no branch to check out. They are written
out here anyway, because what they are for is not obvious from reading them.

### 1. `FORCE_SCRIPT_NAME` — `config/settings.py`

`handle_path /nzsc/*` strips the prefix, so Django receives `/admin/` and
resolves it normally. But it must *generate* `/nzsc/admin/`, or every link,
form action and redirect points out of the subdirectory.

```python
#: Set to /nzsc in production. The edge strips this prefix before the request
#: arrives, so the URLconf never sees it; this is what puts it back on every
#: URL Django generates. Unset (None) everywhere else, including the tests.
FORCE_SCRIPT_NAME = os.environ.get("DJANGO_FORCE_SCRIPT_NAME") or None
```

`STATIC_URL` and `MEDIA_URL` derive from it in the same file:

```python
STATIC_URL = f"{FORCE_SCRIPT_NAME or ''}/static/"
MEDIA_URL = f"{FORCE_SCRIPT_NAME or ''}/media/"
```

Django can prefix these on its own if they are written relative (`"static/"`),
but it resolves the prefix when the value is first read and both readers cache
it — `LazySettings` keeps the string, and staticfiles' storage singleton
captures `base_url` at construction. The first read wins for the life of the
process, so one read before any request has set a prefix freezes `/static/`
into every page that process renders: a site with no stylesheet, and nothing in
the log. Deriving it explicitly removes the timing question.

The front end already builds its endpoints with `{% url %}` rather than
literals, so nothing in the templates needs touching. That is why the
subdirectory is otherwise cheap.

### 2. Cookie names — `config/settings.py`

A second application at `lawtools.nz/other` would set its own `sessionid` and
`csrftoken` on the same domain, and the two would overwrite each other — you
would be logged out of one admin by logging into the other.

```python
SESSION_COOKIE_NAME = os.environ.get("DJANGO_SESSION_COOKIE_NAME", "sessionid")
CSRF_COOKIE_NAME = os.environ.get("DJANGO_CSRF_COOKIE_NAME", "csrftoken")
```

with `DJANGO_SESSION_COOKIE_NAME=nzsc_sessionid` and
`DJANGO_CSRF_COOKIE_NAME=nzsc_csrftoken` in production. Distinct *names* rather
than `SESSION_COOKIE_PATH="/nzsc"`: path-scoping also works, but it silently
logs everyone out the day the prefix changes, and it does not protect the CSRF
cookie from a sibling that has not set a path.

### 3. `X-Forwarded-Proto` — `nginx/nginx.conf.template`

**This one produces a redirect loop on first boot if it is missed.** The
template currently says:

```nginx
proxy_set_header X-Forwarded-Proto $scheme;
```

Caddy terminates TLS and forwards `X-Forwarded-Proto: https`. nginx then
overwrites it with `$scheme`, which is `http` — nginx is listening on plain
port 80 behind the edge. Django reads `http`, decides the request was insecure,
and `SECURE_SSL_REDIRECT` sends a 301 to the URL the browser just asked for.

Preserve an upstream value when there is one, fall back to `$scheme` when there
is not, so the stack still works standalone:

```nginx
# http context, next to the upstream blocks
map $http_x_forwarded_proto $forwarded_proto {
    default  $scheme;
    https    https;
    http     http;
}
```
```nginx
# server context, replacing the existing line
proxy_set_header X-Forwarded-Proto $forwarded_proto;
```

Trusting a client-supplied header is only safe because step 1 of the contract
removed the published port: nothing but Caddy can reach nginx.

### 3a. `LOGIN_REDIRECT_URL` — `config/settings.py`

It was the literal `"/admin/"`, the one hardcoded absolute path in the tree.
Under a prefix that sends a successful login to `/admin/` — outside the
subdirectory, where this edge has nothing mounted, so signing in lands on the
404 above. It is `"admin:index"` now, a URL name, so it goes through
`reverse()`.

### 4. `compose.yml` and `.env`

Drop `ports:` from the `nginx` service and add it to the external `edge`
network. Both are already done on `main`.

The `.env` is the part that is still on you. Below is the whole file for this
deployment, not only the subdirectory half: four of these are things whose
*default* is wrong here, and a default is exactly what nobody notices.

```
# Nothing below this line has a safe default. See the notes after the block.
DJANGO_SECRET_KEY=<python3 -c "import secrets; print(secrets.token_urlsafe(64))">
DJANGO_DEBUG=0
DJANGO_ALLOWED_HOSTS=lawtools.nz,web
DJANGO_CSRF_TRUSTED_ORIGINS=https://lawtools.nz

DATABASE_NAME=nzsc
DATABASE_USERNAME=nzsc
DATABASE_PASSWORD=<something long>
DATABASE_PORT=5432

DJANGO_FORCE_SCRIPT_NAME=/nzsc
DJANGO_SESSION_COOKIE_NAME=nzsc_sessionid
DJANGO_CSRF_COOKIE_NAME=nzsc_csrftoken

DJANGO_SECURE_COOKIES=1
DJANGO_SECURE_SSL_REDIRECT=1
DJANGO_SECURE_HSTS_SECONDS=31536000

NGINX_SERVER_NAME=lawtools.nz

MCP_API_KEY=<openssl rand -hex 32>
MCP_ALLOWED_HOSTS=localhost,127.0.0.1,mcp,lawtools.nz
```

**`DJANGO_DEBUG=0` is not optional and does not happen on its own.** It
defaults to *on* — `_env_bool("DJANGO_DEBUG", True)` in `config/settings.py` —
and `.env.example` ships it commented out, so a file assembled from the
subdirectory settings alone serves Django's debug tracebacks, settings and
SQL to anyone who can reach a 500. Everything else on this page is a
deployment that does not work; this is one that works and should not.

**`MCP_API_KEY` must be set even if you never use the MCP server.**
`mcp_server/server.py` raises on import without it, and the `mcp` service has
`restart: always`, so it crash-loops instead of stopping. That is worse than it
sounds: the app's `nginx.conf.template` declares `upstream mcp { server
mcp:3000; }` with no `resolver`, and nginx resolves upstream names once, at
config-load time. Docker's DNS only answers for running containers, so an nginx
that starts during one of the crash windows dies with `host not found in
upstream "mcp"` — and the symptom is the whole site down, with the cause in a
container nobody was thinking about.

**`DJANGO_ALLOWED_HOSTS` needs `web` as well as the public name.** The MCP
server reaches Django at `http://web:8000`, so Django sees `Host: web` and
answers 400 to a name it was never told about. `lawtools.nz` alone is right for
every browser request and wrong for the one caller that is not a browser.

**`MCP_ALLOWED_HOSTS` needs the public name** for the same reason in reverse.
Caddy forwards the browser's `Host` unchanged and the app's nginx passes it
through, so the MCP transport sees `lawtools.nz` and refuses it as a
DNS-rebinding attempt — a 421, which reads like an auth failure and is not one.

`NGINX_SERVER_NAME` is `lawtools.nz` because Caddy forwards the original `Host`
header unchanged; the app's nginx still matches on the public name and still
answers 444 to anything else.

One caution about the HSTS line. `SECURE_HSTS_INCLUDE_SUBDOMAINS` and
`SECURE_HSTS_PRELOAD` are both derived from `SECURE_HSTS_SECONDS > 0` in that
repo's settings, so the value above commits *every* `lawtools.nz` subdomain to
HTTPS and advertises an intent to be preloaded — a year-long promise made by an
application living in a subdirectory. That is a reasonable thing to want, and a
surprising thing to acquire by accident. `DJANGO_SECURE_HSTS_SECONDS=300` for
the first week makes it reversible while you find out.

## Day to day

```bash
make reload    # apply a config change with no dropped connections
make validate  # parse it without starting anything
make fmt       # rewrite the files in canonical form
make logs
make ps        # what is running, and what is on the edge network
```

`make reload` goes through Caddy's admin API over a unix socket inside the
container. The API is deliberately not on `localhost:2019`, its default: that
address is reachable from every other container on the `edge` network, which
would turn a compromise of any application into control of the edge.

## Adding a second subdirectory

Two directives in `sites/lawtools.nz.caddy`:

```caddy
redir /other /other/ permanent
handle_path /other/* {
	reverse_proxy other_nginx:80
}
```

The `redir` is not decoration: `handle_path /other/*` does not match a bare
`/other`, which would otherwise fall to the catch-all and 404.

## Adding a second domain

A new file, `sites/example.nz.caddy`. Caddy obtains the certificate on first
request. Nothing else changes.

## Firewall (optional, after going proxied)

Once Cloudflare fronts the site, only Cloudflare needs to reach 80 and 443.
This closes direct-to-origin requests, including anyone who has learned the IP:

```bash
for ip in $(curl -s https://www.cloudflare.com/ips-v4) \
          $(curl -s https://www.cloudflare.com/ips-v6); do
  sudo ufw allow proto tcp from "$ip" to any port 80,443 comment 'cloudflare'
done
sudo ufw --force enable
```

Keep your SSH rule first, and be aware this also stops *you* testing the origin
by IP — which is occasionally how you tell a Cloudflare problem from an origin
problem.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `ERR_TOO_MANY_REDIRECTS` | Companion change 3, or Cloudflare set to Flexible instead of Full (strict). |
| Every route under `/nzsc/` 404s, root included | `handle` used instead of `handle_path`, so the prefix arrived unstripped. |
| Pages load but every link drops the `/nzsc` prefix | `FORCE_SCRIPT_NAME` not set. |
| Signing into the admin lands on the edge's 404 | `LOGIN_REDIRECT_URL` written as a path instead of a URL name. |
| CSS and thumbnails 404, HTML fine | The app's nginx is not receiving the stripped path, or `collectstatic` has not run into the shared volume. |
| `502 Bad Gateway` | The target container is not running, or not on the `edge` network. `make ps`. |
| Django's debug page on any error, in production | `DJANGO_DEBUG` unset. It defaults to on. Companion change 4. |
| The whole site 502s, and `nzsc_nginx` exited with `host not found in upstream "mcp"` | `MCP_API_KEY` unset, so `nzsc_mcp` is crash-looping and nginx could not resolve it at startup. Companion change 4. |
| `400 Bad Request` from the MCP server's API calls only | `DJANGO_ALLOWED_HOSTS` is missing `web`. Companion change 4. |
| `421` from `/nzsc/mcp`, with a key that is right | `MCP_ALLOWED_HOSTS` is missing `lawtools.nz`. Companion change 4. |
| Cloudflare `526` | Origin certificate not yet issued. `docker compose logs caddy`. |
| Caddy will not start after an edit | `make validate` says why. CI would have caught it. |
| `make: docker: No such file or directory` | Docker is not installed, or not on this shell's PATH. Deployment step 1. |
| `permission denied` on `/var/run/docker.sock` | You are not in the `docker` group, or you are but have not opened a new login shell since. Deployment step 1. |
