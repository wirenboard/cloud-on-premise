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
PYTHON_BIN    := python3

#----- [ REQUIRED ENVIRONMENT VARIABLES ] -------------------------------------

# EMAIL_ENABLED is mandatory in 2.0 (REQUIRED_VARS + compose fail-fast).
# False/Off/No/0 (case-insensitive) disables email: EMAIL_* variables become
# optional and EMAIL_URL generation is skipped; True/On/Yes/1 enables it.
EMAIL_ENABLED_VALUE := $(shell grep -E '^[[:space:]]*EMAIL_ENABLED=' $(ENV_FILE) 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '[:space:]"' | tr '[:upper:]' '[:lower:]')
EMAIL_DISABLED := $(if $(filter $(EMAIL_ENABLED_VALUE),false off no 0),1,0)

EMAIL_REQUIRED_VARS := \
  EMAIL_PROTOCOL \
  EMAIL_LOGIN \
  EMAIL_PASSWORD \
  EMAIL_SERVER \
  EMAIL_PORT \
  EMAIL_NOTIFICATIONS_FROM \
  EMAIL_URL

REQUIRED_VARS := \
  ABSOLUTE_SERVER \
  EMAIL_ENABLED \
  ADMIN_EMAIL \
  ADMIN_USERNAME \
  ADMIN_PASSWORD \
  TUNNEL_DASHBOARD_USER \
  TUNNEL_DASHBOARD_PASSWORD \
  POSTGRES_USER \
  POSTGRES_PASSWORD \
  POSTGRES_DB \
  TIMESCALE_USER \
  TIMESCALE_PASSWORD \
  TIMESCALE_DB \
  TELEGRAF_TIMESCALE_USER \
  TELEGRAF_TIMESCALE_PASSWORD \
  GRAFANA_TIMESCALE_USER \
  GRAFANA_TIMESCALE_PASSWORD \
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

#----- [ DOMAIN & CERTIFICATES ] ----------------------------------------------

RAW_SERVER      := $(shell grep -E '^ABSOLUTE_SERVER=' $(ENV_FILE) | head -1 | cut -d= -f2- | tr -d '[:space:]')
BASE_DOMAIN     := $(shell echo $(RAW_SERVER) | sed -E 's@https?://@@;s@/.*@@' | cut -d':' -f1)

TLS_DIR         := $(or $(TLS_CERTS_PATH),$(shell grep ^TLS_CERTS_PATH $(ENV_FILE) | cut -d= -f2 | tr -d '[:space:]'))
TLS_DIR         := $(or $(TLS_DIR),./tls)

FULLCHAIN       := $(TLS_DIR)/fullchain.pem
CERT            := $(TLS_DIR)/cert.pem
CHAIN           := $(TLS_DIR)/chain.pem
PRIVKEY         := $(TLS_DIR)/privkey.pem

REQUIRED_DOMAINS := $(BASE_DOMAIN) *.$(BASE_DOMAIN) *.ssh.$(BASE_DOMAIN) *.http.$(BASE_DOMAIN)

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
	@printf "  upgrade                  1.x -> 2.0 upgrade: backup, fix users, migrate, start\n"
	@printf "  fix-users                Run migration_doctor (MODE=scan|auto|resolve|dump|apply)\n"
	@printf "  backup                   Back up PostgreSQL (+ InfluxDB if present) into ./backups\n"
	@printf "  generate-jwt             Generate/update keys for JWT\n"
	@printf "  generate-tunnel-token    Generate SSH/HTTP tunnel token\n"
	@printf "  generate-metrics-secrets Generate TimescaleDB/Telegraf/Grafana secrets\n"
	@printf "  generate-django-secret   Generate Django secret key\n\n"
	@printf "  generate-email-url       Generate/update Email URL"

#------------------------------------------------------------------------------
# [ TLS CERTIFICATE CHECK ] ---------------------------------------------------

.PHONY: check-certs
check-certs:
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
	if ! grep -Fxq "*.apps.$(BASE_DOMAIN)" .san_tmp_domains; then \
	  printf "$(YELLOW)NOTE: certificate does not cover *.apps.$(BASE_DOMAIN) — controller web services (apps tunnels) will not work. This is optional, see README.$(NC)\n"; \
	fi; \
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
		fi; \
	done; \
	if [ $$result -eq 0 ]; then \
		printf "$(GREEN)All required variables are present.$(NC)\n"; \
	else \
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

.PHONY: generate-metrics-secrets
generate-metrics-secrets:
	@printf "\n\033[0;37m%s\033[0m\n" "------ Generating metrics DB secrets (TimescaleDB / Telegraf / Grafana) ------"
	$(call gen_token,TIMESCALE_USER,echo timescale)
	$(call gen_token,TIMESCALE_DB,echo metrics)
	$(call gen_token,TELEGRAF_TIMESCALE_USER,echo telegraf)
	$(call gen_token,GRAFANA_TIMESCALE_USER,echo grafana)
	$(call gen_token,GRAFANA_ADMIN_USER,echo grafana_admin)
	$(call gen_token,TIMESCALE_PASSWORD,openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 48)
	$(call gen_token,TELEGRAF_TIMESCALE_PASSWORD,openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 48)
	$(call gen_token,GRAFANA_TIMESCALE_PASSWORD,openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 48)
	$(call gen_token,GRAFANA_ADMIN_PASSWORD,openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32)

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

.PHONY: generate-email-url
generate-email-url:
	@printf "\n\033[0;37m%s\033[0m\n" "------ Generating EMAIL_URL ------"
ifeq ($(EMAIL_DISABLED),1)
	@printf "$(YELLOW)Email is disabled (EMAIL_ENABLED=$(EMAIL_ENABLED_VALUE)). Skipping EMAIL_URL generation.$(NC)\n"
else
	@EMAIL_PROTOCOL=$$(grep -E '^[[:space:]]*EMAIL_PROTOCOL=' $(ENV_FILE) | cut -d= -f2-); \
	EMAIL_LOGIN=$$(grep -E '^[[:space:]]*EMAIL_LOGIN=' $(ENV_FILE) | cut -d= -f2-); \
	EMAIL_PASSWORD=$$(grep -E '^[[:space:]]*EMAIL_PASSWORD=' $(ENV_FILE) | cut -d= -f2-); \
	EMAIL_SERVER=$$(grep -E '^[[:space:]]*EMAIL_SERVER=' $(ENV_FILE) | cut -d= -f2-); \
	EMAIL_PORT=$$(grep -E '^[[:space:]]*EMAIL_PORT=' $(ENV_FILE) | cut -d= -f2-); \
	if [ -z "$$EMAIL_PROTOCOL" ] || [ -z "$$EMAIL_LOGIN" ] || [ -z "$$EMAIL_PASSWORD" ] || [ -z "$$EMAIL_SERVER" ] || [ -z "$$EMAIL_PORT" ]; then \
		printf "\n$(RED)ERROR: Not all email variables are set.$(NC)\n"; exit 1; \
	fi; \
	EMAIL_LOGIN_ENC=$$($(PYTHON_BIN) -c "import urllib.parse; print(urllib.parse.quote('$$EMAIL_LOGIN'))"); \
	EMAIL_PASSWORD_ENC=$$($(PYTHON_BIN) -c "import urllib.parse; print(urllib.parse.quote('$$EMAIL_PASSWORD'))"); \
	EMAIL_URL="$$EMAIL_PROTOCOL://$$EMAIL_LOGIN_ENC:$$EMAIL_PASSWORD_ENC@$$EMAIL_SERVER:$$EMAIL_PORT"; \
	if grep -q '^EMAIL_URL=' $(ENV_FILE); then \
		sed -i "s|^EMAIL_URL=.*|EMAIL_URL=$$EMAIL_URL|" $(ENV_FILE); \
		printf "\n$(YELLOW)EMAIL_URL updated in %s.$(NC)\n" "$(ENV_FILE)"; \
	else \
		{ echo ""; echo "EMAIL_URL=$$EMAIL_URL"; } >> $(ENV_FILE); \
		printf "\n$(GREEN)EMAIL_URL generated and added to %s.$(NC)\n" "$(ENV_FILE)"; \
	fi
endif

.PHONY: generate-jwt
generate-jwt:
	@printf "\n\033[0;37m%s\033[0m\n" "------ Generating JWT keypair ------"
	@bash ./jwt/update_keys.sh && printf "\n$(GREEN)JWT keypair generated or already valid.$(NC)\n"

.PHONY: generate-env
generate-env:
	@printf  "\n\n\033[1;37m%s\033[0m\n" "=====================[ GENERATING SECRETS AND ENVIRONMENT VARIABLES ]====================="
	@${MAKE} generate-tunnel-token
	@${MAKE} generate-metrics-secrets
	@${MAKE} generate-django-secret
	@${MAKE} generate-absolute-server-regex
	@${MAKE} generate-email-url
	@${MAKE} generate-jwt
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

#------------------------------------------------------------------------------
# [ 1.x -> 2.0 UPGRADE ] ------------------------------------------------------
#
# The 2.0 release makes the user `email` unique and adds a DB constraint that
# `username == email`. On a populated 1.x database the upstream migration
# `users/0013` aborts unless the data is repaired first. `make upgrade` does the
# whole thing safely: BACKUP -> scan for conflicts -> GATE (stop if any) ->
# migrate -> bring the 2.0 stack up. Nothing mutates the DB before the backup.
#------------------------------------------------------------------------------

BACKUP_DIR     := backups
MIGRATION_DIR  := migration
TS             := $(shell date +%Y%m%d-%H%M%S)
# The doctor runs inside the STILL-RUNNING (1.x) backend container via the Django
# shell, touching only username/email. `exec` if the backend is up, else `run`.
# The mode goes through sys.argv inside -c: Django's `shell` rejects trailing args.
DOCTOR_CMD     = uv run --no-dev ./manage.py shell -c "import sys; sys.argv = ['migration_doctor', '$(MODE)']; exec(open('/migration/migration_doctor.py').read())"

.PHONY: backup
backup:
	@printf "\n\n\033[1;37m%s\033[0m\n" "=====================[ BACKUP (PostgreSQL + InfluxDB) ]====================="
	@$(call require_version)
	@mkdir -p "$(BACKUP_DIR)"
	@printf "$(GRAY)------ PostgreSQL dump ------$(NC)\n" 2>/dev/null || printf "------ PostgreSQL dump ------\n"
	@POSTGRES_USER=$$(grep -E '^[[:space:]]*POSTGRES_USER=' $(ENV_FILE) | cut -d= -f2- | tr -d '[:space:]'); \
	POSTGRES_DB=$$(grep -E '^[[:space:]]*POSTGRES_DB=' $(ENV_FILE) | cut -d= -f2- | tr -d '[:space:]'); \
	out="$(BACKUP_DIR)/pg-$(TS).sql.gz"; \
	printf "Dumping database %s -> %s\n" "$$POSTGRES_DB" "$$out"; \
	VERSION=$(VERSION) docker compose exec -T postgres \
	  pg_dump -U "$$POSTGRES_USER" -d "$$POSTGRES_DB" | gzip > "$$out"; \
	if [ ! -s "$$out" ]; then \
	  printf "$(RED)ERROR: PostgreSQL backup is empty — aborting.$(NC)\n"; rm -f "$$out"; exit 1; \
	fi; \
	printf "$(GREEN)PostgreSQL backup written: %s$(NC)\n" "$$out"
	@printf "\n------ InfluxDB backup (only if a 1.x influx service is still running) ------\n"
	@svc=$$(VERSION=$(VERSION) docker compose ps --services 2>/dev/null | grep -xE 'influx(db)?' | head -1); \
	if [ -n "$$svc" ]; then \
	  out="$(BACKUP_DIR)/influx-$(TS)"; \
	  tok=$$(grep -E '^[[:space:]]*INFLUXDB_TOKEN=' $(ENV_FILE) | cut -d= -f2- | tr -d '[:space:]"'); \
	  printf "Backing up InfluxDB (%s) -> %s (kept for the operator; NOT converted to TimescaleDB)\n" "$$svc" "$$out"; \
	  VERSION=$(VERSION) docker compose exec -T "$$svc" influx backup /tmp/influx-backup -t "$$tok" || true; \
	  cid=$$(VERSION=$(VERSION) docker compose ps -q "$$svc"); \
	  mkdir -p "$$out"; \
	  docker cp "$$cid:/tmp/influx-backup/." "$$out/" 2>/dev/null || true; \
	  if [ -n "$$(ls -A "$$out" 2>/dev/null)" ]; then \
	    printf "$(GREEN)InfluxDB backup written: %s$(NC)\n" "$$out"; \
	  else \
	    printf "$(YELLOW)WARNING: InfluxDB backup is EMPTY — metrics history was NOT saved.$(NC)\n"; \
	    printf "$(YELLOW)Back up the 'influxData' docker volume manually if you need the history.$(NC)\n"; \
	  fi; \
	else \
	  printf "$(YELLOW)No running influx service found — skipping InfluxDB backup.$(NC)\n"; \
	  printf "(If you upgraded the metrics store earlier, the InfluxDB data was already handled.)\n"; \
	fi

# fix-users — run the migration_doctor. MODE defaults to scan (read-only).
#   make fix-users MODE=scan       # read-only conflict report
#   make fix-users MODE=auto       # apply safe auto-fixes
#   make fix-users MODE=resolve    # auto-fix + interactive wizard
#   make fix-users MODE=dump       # write migration/conflicts.yaml
#   make fix-users MODE=apply      # read migration/conflicts.yaml back
MODE ?= scan
.PHONY: fix-users
fix-users:
	@printf "\n\n\033[1;37m%s\033[0m\n" "=====================[ migration_doctor: $(MODE) ]====================="
	@$(call require_version)
	@if VERSION=$(VERSION) docker compose ps --services --filter status=running 2>/dev/null | grep -qx backend; then \
	  cid=$$(VERSION=$(VERSION) docker compose ps -q backend); \
	  docker cp "$(MIGRATION_DIR)" "$$cid:/"; \
	  VERSION=$(VERSION) docker compose exec backend $(DOCTOR_CMD); \
	  docker cp "$$cid:/migration/." "$(MIGRATION_DIR)/"; \
	else \
	  VERSION=$(VERSION) docker compose run --rm \
	    -v "$$PWD/$(MIGRATION_DIR):/migration" backend $(DOCTOR_CMD); \
	fi

.PHONY: upgrade
upgrade:
	@printf "\n\n\033[1;37m%s\033[0m\n" "=====================[ 1.x -> 2.0 UPGRADE ]====================="
	@$(call require_version)
	@if ! grep -Eq '^[[:space:]]*EMAIL_ENABLED=' $(ENV_FILE); then \
	  printf "$(YELLOW)EMAIL_ENABLED is not set — keeping the 1.x behaviour (True). Set it explicitly in %s.$(NC)\n" "$(ENV_FILE)"; \
	  { echo ""; echo "EMAIL_ENABLED=True"; } >> $(ENV_FILE); \
	fi
	@${MAKE} generate-env
	@${MAKE} check-certs
	@printf "\n$(YELLOW)Step 1/4: mandatory backup (before ANY DB change).$(NC)\n"
	@${MAKE} backup
	@printf "\n$(YELLOW)Step 2/4: scanning the user table for 2.0 conflicts.$(NC)\n"
	@if ! ${MAKE} fix-users MODE=scan; then \
	  printf "\n$(RED)Conflicts found — migration is BLOCKED.$(NC)\n"; \
	  printf "Resolve them, then re-run \`make upgrade\`:\n"; \
	  printf "  $(GREEN)make fix-users MODE=resolve$(NC)   (interactive wizard)\n"; \
	  printf "  $(GREEN)make fix-users MODE=dump$(NC) then edit $(MIGRATION_DIR)/conflicts.yaml then $(GREEN)make fix-users MODE=apply$(NC)\n"; \
	  printf "  ($(GREEN)make fix-users MODE=auto$(NC) applies the safe fixes automatically.)\n"; \
	  exit 1; \
	fi
	@printf "\n$(GREEN)No user conflicts. Proceeding.$(NC)\n"
	@printf "\n$(YELLOW)Step 3/4: applying database migrations on the 2.0 backend image.$(NC)\n"
	@VERSION=$(VERSION) docker compose pull
	@VERSION=$(VERSION) docker compose run --rm backend uv run --no-dev ./manage.py migrate
	@printf "\n$(YELLOW)Step 4/4: bringing up the 2.0 stack.$(NC)\n"
	@VERSION=$(VERSION) docker compose up -d --build
	@printf "\n$(GREEN)Upgrade to $(VERSION) complete.$(NC)\n"
