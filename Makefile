#------------------------------------------------------------------------------
# Wirenboard On-Premise - Makefile (Production Grade)
#------------------------------------------------------------------------------

ENV_FILE      := .env
ENV_EXAMPLE   := .env.example
PYTHON_BIN    := python3

REQUIRED_VARS := \
  ABSOLUTE_SERVER \
  EMAIL_PROTOCOP \
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

#------------------------------------------------------------------------------
# Help Section
#------------------------------------------------------------------------------

.PHONY: help
help:
	@echo ""
	@echo "Usage: make <target>"
	@echo ""
	@echo "Available targets:"
	@echo "  help                  Показать это сообщение"
	@echo "  init-env              Создать .env из .env.example, если отсутствует"
	@echo "  check-env             Проверить, что все обязательные переменные заданы"
	@echo "  generate-env          Сгенерировать все секреты и переменные (без перезаписи существующих)"
	@echo "  run                   Полный цикл запуска проекта, включая: generate-env, запуск контейнеров"
	@echo "  update                Обновить образы, пересобрать и запустить"
	@echo "  generate-jwt          Сгенерировать/обновить ключи для JWT"
	@echo ""

#------------------------------------------------------------------------------
# Utility Macros & Recipes
#------------------------------------------------------------------------------

define gen_token
	@VAR_NAME="$1"; \
	NEW_VALUE=$$($2); \
	if grep -Eq "^$${VAR_NAME}=" "$(ENV_FILE)"; then \
		echo "$${VAR_NAME} уже существует."; \
	else \
		{ echo ""; echo "$${VAR_NAME}=$${NEW_VALUE}"; } >> "$(ENV_FILE)"; \
		echo "$${VAR_NAME} добавлен в $(ENV_FILE)"; \
	fi
endef

#------------------------------------------------------------------------------
# Environment file management
#------------------------------------------------------------------------------

.PHONY: init-env
init-env:
	@if [ ! -f $(ENV_FILE) ]; then \
		if [ -f $(ENV_EXAMPLE) ]; then \
			cp $(ENV_EXAMPLE) $(ENV_FILE); \
			echo ".env создан из .env.example"; \
		else \
			echo "ОШИБКА: нет $(ENV_FILE) и нет $(ENV_EXAMPLE)"; \
			exit 1; \
		fi \
	else \
		echo "$(ENV_FILE) уже существует"; \
	fi

.PHONY: check-env
check-env:
	@if [ ! -f $(ENV_FILE) ]; then \
		echo "ОШИБКА: Файл $(ENV_FILE) не найден."; exit 1; \
	fi
	@result=0; \
	for var in $(REQUIRED_VARS); do \
		if ! grep -Eq '^[[:space:]]*'$${var}'=' $(ENV_FILE); then \
			echo "ОШИБКА: Обязательная переменная '$${var}' отсутствует или закомментирована в $(ENV_FILE)."; \
			result=1; \
		fi; \
	done; \
	if [ $$result -eq 0 ]; then \
		echo "Все обязательные переменные присутствуют."; \
	else \
		exit 1; \
	fi

#------------------------------------------------------------------------------
# Token and secret generation (idempotent)
#------------------------------------------------------------------------------

.PHONY: generate-tunnel-token
generate-tunnel-token:
	$(call gen_token,TUNNEL_AUTH_TOKEN,openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 64)

.PHONY: generate-influx-token
generate-influx-token:
	$(call gen_token,INFLUXDB_TOKEN,openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 64)

.PHONY: generate-django-secret
generate-django-secret:
	$(call gen_token,SECRET_KEY,openssl rand -base64 50 | tr -dc 'A-Za-z0-9!@#$%^&*(-_=+)' | cut -c1-50)

.PHONY: generate-absolute-server-regex
generate-absolute-server-regex:
	@ABSOLUTE_SERVER=$$(grep -E '^[[:space:]]*ABSOLUTE_SERVER=' $(ENV_FILE) | cut -d= -f2-); \
	if [ -z "$$ABSOLUTE_SERVER" ]; then \
		echo "Ошибка: переменная ABSOLUTE_SERVER отсутствует."; exit 1; \
	fi; \
	ABSOLUTE_SERVER_REGEX=$$(printf '%s' "$$ABSOLUTE_SERVER" | sed -e 's/[.[\*^$$()+?{}|\\]/\\\\&/g'); \
	if grep -q '^ABSOLUTE_SERVER_REGEX=' $(ENV_FILE); then \
		sed -i "" "s|^ABSOLUTE_SERVER_REGEX=.*|ABSOLUTE_SERVER_REGEX=$$ABSOLUTE_SERVER_REGEX|" $(ENV_FILE); \
	else \
		{ echo ""; echo "ABSOLUTE_SERVER_REGEX=$$ABSOLUTE_SERVER_REGEX"; } >> $(ENV_FILE); \
	fi

.PHONY: generate-email-url
generate-email-url:
	@EMAIL_PROTOCOP=$$(grep -E '^[[:space:]]*EMAIL_PROTOCOP=' $(ENV_FILE) | cut -d= -f2-); \
	EMAIL_LOGIN=$$(grep -E '^[[:space:]]*EMAIL_LOGIN=' $(ENV_FILE) | cut -d= -f2-); \
	EMAIL_PASSWORD=$$(grep -E '^[[:space:]]*EMAIL_PASSWORD=' $(ENV_FILE) | cut -d= -f2-); \
	EMAIL_SERVER=$$(grep -E '^[[:space:]]*EMAIL_SERVER=' $(ENV_FILE) | cut -d= -f2-); \
	EMAIL_PORT=$$(grep -E '^[[:space:]]*EMAIL_PORT=' $(ENV_FILE) | cut -d= -f2-); \
	if [ -z "$$EMAIL_PROTOCOP" ] || [ -z "$$EMAIL_LOGIN" ] || [ -z "$$EMAIL_PASSWORD" ] || [ -z "$$EMAIL_SERVER" ] || [ -z "$$EMAIL_PORT" ]; then \
		echo "Ошибка: не заданы все email-переменные."; exit 1; \
	fi; \
	EMAIL_LOGIN_ENC=$$($(PYTHON_BIN) -c "import urllib.parse; print(urllib.parse.quote('$$EMAIL_LOGIN'))"); \
	EMAIL_PASSWORD_ENC=$$($(PYTHON_BIN) -c "import urllib.parse; print(urllib.parse.quote('$$EMAIL_PASSWORD'))"); \
	EMAIL_URL="$$EMAIL_PROTOCOP://$$EMAIL_LOGIN_ENC:$$EMAIL_PASSWORD_ENC@$$EMAIL_SERVER:$$EMAIL_PORT"; \
	if grep -q '^EMAIL_URL=' $(ENV_FILE); then \
		sed -i "" "s|^EMAIL_URL=.*|EMAIL_URL=$$EMAIL_URL|" $(ENV_FILE); \
	else \
		{ echo ""; echo "EMAIL_URL=$$EMAIL_URL"; } >> $(ENV_FILE); \
	fi

.PHONY: generate-jwt
generate-jwt:
	sh ./jwt/update_keys.sh

.PHONY: generate-env
generate-env: init-env
	@echo "#--------------------------------------------------------------------------" >> $(ENV_FILE)
	@echo "# Generated vars ----------------------------------------------------------" >> $(ENV_FILE)
	@echo "#--------------------------------------------------------------------------" >> $(ENV_FILE)
	${MAKE} generate-tunnel-token
	${MAKE} generate-influx-token
	${MAKE} generate-django-secret
	${MAKE} generate-absolute-server-regex
	${MAKE} generate-email-url
	${MAKE} generate-jwt
	${MAKE} check-env

#------------------------------------------------------------------------------
# Composite targets
#------------------------------------------------------------------------------

.PHONY: run
run: generate-env
	docker compose up -d --build

.PHONY: update
update:
	docker compose down
	docker compose pull
	${MAKE} generate-env
	docker compose up -d --build
