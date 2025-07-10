ENV_FILE=.env

define gen_token
	@VAR_NAME="$1"; \
	NEW_VALUE=$$($2); \
	if grep -Eq "^$${VAR_NAME}=" "$(ENV_FILE)"; then \
		echo "$${VAR_NAME} уже существует (активна)."; \
	else \
		{ echo ""; echo "$${VAR_NAME}=$${NEW_VALUE}"; } >> "$(ENV_FILE)"; \
	fi
endef

required_vars = \
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

check-env:
	@result=0; \
	for var in $(required_vars); do \
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

generate-tunnel-token:
	$(call gen_token,TUNNEL_AUTH_TOKEN,openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 64)

generate-influx-token:
	$(call gen_token,INFLUXDB_TOKEN,openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 64)

generate-django-secret:
	$(call gen_token,SECRET_KEY,openssl rand -base64 50 | tr -dc 'A-Za-z0-9!@#$%^&*(-_=+)' | cut -c1-50)


generate-absolute-server-regex:
	@ABSOLUTE_SERVER=$$(grep -E '^[[:space:]]*ABSOLUTE_SERVER=' $(ENV_FILE) | cut -d= -f2-); \
	if [ -z "$$ABSOLUTE_SERVER" ]; then \
		echo "Ошибка: переменная ABSOLUTE_SERVER отсутствует или закомментирована в $(ENV_FILE)."; \
		exit 1; \
	fi; \
	ABSOLUTE_SERVER_REGEX=$$(printf '%s' "$$ABSOLUTE_SERVER" | sed -e 's/[.[\*^$$()+?{}|\\]/\\\\&/g'); \
	if grep -q '^ABSOLUTE_SERVER_REGEX=' $(ENV_FILE); then \
		sed -i "" "s|^ABSOLUTE_SERVER_REGEX=.*|ABSOLUTE_SERVER_REGEX=$$ABSOLUTE_SERVER_REGEX|" $(ENV_FILE); \
	else \
		{ echo ""; echo "ABSOLUTE_SERVER_REGEX=$$ABSOLUTE_SERVER_REGEX"; } >> $(ENV_FILE); \
	fi

generate-email-url:
	@EMAIL_PROTOCOP=$$(grep -E '^[[:space:]]*EMAIL_PROTOCOP=' $(ENV_FILE) | cut -d= -f2-); \
	EMAIL_LOGIN=$$(grep -E '^[[:space:]]*EMAIL_LOGIN=' $(ENV_FILE) | cut -d= -f2-); \
	EMAIL_PASSWORD=$$(grep -E '^[[:space:]]*EMAIL_PASSWORD=' $(ENV_FILE) | cut -d= -f2-); \
	EMAIL_SERVER=$$(grep -E '^[[:space:]]*EMAIL_SERVER=' $(ENV_FILE) | cut -d= -f2-); \
	EMAIL_PORT=$$(grep -E '^[[:space:]]*EMAIL_PORT=' $(ENV_FILE) | cut -d= -f2-); \
	if [ -z "$$EMAIL_PROTOCOP" ] || [ -z "$$EMAIL_LOGIN" ] || [ -z "$$EMAIL_PASSWORD" ] || [ -z "$$EMAIL_SERVER" ] || [ -z "$$EMAIL_PORT" ]; then \
		echo "Ошибка: отсутствует одна из переменных EMAIL_PROTOCOP, EMAIL_LOGIN, EMAIL_PASSWORD, EMAIL_SERVER, EMAIL_PORT."; \
		exit 1; \
	fi; \
	EMAIL_LOGIN_ENC=$$(python3 -c "import urllib.parse; print(urllib.parse.quote('$$EMAIL_LOGIN'))"); \
	EMAIL_PASSWORD_ENC=$$(python3 -c "import urllib.parse; print(urllib.parse.quote('$$EMAIL_PASSWORD'))"); \
	EMAIL_URL="$$EMAIL_PROTOCOP://$$EMAIL_LOGIN_ENC:$$EMAIL_PASSWORD_ENC@$$EMAIL_SERVER:$$EMAIL_PORT"; \
	if grep -q '^EMAIL_URL=' $(ENV_FILE); then \
		sed -i "" "s|^EMAIL_URL=.*|EMAIL_URL=$$EMAIL_URL|" $(ENV_FILE); \
	else \
		{ echo ""; echo "EMAIL_URL=$$EMAIL_URL"; } >> $(ENV_FILE); \
	fi

generate-jwt:
	sh ./jwt/update_keys.sh


generate-env:
	@if [ ! -f $(ENV_FILE) ]; then \
		echo "ОШИБКА: Файл $(ENV_FILE) не найден."; \
		exit 1; \
	fi; \
	result=0; \
	echo "" >> .env
	echo "#--------------------------------------------------------------------------" >> .env
	echo "# Generated vars ----------------------------------------------------------" >> .env
	echo "#--------------------------------------------------------------------------" >> .env
	${MAKE} generate-tunnel-token
	${MAKE} generate-influx-token
	${MAKE} generate-django-secret
	${MAKE} generate-absolute-server-regex
	${MAKE} generate-email-url
	${MAKE} check-env

on-premise-run:
	${MAKE} generate-env
	docker compose up -d --build

on-premise-update:
	docker compose down
	docker compose pull
	${MAKE} generate-env
	docker compose up -d --build
