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

## First-time setup

```bash
git clone https://github.com/squarish/lawtools_caddy.git /home/jack/lawtools_caddy
cd /home/jack/lawtools_caddy
cp .env.example .env && $EDITOR .env      # set ACME_EMAIL

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

## Cloudflare

Do this in order. It avoids every error window.

1. **A record** `lawtools.nz` → the droplet's IPv4, initially **DNS only**
   (grey cloud). Caddy needs to be reachable directly to prove it controls the
   domain, and you want to confirm Caddy works before Cloudflare is a variable.
2. `make up`, then wait for the certificate:
   ```bash
   docker compose logs caddy | grep -i "certificate obtained"
   curl -I https://lawtools.nz/nzsc/
   ```
3. Flip the record to **Proxied** (orange cloud).
4. **SSL/TLS → Overview → Full (strict)**.

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
worst-first: the third one is the trap.

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

`STATIC_URL` and `MEDIA_URL` are already relative (`"static/"`, `"media/"`), so
Django prefixes them automatically and no template needs touching. The front
end already builds its endpoints with `{% url %}` rather than literals. That is
why the subdirectory is nearly free.

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

### 4. `compose.yml` and `.env`

Drop `ports:` from the `nginx` service, add it to the external `edge` network,
and set:

```
DJANGO_FORCE_SCRIPT_NAME=/nzsc
DJANGO_SESSION_COOKIE_NAME=nzsc_sessionid
DJANGO_CSRF_COOKIE_NAME=nzsc_csrftoken
DJANGO_ALLOWED_HOSTS=lawtools.nz
DJANGO_CSRF_TRUSTED_ORIGINS=https://lawtools.nz
DJANGO_SECURE_COOKIES=1
DJANGO_SECURE_SSL_REDIRECT=1
DJANGO_SECURE_HSTS_SECONDS=31536000
NGINX_SERVER_NAME=lawtools.nz
```

`NGINX_SERVER_NAME` is `lawtools.nz` because Caddy forwards the original `Host`
header unchanged; the app's nginx still matches on the public name and still
answers 444 to anything else.

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
| CSS and thumbnails 404, HTML fine | The app's nginx is not receiving the stripped path, or `collectstatic` has not run into the shared volume. |
| `502 Bad Gateway` | The target container is not running, or not on the `edge` network. `make ps`. |
| Cloudflare `526` | Origin certificate not yet issued. `docker compose logs caddy`. |
| Caddy will not start after an edit | `make validate` says why. CI would have caught it. |
