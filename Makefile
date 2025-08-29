#------------------------------------------------------------------------------
# Wirenboard On-Premise - Makefile (Production, Colorful & Informative Output)
#------------------------------------------------------------------------------

MAKEFLAGS += --no-print-directory

RED   = \033[0;31m
YELLOW= \033[1;33m
GREEN = \033[0;32m
NC    = \033[0m  # No Color

ENV_FILE      := .env
ENV_EXAMPLE   := .env.example
PYTHON_BIN    := python3

#----- [ REQUIRED ENVIRONMENT VARIABLES ] -------------------------------------

REQUIRED_VARS := \
  ABSOLUTE_SERVER \
  EMAIL_PROTOCOL \
  EMAIL_LOGIN \
  EMAIL_PASSWORD \
  EMAIL_SERVER \
  EMAIL_PORT \
  EMAIL_NOTIFICATIONS_FROM \
  ADMIN_EMAIL \
  ADMIN_USERNAME \
  ADMIN_PASSWORD \
  INFLUXDB_USERNAME \
  INFLUXDB_PASSWORD \
  TUNNEL_DASHBOARD_USER \
  TUNNEL_DASHBOARD_PASSWORD \
  TUNNEL_DASHBOARD_PORT \
  TUNNEL_PORT \
  POSTGRES_USER \
  POSTGRES_PASSWORD \
  POSTGRES_DB \
  TUNNEL_AUTH_TOKEN \
  INFLUXDB_TOKEN \
  SECRET_KEY \
  ABSOLUTE_SERVER_REGEX \
  EMAIL_URL \
  PRIVATE_KEY \
  PUBLIC_KEY

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
	@printf "  update                   Update images, rebuild and start\n"
	@printf "  generate-jwt             Generate/update keys for JWT\n"
	@printf "  generate-tunnel-token    Generate SSH/HTTP tunnel token\n"
	@printf "  generate-influx-token    Generate Influx token\n"
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
	rm -f .san_tmp_domains
	@printf "$(GREEN)All required domains are present in the certificate.$(NC)\n"
	@printf "$(GREEN)Certificate check: PASSED.$(NC)\n"

#------------------------------------------------------------------------------
# [ ENVIRONMENT CHECK ] -------------------------------------------------------

.PHONY: check-env
check-env:
	@printf "\n\n\033[1;37m%s\033[0m\n" "=====================[ CHECKING ENVIRONMENT VARIABLES ]====================="
	@printf "Checking environment variables...\n"
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

.PHONY: generate-influx-token
generate-influx-token:
	@printf "\n\033[0;37m%s\033[0m\n" "------ Generating Influx token ------"
	$(call gen_token,INFLUXDB_TOKEN,openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 64)

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

.PHONY: generate-jwt
generate-jwt:
	@printf "\n\033[0;37m%s\033[0m\n" "------ Generating JWT keypair ------"
	@bash ./jwt/update_keys.sh && printf "\n$(GREEN)JWT keypair generated or already valid.$(NC)\n"

.PHONY: generate-env
generate-env:
	@printf  "\n\n\033[1;37m%s\033[0m\n" "=====================[ GENERATING SECRETS AND ENVIRONMENT VARIABLES ]====================="
	@${MAKE} generate-tunnel-token
	@${MAKE} generate-influx-token
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
	@${MAKE} generate-env
	@${MAKE} check-certs
	@export VERSION=$$(cat VERSION)
	docker compose up -d --build

.PHONY: run-no-cert-check
run-no-cert-check:
	@${MAKE} generate-env
	@export VERSION=$$(cat VERSION)
	docker compose up -d --build

.PHONY: update
update:
	@printf "\n\n\033[1;37m%s\033[0m\n" "=====================[ UPDATING IMAGES AND RESTARTING CONTAINERS ]====================="
	docker compose down
	docker image prune -f
	docker container prune -f
	docker compose pull
	@${MAKE} generate-env
	@export VERSION=$$(cat VERSION)
	docker compose up -d --build

