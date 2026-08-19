#------------------------------------------------------------------------------
# Wirenboard On-Premise - Makefile (Production, Colorful & Informative Output)
#------------------------------------------------------------------------------

MAKEFLAGS += --no-print-directory

RED   = \033[0;31m
YELLOW= \033[1;33m
GREEN = \033[0;32m
NC    = \033[0m  # No Color

VERSION = $(shell tr -d '[:space:]' < VERSION 2>/dev/null)

define require_version
	@if [ -z "$(VERSION)" ]; then \
		printf "$(RED)ERROR: VERSION file missing or empty$(NC)\n"; exit 1; \
	fi
endef

ENV_FILE      := .env
ENV_EXAMPLE   := .env.example
ENV_GET        = $(shell bash scripts/env.sh get $(1) $(ENV_FILE))

# Both defined once and shared with the scripts: the marker name lives in env.sh,
# and these are the variables whose presence still marks a 1.x configuration.
UPGRADE_MARKER := $(shell bash scripts/env.sh marker)
LEGACY_VARS    := INFLUXDB_TOKEN ADMIN_USERNAME EMAIL_PROTOCOL
LEGACY_RE      := ^[[:space:]]*($(shell printf '%s' "$(LEGACY_VARS)" | tr ' ' '|'))=

#----- [ REQUIRED ENVIRONMENT VARIABLES ] -------------------------------------

# EMAIL_ENABLED is mandatory since 2.0 (REQUIRED_VARS + compose fail-fast).
# False/Off/No/0 (case-insensitive) disables email and makes EMAIL_* optional.
EMAIL_ENABLED_VALUE := $(shell printf '%s' "$(call ENV_GET,EMAIL_ENABLED)" | tr '[:upper:]' '[:lower:]')
EMAIL_DISABLED := $(if $(filter $(EMAIL_ENABLED_VALUE),false off no 0),1,0)

# Read by the backend and by Grafana, whose boolean dictionaries differ: 'ok' and
# 'Y' mean on for the cloud and off for Grafana. Only shared spellings are allowed.
EMAIL_ENABLED_RAW := $(call ENV_GET,EMAIL_ENABLED)
EMAIL_BOOL_OK := true True TRUE yes Yes YES on On ON 1 y \
                 false False FALSE no No NO off Off OFF 0

EMAIL_REQUIRED_VARS := \
  EMAIL_HOST \
  EMAIL_PORT \
  EMAIL_HOST_USER \
  EMAIL_HOST_PASSWORD \
  EMAIL_NOTIFICATIONS_FROM

REQUIRED_VARS := \
  ABSOLUTE_SERVER \
  EMAIL_ENABLED \
  ADMIN_EMAIL \
  ADMIN_PASSWORD \
  TUNNEL_DASHBOARD_USER \
  TUNNEL_DASHBOARD_PASSWORD \
  POSTGRES_USER \
  POSTGRES_PASSWORD \
  POSTGRES_DB \
  GRAFANA_ADMIN_USER \
  GRAFANA_ADMIN_PASSWORD \
  TUNNEL_AUTH_TOKEN \
  SECRET_KEY \
  ABSOLUTE_SERVER_REGEX \
  PRIVATE_KEY \
  PUBLIC_KEY \
  TIMESCALE_PASSWORD \
  TELEGRAF_TIMESCALE_PASSWORD \
  GRAFANA_TIMESCALE_PASSWORD

ifeq ($(EMAIL_DISABLED),0)
REQUIRED_VARS += $(EMAIL_REQUIRED_VARS)
endif

# Empty is a legitimate answer here: a relay that takes mail without authentication.
ALLOW_EMPTY_VARS := EMAIL_HOST_USER EMAIL_HOST_PASSWORD

# These end up inside credential URLs (DATABASE_URL, GRAFANA_ADMIN_MANAGEMENT_URL).
URL_CRED_VARS := POSTGRES_USER POSTGRES_PASSWORD GRAFANA_ADMIN_USER GRAFANA_ADMIN_PASSWORD

#----- [ DOMAIN & CERTIFICATES ] ----------------------------------------------

RAW_SERVER      := $(call ENV_GET,ABSOLUTE_SERVER)
BASE_DOMAIN     := $(shell echo $(RAW_SERVER) | sed -E 's@https?://@@;s@/.*@@' | cut -d':' -f1)

TLS_DIR         := $(or $(TLS_CERTS_PATH),$(call ENV_GET,TLS_CERTS_PATH))
TLS_DIR         := $(or $(TLS_DIR),./tls)

FULLCHAIN       := $(TLS_DIR)/fullchain.pem
CERT            := $(TLS_DIR)/cert.pem
CHAIN           := $(TLS_DIR)/chain.pem
PRIVKEY         := $(TLS_DIR)/privkey.pem

REQUIRED_DOMAINS := $(BASE_DOMAIN) *.$(BASE_DOMAIN) *.ssh.$(BASE_DOMAIN) *.http.$(BASE_DOMAIN) *.apps.$(BASE_DOMAIN)

#------------------------------------------------------------------------------
# [ HELP ]
#------------------------------------------------------------------------------

.PHONY: help
help:
	@printf "\nUsage: make <target>\n\n"
	@printf "Available targets:\n"
	@printf "  help                     Show this message\n"
	@printf "  check-env                Check all required variables in .env\n"
	@printf "  check-certs              Check TLS certificates and domain coverage\n"
	@printf "  generate-env             Generate all secrets and variables (non-destructive)\n"
	@printf "  run                      Full project launch: generate-env, check-certs, start containers\n"
	@printf "  run-no-cert-check        Launch without checking TLS certificates (not recommended)\n"
	@printf "  stop                     Stop containers\n"
	@printf "  restart                  Restart containers (with cert check)\n"
	@printf "  update                   Update images, rebuild and start\n"
	@printf "  upgrade                  1.x -> 2.x upgrade: checks, then backup, stop, migrate, start\n"
	@printf "  fix-users                Run migration_doctor (MODE=scan|auto|resolve|dump|apply)\n"
	@printf "  backup                   Back up PostgreSQL (+ InfluxDB if present) into ./backups\n"
	@printf "  reload-certs             Apply a renewed TLS certificate (restarts Traefik only)\n"
	@printf "  update-geoip             Refresh the session geolocation database\n"
	@printf "  generate-jwt             Generate/update keys for JWT\n"
	@printf "  generate-tunnel-token    Generate SSH/HTTP tunnel token\n"
	@printf "  generate-django-secret   Generate Django secret key\n"

#------------------------------------------------------------------------------
# [ INTROSPECTION ] -----------------------------------------------------------
# migration/migrate-env.sh asks for these instead of scraping the file: make expands
# the lists itself, so the conditional EMAIL_* part is already resolved.

.PHONY: print-required-vars
print-required-vars:
	@printf '%s\n' $(REQUIRED_VARS)

.PHONY: print-allow-empty-vars
print-allow-empty-vars:
	@printf '%s\n' $(ALLOW_EMPTY_VARS)

#------------------------------------------------------------------------------
# [ 1.x GUARD ] ---------------------------------------------------------------

# The 2.x images run their migrations as they start, and that migration aborts on
# an unrepaired 1.x database — so every target that starts the stack has to refuse
# while the installation is still on 1.x. Only `make upgrade` may proceed: it backs
# up, repairs the accounts and migrates in the right order. Both signals disappear
# once the upgrade is done, which is what lets `make update` work again afterwards.
.PHONY: check-not-1x
check-not-1x:
	@if [ -f "$(UPGRADE_MARKER)" ]; then \
		printf "$(RED)ERROR: an upgrade is unfinished — the configuration is already 2.x while the database may not be.$(NC)\n"; \
		printf "$(YELLOW)Starting the stack now would migrate on top of that. Finish the upgrade instead:$(NC)\n"; \
		printf "$(YELLOW)  make fix-users MODE=scan   see what stopped it\n  make upgrade               run it again$(NC)\n"; \
		printf "$(YELLOW)To go back instead, follow the rollback in migration/RELEASE_NOTES_2.0.md — it clears this state.$(NC)\n"; \
		exit 1; \
	fi
	@old_img="$$(docker ps --format '{{.Image}}' 2>/dev/null | grep -E 'on-premise/wbc-' | sed 's/.*://' | awk -F. '$$1 ~ /^[0-9]+$$/ && $$1 < 2' | sort -u | head -1)"; \
	if grep -Eq '$(LEGACY_RE)' $(ENV_FILE) 2>/dev/null; then \
		old_env="its $(ENV_FILE) is still the 1.x one"; \
	fi; \
	if [ -n "$$old_img" ] || [ -n "$${old_env:-}" ]; then \
		printf "$(RED)ERROR: this installation is still on 1.x%s.$(NC)\n" "$${old_img:+ (running $$old_img)}$${old_env:+ ($$old_env)}"; \
		printf "$(YELLOW)Starting %s here would migrate the database on image start, and that$(NC)\n" "$(VERSION)"; \
		printf "$(YELLOW)migration aborts on a 1.x database: the cloud stops and no backup exists.$(NC)\n"; \
		printf "$(YELLOW)Run 'make upgrade' instead — it backs up, repairs the accounts and$(NC)\n"; \
		printf "$(YELLOW)migrates in the right order. Afterwards 'make update' works as usual.$(NC)\n"; \
		exit 1; \
	fi

#------------------------------------------------------------------------------
# [ TESTS ] -------------------------------------------------------------------
# Fixtures only — no containers, no database. Not shipped with the release.

# tests/ covers the product; migration/tests/ goes away with the 1.x upgrade path.
.PHONY: test
test:
	@printf "\n\n\033[1;37m%s\033[0m\n" "=====================[ TESTS ]====================="
	@bash tests/test-check-env.sh
	@printf "\n"
	@bash migration/tests/test-migrate-env.sh
	@printf "\n"
	@bash migration/tests/test-upgrade-gate.sh
	@printf "\n"
	@python3 migration/tests/test_migration_doctor.py

#------------------------------------------------------------------------------
# [ TLS CERTIFICATE CHECK ] ---------------------------------------------------

# Traefik bind-mounts the certificate files, so Docker creates a directory in place
# of a missing one — after which the real certificate cannot be put there.
.PHONY: check-cert-paths
check-cert-paths:
	@for f in "$(PRIVKEY)" "$(FULLCHAIN)"; do \
		if [ -d "$$f" ]; then \
			printf "$(RED)ERROR: %s is a directory, not a file.$(NC)\n" "$$f"; \
			printf "$(YELLOW)Docker created it when the stack started without the certificate in place.$(NC)\n"; \
			printf "$(YELLOW)Remove it and put the certificate there: rmdir '%s'$(NC)\n" "$$f"; \
			exit 1; \
		fi; \
	done

.PHONY: check-certs
check-certs: check-cert-paths
	@printf "\n\n\033[1;37m%s\033[0m\n" "=====================[ CHECKING TLS CERTIFICATES ]====================="
	@printf "Checking TLS certificates...\n"
	@if [ -z "$(RAW_SERVER)" ]; then \
		printf "$(RED)ERROR: The variable ABSOLUTE_SERVER is missing in $(ENV_FILE).$(NC)\n"; exit 1; fi
	@printf "Domain: %s\n" "$(BASE_DOMAIN)"
	@printf "Certificate directory: %s\n" "$(TLS_DIR)"
	@printf "\n\033[0;37m%s\033[0m\n" "------ Checking private key presence ------"
	@if [ ! -f "$(PRIVKEY)" ]; then \
		printf "$(RED)ERROR: Private key not found: %s$(NC)\n" "$(PRIVKEY)"; exit 1; \
	else \
		printf "$(GREEN)Private key found: %s$(NC)\n" "$(PRIVKEY)"; \
	fi
	@if [ -f "$(FULLCHAIN)" ]; then \
		printf "$(GREEN)Fullchain found: %s$(NC)\n" "$(FULLCHAIN)"; \
	else \
		if [ -f "$(CERT)" ] && [ -f "$(CHAIN)" ]; then \
			printf "Creating fullchain.pem from cert.pem and chain.pem...\n"; \
			cat $(CERT) $(CHAIN) > $(FULLCHAIN); \
			printf "$(GREEN)Fullchain.pem created.$(NC)\n"; \
		else \
			printf "$(RED)ERROR: No fullchain.pem found and cert.pem or chain.pem is missing.$(NC)\n"; exit 1; \
		fi \
	fi
	@printf "\n\033[0;37m%s\033[0m\n" "------ Validating key and certificate match ------"
	@printf "Verifying key and certificate match...\n"
	@CERT_MOD=$$(openssl x509 -noout -modulus -in $(FULLCHAIN) | openssl md5); \
	KEY_MOD=$$(openssl rsa -noout -modulus -in $(PRIVKEY) | openssl md5); \
	if [ "$$CERT_MOD" != "$$KEY_MOD" ]; then \
		printf "$(RED)ERROR: Certificate and private key do not match.$(NC)\n"; exit 1; \
	else \
		printf "$(GREEN)Key and certificate match.$(NC)\n"; \
	fi
	@printf "\n\033[0;37m%s\033[0m\n" "------ Validating certificate expiry date ------"
	@printf "Validating certificate expiry date...\n"
	@EXP_DATE=$$(openssl x509 -in $(FULLCHAIN) -noout -enddate | cut -d= -f2); \
	EXP_EPOCH=$$(date -d "$$EXP_DATE" +%s); \
	NOW_EPOCH=$$(date +%s); \
	if [ $$EXP_EPOCH -le $$NOW_EPOCH ]; then \
		printf "$(RED)ERROR: Certificate has expired: %s$(NC)\n" "$$EXP_DATE"; exit 1; \
	else \
		printf "$(GREEN)Certificate is valid until: %s$(NC)\n" "$$EXP_DATE"; \
	fi
	@printf "\n\033[0;37m%s\033[0m\n" "------ Checking required domains in certificate (SAN) ------"
	@printf "Checking required domains in certificate (SAN)...\n"
	@printf "Certificate SANs found:\n"
	@CERT_DOMAINS=$$(openssl x509 -in $(FULLCHAIN) -noout -text | \
	  awk '/X509v3 Subject Alternative Name/ {getline; print}' | \
	  tr ',' '\n' | sed 's/^[[:space:]]*DNS://g' | sed 's/[[:space:]]*$$//'); \
	printf "%s\n" "$$CERT_DOMAINS"; \
	for dom in $(REQUIRED_DOMAINS); do \
	  echo "$$CERT_DOMAINS" > .san_tmp_domains; \
	  if grep -Fxq "$$dom" .san_tmp_domains; then \
	    printf "$(GREEN)  OK: %s covered$(NC)\n" "$$dom"; \
	  else \
	    printf "$(RED)ERROR: Certificate does not cover required domain: %s$(NC)\n" "$$dom"; rm -f .san_tmp_domains; exit 1; \
	  fi; \
	done; \
	rm -f .san_tmp_domains
	@printf "$(GREEN)All required domains are present in the certificate.$(NC)\n"
	@printf "$(GREEN)Certificate check: PASSED.$(NC)\n"

#------------------------------------------------------------------------------
# [ ENVIRONMENT CHECK ] -------------------------------------------------------

.PHONY: check-env
check-env:
	@printf "\n\n\033[1;37m%s\033[0m\n" "=====================[ CHECKING ENVIRONMENT VARIABLES ]====================="
	@printf "Checking environment variables...\n"
ifeq ($(EMAIL_DISABLED),1)
	@printf "$(YELLOW)Email is disabled (EMAIL_ENABLED=$(EMAIL_ENABLED_VALUE)): EMAIL_* variables are not required.$(NC)\n"
endif
	@v='$(EMAIL_ENABLED_RAW)'; \
	if [ -n "$$v" ] && ! printf '%s\n' $(EMAIL_BOOL_OK) | grep -qx -- "$$v"; then \
		printf "$(RED)ERROR: EMAIL_ENABLED='%s' is not a boolean both the cloud and Grafana read the same way.$(NC)\n" "$$v"; \
		printf "$(YELLOW)Spellings like 'ok' or 'Y' switch email on for the cloud while Grafana alerts stay silent. Use True or False.$(NC)\n"; \
		exit 1; \
	fi
	@r="$$(bash scripts/env.sh getraw METRICS_RETENTION_DAYS | tr -d '\"')"; \
	r="$${r#"$${r%%[![:space:]]*}"}"; r="$${r%"$${r##*[![:space:]]}"}"; \
	if [ -n "$$r" ] && ! { printf '%s' "$$r" | grep -qE '^[0-9]+$$' && [ "$$r" -ge 1 ] && [ "$$r" -le 3650 ]; }; then \
		printf "$(RED)ERROR: METRICS_RETENTION_DAYS='%s' — the metrics store takes a whole number of days from 1 to 3650.$(NC)\n" "$$r"; \
		printf "$(YELLOW)It is written into the store as a constraint: an out-of-range value makes every metric insert fail.$(NC)\n"; \
		printf "$(YELLOW)There is no 'keep forever' value — leave the variable out to take the default of 30 days.$(NC)\n"; \
		exit 1; \
	fi
	@if [ ! -f $(ENV_FILE) ]; then \
		printf "$(RED)ERROR: File %s not found. Please create it based on %s.$(NC)\n" "$(ENV_FILE)" "$(ENV_EXAMPLE)"; exit 1; \
	fi
	@bad=0; \
	for var in $(URL_CRED_VARS); do \
		val="$$(bash scripts/env.sh getraw "$$var" | tr -d '\"')"; \
		[ -n "$$val" ] || continue; \
		why=""; \
		printf '%s' "$$val" | grep -q '[]/?#[]' && why="one of ] / ? # ["; \
		printf '%s' "$$val" | grep -q '[[:space:]]' && why="a space"; \
		printf '%s' "$$val" | grep -qE '%[0-9A-Fa-f][0-9A-Fa-f]' && why="a percent escape (it decodes into another character)"; \
		case "$$var" in *_USER) printf '%s' "$$val" | grep -q ':' && why="a colon";; esac; \
		if [ -n "$$why" ]; then \
			printf "$(RED)ERROR: %s contains %s — it goes into a credential URL and would break it.$(NC)\n" "$$var" "$$why"; \
			bad=1; \
		fi; \
	done; \
	[ $$bad -eq 0 ] || exit 1
	@result=0; \
	for var in $(REQUIRED_VARS); do \
		if ! grep -Eq '^[[:space:]]*'$${var}'=' $(ENV_FILE); then \
			printf "$(RED)ERROR: Required variable '%s' is missing or commented out in %s.$(NC)\n" "$${var}" "$(ENV_FILE)"; \
			result=1; \
		elif [ -z "$$(bash scripts/env.sh get "$$var")" ] \
		     && ! printf '%s\n' $(ALLOW_EMPTY_VARS) | grep -qx "$${var}"; then \
			printf "$(RED)ERROR: Required variable '%s' is empty in %s — set a value.$(NC)\n" "$${var}" "$(ENV_FILE)"; \
			result=1; \
		fi; \
	done; \
	if [ $$result -eq 0 ]; then \
		printf "$(GREEN)All required variables are present.$(NC)\n"; \
	else \
		if grep -Eq '$(LEGACY_RE)' $(ENV_FILE); then \
			printf "$(YELLOW)This .env looks like a 1.x one. Do NOT patch it by hand — run 'make upgrade':$(NC)\n"; \
			printf "$(YELLOW)it migrates the configuration, backs the database up and repairs the accounts first.$(NC)\n"; \
		else \
			printf "$(YELLOW)Variables introduced by a newer release are listed in %s — copy the missing ones over and set your own values.$(NC)\n" "$(ENV_EXAMPLE)"; \
			printf "$(YELLOW)Secrets and passwords are not listed there: 'make generate-env' creates them.$(NC)\n"; \
		fi; \
		exit 1; \
	fi

#------------------------------------------------------------------------------
# [ TOKENS AND SECRETS GENERATION ] -------------------------------------------
# Each target prints status before and after execution.

define gen_token
	@VAR_NAME="$1"; \
	NEW_VALUE=$$($2); \
	if grep -Eq "^$${VAR_NAME}=" "$(ENV_FILE)"; then \
		printf "\n$(YELLOW)%s already exists. Skipped.$(NC)\n" "$${VAR_NAME}"; \
	else \
		{ echo ""; echo "$${VAR_NAME}=$${NEW_VALUE}"; } >> "$(ENV_FILE)"; \
		printf "\n$(GREEN)%s generated and added to %s.$(NC)\n" "$${VAR_NAME}" "$(ENV_FILE)"; \
	fi
endef

.PHONY: generate-tunnel-token
generate-tunnel-token:
	@printf "\n\033[0;37m%s\033[0m\n" "------ Generating SSH/HTTP tunnel token ------"
	$(call gen_token,TUNNEL_AUTH_TOKEN,openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 64)

# Alphanumeric only: TIMESCALE_PASSWORD goes into a connection URL, the other two
# into the SQL that creates the roles.
.PHONY: generate-metrics-passwords
generate-metrics-passwords:
	@printf "\n\033[0;37m%s\033[0m\n" "------ Generating metrics store passwords ------"
	$(call gen_token,TIMESCALE_PASSWORD,openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 48)
	$(call gen_token,TELEGRAF_TIMESCALE_PASSWORD,openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 48)
	$(call gen_token,GRAFANA_TIMESCALE_PASSWORD,openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 48)

.PHONY: generate-django-secret
generate-django-secret:
	@printf "\n\033[0;37m%s\033[0m\n" "------ Generating Django secret ------"
	$(call gen_token,SECRET_KEY,openssl rand -base64 50 | tr -dc 'A-Za-z0-9!@#$%^&*(-_=+)' | cut -c1-50)

.PHONY: generate-absolute-server-regex
generate-absolute-server-regex:
	@printf "\n\033[0;37m%s\033[0m\n" "------ Generating ABSOLUTE_SERVER_REGEX ------"
	@ABSOLUTE_SERVER=$$(bash scripts/env.sh get ABSOLUTE_SERVER); \
	if [ -z "$$ABSOLUTE_SERVER" ]; then \
		printf "\n$(RED)ERROR: ABSOLUTE_SERVER variable is missing.$(NC)\n"; exit 1; \
	fi; \
	ABSOLUTE_SERVER_REGEX=$$(printf '%s' "$$ABSOLUTE_SERVER" | sed -e 's/[.[\*^$$()+?{}|\\]/\\\\&/g'); \
	if grep -q '^ABSOLUTE_SERVER_REGEX=' $(ENV_FILE); then \
		sed -i "s|^ABSOLUTE_SERVER_REGEX=.*|ABSOLUTE_SERVER_REGEX=$$ABSOLUTE_SERVER_REGEX|" $(ENV_FILE); \
		printf "\n$(YELLOW)ABSOLUTE_SERVER_REGEX updated in %s.$(NC)\n" "$(ENV_FILE)"; \
	else \
		{ echo ""; echo "ABSOLUTE_SERVER_REGEX=$$ABSOLUTE_SERVER_REGEX"; } >> $(ENV_FILE); \
		printf "\n$(GREEN)ABSOLUTE_SERVER_REGEX generated and added to %s.$(NC)\n" "$(ENV_FILE)"; \
	fi

.PHONY: generate-jwt
generate-jwt:
	@printf "\n\033[0;37m%s\033[0m\n" "------ Generating JWT keypair ------"
	@bash ./jwt/update_keys.sh && printf "\n$(GREEN)JWT keypair generated or already valid.$(NC)\n"

# DB-IP publishes a new database monthly; the automatic download only fetches a
# missing one, so refreshing is a deliberate step.
.PHONY: update-geoip
update-geoip:
	@printf "\n\n\033[1;37m%s\033[0m\n" "=====================[ UPDATING GEOLOCATION DATABASE ]====================="
	@bash ./scripts/fetch-geoip.sh --force

.PHONY: generate-env
generate-env:
	@printf  "\n\n\033[1;37m%s\033[0m\n" "=====================[ GENERATING SECRETS AND ENVIRONMENT VARIABLES ]====================="
	@${MAKE} generate-tunnel-token
	@${MAKE} generate-metrics-passwords
	@${MAKE} generate-django-secret
	@${MAKE} generate-absolute-server-regex
	@${MAKE} generate-jwt
	@bash ./scripts/fetch-geoip.sh
	@${MAKE} check-env
	@printf "\n\n$(GREEN)All secrets and environment variables are ready.$(NC)\n"

#------------------------------------------------------------------------------
# [ METRICS SCHEMA ] ----------------------------------------------------------

# The one-shot that re-applies the metrics schema fails quietly: `compose up`
# reports success as long as the container started. A schema left unapplied shows
# up much later, as metrics that quietly stopped arriving.
.PHONY: check-metrics-schema
check-metrics-schema:
	@cid="$$(VERSION=$(VERSION) docker compose ps -aq timescale-init 2>/dev/null | head -1)"; \
	[ -n "$$cid" ] || exit 0; \
	code="$$(timeout 600 docker wait "$$cid" 2>/dev/null)" || code=timeout; \
	if [ "$$code" = "0" ]; then \
		printf "$(GREEN)Metrics schema applied.$(NC)\n"; \
	else \
		printf "$(RED)ERROR: the metrics schema was not applied (timescale-init: $$code).$(NC)\n"; \
		printf "$(YELLOW)The stack is up, but the metrics store did not get this release's schema —$(NC)\n"; \
		printf "$(YELLOW)metrics may stop arriving without any other sign. See what happened:$(NC)\n"; \
		printf "$(YELLOW)  docker compose logs timescale-init$(NC)\n"; \
		exit 1; \
	fi

#------------------------------------------------------------------------------
# [ COMPOSITE TARGETS ] -------------------------------------------------------

.PHONY: run
run:
	@printf "\n\n\033[1;37m%s\033[0m\n" "=====================[ LAUNCHING DOCKER COMPOSE ]====================="
	@$(call require_version)
	@${MAKE} check-not-1x
	@${MAKE} generate-env
	@${MAKE} check-certs
	@VERSION=$(VERSION) docker compose up -d --build
	@${MAKE} check-metrics-schema

.PHONY: run-no-cert-check
run-no-cert-check:
	@printf "\n\n\033[1;37m%s\033[0m\n" "=====================[ LAUNCHING DOCKER COMPOSE (NO CERT CHECK) ]====================="
	@$(call require_version)
	@${MAKE} check-not-1x
	@${MAKE} generate-env
	@${MAKE} check-cert-paths
	@VERSION=$(VERSION) docker compose up -d --build
	@${MAKE} check-metrics-schema

.PHONY: update
update:
	@printf "\n\n\033[1;37m%s\033[0m\n" "=====================[ UPDATING IMAGES AND RESTARTING CONTAINERS ]====================="
	@$(call require_version)
	@${MAKE} check-not-1x
	@${MAKE} generate-env
	@${MAKE} check-certs
	@VERSION=$(VERSION) docker compose down
	docker image prune -f
	docker container prune -f
	@VERSION=$(VERSION) docker compose pull
	@VERSION=$(VERSION) docker compose up -d --build
	@${MAKE} check-metrics-schema

.PHONY: stop
stop:
	@printf "\n\n\033[1;37m%s\033[0m\n" "=====================[ STOPPING CONTAINERS ]====================="
	@$(call require_version)
	@VERSION=$(VERSION) docker compose down

.PHONY: restart
restart:
	@printf "\n\n\033[1;37m%s\033[0m\n" "=====================[ RESTARTING CONTAINERS ]====================="
	@$(call require_version)
	@${MAKE} check-not-1x
	@${MAKE} generate-env
	@${MAKE} check-certs
	@export VERSION=$(VERSION); docker compose down && docker compose up -d --build
	@${MAKE} check-metrics-schema

# Traefik reads the certificate files once at startup, so a renewed certificate
# needs it restarted — only it, the rest of the stack keeps serving.
.PHONY: reload-certs
reload-certs:
	@printf "\n\n\033[1;37m%s\033[0m\n" "=====================[ RELOADING CERTIFICATES ]====================="
	@$(call require_version)
	@${MAKE} check-certs
	@VERSION=$(VERSION) docker compose restart traefik

#------------------------------------------------------------------------------
# [ 1.x -> 2.x UPGRADE ] ------------------------------------------------------
# Thin wrappers over migration/upgrade.sh; both go away once 1.x is unsupported.

MODE ?= scan

.PHONY: backup
backup:
	@printf "\n\n\033[1;37m%s\033[0m\n" "=====================[ BACKUP ]====================="
	@$(call require_version)
	@bash ./migration/upgrade.sh backup

# MODE=scan (read-only) | auto (safe fixes) | resolve (wizard) | dump / apply (edit conflicts.yaml)
.PHONY: fix-users
fix-users:
	@printf "\n\n\033[1;37m%s\033[0m\n" "=====================[ migration_doctor: $(MODE) ]====================="
	@$(call require_version)
	@bash ./migration/upgrade.sh fix-users $(MODE)

.PHONY: upgrade
upgrade:
	@printf "\n\n\033[1;37m%s\033[0m\n" "=====================[ 1.x -> 2.x UPGRADE ]====================="
	@$(call require_version)
	@bash ./migration/upgrade.sh upgrade
