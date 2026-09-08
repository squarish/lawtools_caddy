# Convenience wrappers. Everything here is a docker compose command you could
# type by hand; these exist so you do not have to remember the flags.

COMPOSE := docker compose
CADDY_IMAGE := caddy:2-alpine
ADMIN := unix//run/caddy-admin.sock

.PHONY: help bootstrap up down reload validate fmt logs ps

help:
	@grep -E '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  %-12s %s\n", $$1, $$2}'

bootstrap: ## One-time: create the shared network and the certificate volume
	docker network create edge 2>/dev/null || echo "network 'edge' already exists"
	docker volume create caddy_data 2>/dev/null || echo "volume 'caddy_data' already exists"

up: validate ## Start the edge (validates the config first)
	$(COMPOSE) up -d

down: ## Stop the edge. Never add -v: that would delete the certificates.
	$(COMPOSE) down

reload: validate ## Apply a config change with no dropped connections
	$(COMPOSE) exec caddy caddy reload --config /etc/caddy/Caddyfile --address $(ADMIN)

validate: ## Parse the config without starting anything
	docker run --rm -v $(CURDIR):/etc/caddy:ro -e ACME_EMAIL=validate@example.com \
		--entrypoint caddy $(CADDY_IMAGE) validate --config /etc/caddy/Caddyfile --adapter caddyfile

fmt: ## Rewrite the config files in canonical form
	docker run --rm -v $(CURDIR):/etc/caddy --entrypoint caddy $(CADDY_IMAGE) fmt --overwrite /etc/caddy/Caddyfile
	docker run --rm -v $(CURDIR):/etc/caddy --entrypoint sh $(CADDY_IMAGE) -c 'for f in /etc/caddy/sites/*.caddy; do caddy fmt --overwrite "$$f"; done'

logs: ## Follow the access and error log
	$(COMPOSE) logs -f caddy

ps: ## What is running, and what is on the edge network
	$(COMPOSE) ps
	@echo
	docker network inspect edge --format '{{range .Containers}}{{.Name}} {{end}}'
