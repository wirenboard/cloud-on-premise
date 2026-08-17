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

#----- [ REQUIRED ENVIRONMENT VARIABLES ] -------------------------------------

# EMAIL_ENABLED is mandatory since 2.0 (REQUIRED_VARS + compose fail-fast).
# False/Off/No/0 (case-insensitive) disables email and makes EMAIL_* optional.
EMAIL_ENABLED_VALUE := $(shell grep -E '^[[:space:]]*EMAIL_ENABLED=' $(ENV_FILE) 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '[:space:]"' | tr '[:upper:]' '[:lower:]')
EMAIL_DISABLED := $(if $(filter $(EMAIL_ENABLED_VALUE),false off no 0),1,0)

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
  PUBLIC_KEY

ifeq ($(EMAIL_DISABLED),0)
REQUIRED_VARS += $(EMAIL_REQUIRED_VARS)
endif

# Empty is a legitimate answer here: a relay that takes mail without authentication.
ALLOW_EMPTY_VARS := EMAIL_HOST_USER EMAIL_HOST_PASSWORD

#----- [ DOMAIN & CERTIFICATES ] ----------------------------------------------

RAW_SERVER      := $(shell grep -E '^ABSOLUTE_SERVER=' $(ENV_FILE) | head -1 | cut -d= -f2- | tr -d '[:space:]')
BASE_DOMAIN     := $(shell echo $(RAW_SERVER) | sed -E 's@https?://@@;s@/.*@@' | cut -d':' -f1)

TLS_DIR         := $(or $(TLS_CERTS_PATH),$(shell grep ^TLS_CERTS_PATH $(ENV_FILE) | cut -d= -f2 | tr -d '[:space:]'))
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
	@v="$(EMAIL_ENABLED_VALUE)"; \
	if [ -n "$$v" ]; then case "$$v" in \
	  true|on|ok|y|yes|1|false|off|no|0) ;; \
	  *) printf "$(RED)ERROR: EMAIL_ENABLED='%s' is not a recognized boolean — the backend would silently disable email. Use True or False.$(NC)\n" "$$v"; exit 1;; \
	esac; fi
	@if [ ! -f $(ENV_FILE) ]; then \
		printf "$(RED)ERROR: File %s not found. Please create it based on %s.$(NC)\n" "$(ENV_FILE)" "$(ENV_EXAMPLE)"; exit 1; \
	fi
	@result=0; \
	for var in $(REQUIRED_VARS); do \
		if ! grep -Eq '^[[:space:]]*'$${var}'=' $(ENV_FILE); then \
			printf "$(RED)ERROR: Required variable '%s' is missing or commented out in %s.$(NC)\n" "$${var}" "$(ENV_FILE)"; \
			result=1; \
		elif [ -z "$$(grep -E '^[[:space:]]*'$${var}'=' $(ENV_FILE) | tail -1 | cut -d= -f2- | tr -d '[:space:]\"')" ] \
		     && ! printf '%s\n' $(ALLOW_EMPTY_VARS) | grep -qx "$${var}"; then \
			printf "$(RED)ERROR: Required variable '%s' is empty in %s — set a value.$(NC)\n" "$${var}" "$(ENV_FILE)"; \
			result=1; \
		fi; \
	done; \
	if [ $$result -eq 0 ]; then \
		printf "$(GREEN)All required variables are present.$(NC)\n"; \
	else \
		if grep -Eq '^[[:space:]]*(INFLUXDB_TOKEN|ADMIN_USERNAME|EMAIL_PROTOCOL)=' $(ENV_FILE); then \
			printf "$(YELLOW)This .env looks like a 1.x one. Do NOT patch it by hand — run 'make upgrade':$(NC)\n"; \
			printf "$(YELLOW)it migrates the configuration, backs the database up and repairs the accounts first.$(NC)\n"; \
		else \
			printf "$(YELLOW)Variables introduced by a newer release are listed in %s — copy the missing ones over and set your own values.$(NC)\n" "$(ENV_EXAMPLE)"; \
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

.PHONY: generate-django-secret
generate-django-secret:
	@printf "\n\033[0;37m%s\033[0m\n" "------ Generating Django secret ------"
	$(call gen_token,SECRET_KEY,openssl rand -base64 50 | tr -dc 'A-Za-z0-9!@#$%^&*(-_=+)' | cut -c1-50)

.PHONY: generate-absolute-server-regex
generate-absolute-server-regex:
	@printf "\n\033[0;37m%s\033[0m\n" "------ Generating ABSOLUTE_SERVER_REGEX ------"
	@ABSOLUTE_SERVER=$$(grep -E '^[[:space:]]*ABSOLUTE_SERVER=' $(ENV_FILE) | cut -d= -f2-); \
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
	@${MAKE} generate-django-secret
	@${MAKE} generate-absolute-server-regex
	@${MAKE} generate-jwt
	@bash ./scripts/fetch-geoip.sh
	@${MAKE} check-env
	@printf "\n\n$(GREEN)All secrets and environment variables are ready.$(NC)\n"

#------------------------------------------------------------------------------
# [ COMPOSITE TARGETS ] -------------------------------------------------------

.PHONY: run
run:
	@printf "\n\n\033[1;37m%s\033[0m\n" "=====================[ LAUNCHING DOCKER COMPOSE ]====================="
	@$(call require_version)
	@${MAKE} generate-env
	@${MAKE} check-certs
	@VERSION=$(VERSION) docker compose up -d --build

.PHONY: run-no-cert-check
run-no-cert-check:
	@printf "\n\n\033[1;37m%s\033[0m\n" "=====================[ LAUNCHING DOCKER COMPOSE (NO CERT CHECK) ]====================="
	@$(call require_version)
	@${MAKE} generate-env
	@${MAKE} check-cert-paths
	@VERSION=$(VERSION) docker compose up -d --build

.PHONY: update
update:
	@printf "\n\n\033[1;37m%s\033[0m\n" "=====================[ UPDATING IMAGES AND RESTARTING CONTAINERS ]====================="
	@$(call require_version)
	@${MAKE} generate-env
	@${MAKE} check-certs
	@VERSION=$(VERSION) docker compose down
	docker image prune -f
	docker container prune -f
	@VERSION=$(VERSION) docker compose pull
	@VERSION=$(VERSION) docker compose up -d --build

.PHONY: stop
stop:
	@printf "\n\n\033[1;37m%s\033[0m\n" "=====================[ STOPPING CONTAINERS ]====================="
	@$(call require_version)
	@VERSION=$(VERSION) docker compose down

.PHONY: restart
restart:
	@printf "\n\n\033[1;37m%s\033[0m\n" "=====================[ RESTARTING CONTAINERS ]====================="
	@$(call require_version)
	@${MAKE} generate-env
	@${MAKE} check-certs
	@export VERSION=$(VERSION); docker compose down && docker compose up -d --build

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
# Thin wrappers over scripts/upgrade.sh; both go away once 1.x is unsupported.

MODE ?= scan

.PHONY: backup
backup:
	@printf "\n\n\033[1;37m%s\033[0m\n" "=====================[ BACKUP ]====================="
	@$(call require_version)
	@bash ./scripts/upgrade.sh backup

# MODE=scan (read-only) | auto (safe fixes) | resolve (wizard) | dump / apply (edit conflicts.yaml)
.PHONY: fix-users
fix-users:
	@printf "\n\n\033[1;37m%s\033[0m\n" "=====================[ migration_doctor: $(MODE) ]====================="
	@$(call require_version)
	@bash ./scripts/upgrade.sh fix-users $(MODE)

.PHONY: upgrade
upgrade:
	@printf "\n\n\033[1;37m%s\033[0m\n" "=====================[ 1.x -> 2.x UPGRADE ]====================="
	@$(call require_version)
	@bash ./scripts/upgrade.sh upgrade
