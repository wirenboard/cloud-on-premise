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
  EMAIL_HOST_USER \
  EMAIL_HOST_PASSWORD \
  EMAIL_HOST \
  EMAIL_PORT \
  EMAIL_NOTIFICATIONS_FROM \
  ADMIN_EMAIL \
  ADMIN_PASSWORD \
  TIMESCALE_USER \
  TIMESCALE_PASSWORD \
  TIMESCALE_DB \
  TUNNEL_DASHBOARD_USER \
  TUNNEL_DASHBOARD_PASSWORD \
  TUNNEL_DASHBOARD_PORT \
  TUNNEL_PORT \
  POSTGRES_USER \
  POSTGRES_PASSWORD \
  POSTGRES_DB \
  TELEGRAF_TIMESCALE_USER \
  TELEGRAF_TIMESCALE_PASSWORD \
  TELEGRAF_INPUT_PORT \
  TUNNEL_AUTH_TOKEN \
  SECRET_KEY \


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
	@printf "  check-jwt                Check JWT RSA key files\n"
	@printf "  generate-env             Generate all secrets and variables (non-destructive)\n"
	@printf "  run                      Full project launch: generate-env, check-certs, start containers\n"
	@printf "  update                   Update images, rebuild and start\n"
	@printf "  generate-jwt-keys        Generate JWT RSA key file pair\n"
	@printf "  generate-tunnel-token    Generate SSH/HTTP tunnel token\n"
	@printf "  generate-django-secret   Generate Django secret key\n\n"

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

.PHONY: check-jwt
check-jwt:
	@printf "\n\033[0;37m%s\033[0m\n" "------ Checking JWT RSA keys ------"
	@set -e; \
	if [ ! -f jwt/private.pem ]; then \
		echo ""; \
		echo "$(RED)ERROR: JWT private key not found: jwt/private.pem$(NC)"; \
		exit 1; \
	fi; \
	if [ ! -f jwt/public.pem ]; then \
		echo ""; \
		echo "$(RED)ERROR: JWT public key not found: jwt/public.pem$(NC)"; \
		exit 1; \
	fi; \
	if ! openssl rsa -in jwt/private.pem -check -noout >/dev/null 2>&1; then \
		echo ""; \
		echo "$(RED)ERROR: Invalid JWT private key$(NC)"; \
		exit 1; \
	fi; \
	priv_mod=$$(openssl rsa -in jwt/private.pem -noout -modulus 2>/dev/null); \
	pub_mod=$$(openssl rsa -pubin -in jwt/public.pem -noout -modulus 2>/dev/null); \
	if [ "$$priv_mod" != "$$pub_mod" ]; then \
		echo ""; \
		echo "$(RED)ERROR: JWT public key does NOT match private key$(NC)"; \
		echo ""; \
		exit 1; \
	fi; \
	echo "$(GREEN)OK: JWT RSA keys are valid$(NC)"

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

.PHONY: generate-jwt-keys
generate-jwt-keys:
	@printf "\n\033[0;37m%s\033[0m\n" "------ Generating JWT key files ------"
	@mkdir -p jwt
	@openssl genrsa -out jwt/private.pem 2048
	@openssl rsa -in jwt/private.pem -pubout -out jwt/public.pem
	@printf "$(GREEN)Generated JWT RSA key pair in 'jwt' directory$(NC)\n"

.PHONY: generate-env
generate-env:
	@printf  "\n\n\033[1;37m%s\033[0m\n" "=====================[ GENERATING SECRETS AND ENVIRONMENT VARIABLES ]====================="
	@${MAKE} generate-tunnel-token
	@${MAKE} generate-django-secret
	@${MAKE} check-env
	@printf "\n\n$(GREEN)All secrets and environment variables are ready.$(NC)\n"

#------------------------------------------------------------------------------
# [ COMPOSITE TARGETS ] -------------------------------------------------------

.PHONY: run
run:
	@${MAKE} generate-env
	@${MAKE} check-certs
	@${MAKE} check-jwt
	@VERSION=$$(cat VERSION) docker compose up -d --build

.PHONY: run-no-cert-check
run-no-cert-check:
	@${MAKE} generate-env
	@${MAKE} check-jwt
	@VERSION=$$(cat VERSION) docker compose up -d --build

.PHONY: update
update:
	@printf "\n\n\033[1;37m%s\033[0m\n" "=====================[ UPDATING IMAGES AND RESTARTING CONTAINERS ]====================="
	@VERSION=$$(cat VERSION) docker compose down
	@VERSION=$$(cat VERSION) docker image prune -f
	@VERSION=$$(cat VERSION) docker container prune -f
	@VERSION=$$(cat VERSION) docker compose pull
	@${MAKE} generate-env
	@VERSION=$$(cat VERSION) docker compose up -d --build

