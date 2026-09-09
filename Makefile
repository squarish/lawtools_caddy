# Convenience wrappers. Everything here is a docker compose command you could
# type by hand; these exist so you do not have to remember the flags.

COMPOSE := docker compose
CADDY_IMAGE := caddy:2-alpine
ADMIN := unix//run/caddy-admin.sock

.PHONY: help require-docker bootstrap up down reload validate fmt logs ps

help:
	@grep -E '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  %-12s %s\n", $$1, $$2}'

# Every other target shells out to docker. Without this check the failure
# surfaces differently depending on the recipe: make runs a line containing no
# shell metacharacters by exec'ing it directly, so a missing binary reads as
# `make: docker: No such file or directory`, while a line with `||` in it goes
# through sh and can have that same failure mistaken for the fallback case.
require-docker:
	@command -v docker >/dev/null 2>&1 || { \
		echo 'docker is not installed, or not on this shell PATH.'; \
		echo; \
		echo '  curl -fsSL https://get.docker.com | sudo sh'; \
		echo '  sudo usermod -aG docker $$USER'; \
		echo; \
		echo 'Then open a new login shell, so the group membership takes effect.'; \
		exit 1; }
	@docker compose version >/dev/null 2>&1 || { \
		echo 'docker is installed but the compose plugin is missing.'; \
		echo 'On Debian and Ubuntu:  sudo apt-get install -y docker-compose-plugin'; \
		exit 1; }

bootstrap: require-docker ## One-time: create the shared network and the certificate volume
	@if docker network inspect edge >/dev/null 2>&1; then \
		echo "network 'edge' already exists"; \
	else \
		docker network create edge; \
	fi
	@if docker volume inspect caddy_data >/dev/null 2>&1; then \
		echo "volume 'caddy_data' already exists"; \
	else \
		docker volume create caddy_data; \
	fi

up: validate ## Start the edge (validates the config first)
	$(COMPOSE) up -d

down: require-docker ## Stop the edge. Never add -v: that would delete the certificates.
	$(COMPOSE) down

reload: validate ## Apply a config change with no dropped connections
	$(COMPOSE) exec caddy caddy reload --config /etc/caddy/Caddyfile --address $(ADMIN)

validate: require-docker ## Parse the config without starting anything
	docker run --rm -v $(CURDIR):/etc/caddy:ro -e ACME_EMAIL=validate@example.com \
		--entrypoint caddy $(CADDY_IMAGE) validate --config /etc/caddy/Caddyfile --adapter caddyfile

fmt: require-docker ## Rewrite the config files in canonical form
	docker run --rm -v $(CURDIR):/etc/caddy --entrypoint caddy $(CADDY_IMAGE) fmt --overwrite /etc/caddy/Caddyfile
	docker run --rm -v $(CURDIR):/etc/caddy --entrypoint sh $(CADDY_IMAGE) -c 'for f in /etc/caddy/sites/*.caddy; do caddy fmt --overwrite "$$f"; done'

logs: require-docker ## Follow the access and error log
	$(COMPOSE) logs -f caddy

ps: require-docker ## What is running, and what is on the edge network
	$(COMPOSE) ps
	@echo
	docker network inspect edge --format '{{range .Containers}}{{.Name}} {{end}}'
