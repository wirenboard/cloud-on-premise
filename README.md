# Wirenboard On-Premise Облако


> ⚠️ Используя этот репозиторий или загружая образы, вы принимаете условия лицензионного соглашения (LICENSE файл).

---

## 📖 Описание

Документация по настройке и развертыванию облака Wirenboard в On-Premise окружении. 

Инструкция включает настройку переменных окружения, запуск контейнеров,
а также пример получения Wildcard сертификатов вручную с помощью Certbot и Let's Encrypt и настройки DNS записей для отправки email


### Минимальные системные требования:
- OS: Linux(Ubuntu 24)
- CPU: 2 Cores
- RAM: 6GB
- HDD: 20GB

### Рекомендуемые системные требования:

- OS: Linux(Ubuntu 24)
- CPU: 4 Cores
- RAM: 8GB
- HDD: 40GB

---


## 🚀 Развертывание приложения
Скопируйте архив на сервер, распакуйте его и следуйте инструкциям ниже.

> Для запуска вам понадобится Docker и Docker Compose.

> ⚠️ Обязательно [настройте сертификаты](#настройка-сертификатов)! Это необходимо для корректной работы облака.

### 1. Добавление переменных окружения
Переименуйте файл `.env.example` в `.env` и укажите свои переменные окружения:

```bash
mv .env.example .env
nano .env
```
Пример заполнения переменных окружения:

```dotenv
# Доменный адрес сервера
ABSOLUTE_SERVER=your-domain-name.com
# Заменить точки на \. в доменном имени
ABSOLUTE_SERVER_REGEX=your-domain-name\.com

# Создание администратора в Django
DJANGO_SUPERUSER_EMAIL=django_admin@mail.com
DJANGO_SUPERUSER_USERNAME=django_admin
DJANGO_SUPERUSER_PASSWORD=django_password

# Секретный ключ Django. Можно сгенерировать на сайте https://djecrety.ir/
SECRET_KEY=django_secret_key

# Создание администратора InfluxDB
INFLUXDB_USERNAME=influx_admin
INFLUXDB_PASSWORD=influx_password
INFLUXDB_TOKEN=influx_token

# Создание администратора Tunnel Dashboard
TUNNEL_DASHBOARD_USER=tunnel_admin
TUNNEL_DASHBOARD_PASSWORD=tunnel_password
TUNNEL_AUTH_TOKEN=tunnel_auth_token

# Создание администратора Minio
MINIO_ROOT_USER=minio_admin
MINIO_ROOT_PASSWORD=minio_password

# Создание администратора Postgres
POSTGRES_DB=db_name
POSTGRES_USER=postgres_user
POSTGRES_PASSWORD=postgres_password

# Настройка подключения к SMTP серверу
# В логине и пароле замените все символы @ на %40 и : на %3A
# Установите smtp+ssl если используете SSL
EMAIL_URL=smtp+tls://user@mail.com:password@smtp.mail.com:587

# Адрес отправителя
EMAIL_NOTIFICATIONS_FROM=user@mail.com

# Приватный и публичный ключи для JWT. Заменить все переносы строк на \n
PRIVATE_KEY="-----BEGIN PRIVATE KEY-----\nMIIEvAIBKYfZatYWB9N----YOUR_KEY----aUIZJC7fno2DqqH5fQ==\n-----END PRIVATE KEY-----"
PUBLIC_KEY="-----BEGIN PUBLIC KEY-----\nMIIBIjANBgkqhkiG9wT----YOUR_KEY----3UV8Hm2CS7x9E47QIQAB\n-----END PUBLIC KEY-----"

```

Можно воспользоваться командой для генерации ключей:
```bash
openssl genpkey -algorithm RSA -out private_key.pem -pkeyopt rsa_keygen_bits:2048
openssl rsa -pubout -in private_key.pem -out public_key.pem
```


### 4. Запуск контейнеров
Запустите контейнеры в фоновом режиме с помощью Docker Compose:

```bash
docker compose up -d --build
```

После успешного запуска docker compose будет создан пользователь с правами администратора для первичного доступа в облако и панель администратора.
Логин и пароль берутся из `.env` файла из переменных `ADMIN_USERNAM` и `ADMIN_PASSWORD` если они были установлены.
Или устанавливаются по умолчанию как login: `admin` password: `admin`.

Добавление остальных пользователей происходит по приглашению администратора на странице настроек организации. Приглашенному пользователю придет email со ссылкой после перехода по которой будет предложено зарегистрироваться.


> ⚠️ После развертывания облака, необходимо [настроить контроллеры](#настройка-контроллера) для работы с on-premises облаком.


## 🔑 Настройка сертификатов

Вы можете подключить сертификаты `fullchain.pem` и `privkey.pem` добавив их в директорию `/etc/letsencrypt/live/your-domain.com/`.

Необходимо, чтобы у вас была создана следующая DNS-запись типа A:

```
*.your-domain.com
```

Она должна покрывать следующие поддомены:

```
metrics.your-domain.com
influx.your-domain.com
tunnel.your-domain.com
app.your-domain.com
agent.your-domain.com
ssh.your-domain.com
http.your-domain.com
*.ssh.your-domain.com
*.http.your-domain.com
```

---

### Пример ручной настройки Wildcard сертификатов

### Установка Certbot

```bash
sudo apt update && sudo apt install certbot -y
```

### Получение сертификата с wildcard-доменами

Укажите email, к которому будет привязан сертификат и доменное имя:

```bash
export EMAIL=admin@email.com
export DOMAIN_NAME=your-domain-name.com
```

Запустите Certbot выполнив команду:

```bash
sudo certbot certonly --manual --preferred-challenges dns \
  --agree-tos \
  --email $EMAIL \
  --key-type rsa \
  -d $DOMAIN_NAME \
  -d "*.$DOMAIN_NAME" \
  -d "*.ssh.$DOMAIN_NAME" \
  -d "*.http.$DOMAIN_NAME"
```

И последовательно создайте записи на вашем DNS-сервере на основе того что выдаст Certbot:

### 🔹 Первая запись от Certbot

```
Type: TXT
Name: _acme-challenge.your-domain-name.com.
Value: some_token_1
```

Добавьте запись в ваш DNS-сервер.

Не закрывая окно терминала, проверьте в другом окне создана ли запись:

```bash
dig TXT _acme-challenge.your-domain-name.com +short
```

Если запись создана, нажмите **Enter** (Continue) в первом окне.

### 🔹 Вторая запись (`http`) по аналогии с первой

```
Type: TXT
Name: _acme-challenge.http.your-domain-name.com.
Value: some_token_2
```

Проверьте:

```bash
dig TXT _acme-challenge.http.your-domain-name.com +short
```
Если запись создана, нажмите **Enter** (Continue).

**И так далее пока не создадите все записи.**


### Результат

Certbot сохранит сертификат по пути:

```
/etc/letsencrypt/live/your-domain.com/fullchain.pem
/etc/letsencrypt/live/your-domain.com/privkey.pem
```

### Проверка RSA-ключа

```bash
openssl rsa -in /etc/letsencrypt/live/$DOMAIN_NAME/privkey.pem -check -noout
```

Должно быть:

```
RSA key ok
```
---

## 🛠️ Настройка контроллера 

!!! Не актуально !!! Поправить

Для настройки контроллера на работу с вашим on-premises облаком, необходимо выполнить следующие шаги:

### 1. Добавить провайдера облака

Зайти в консоль самого контроллера и выполнить следующие команду:
```bash
wb-cloud-agent add-provider your-onpremise-name https://your-domain.com/ https://your-domain.com/api-agent/v1/
```
где:
- `your-onpremise-name` - название провайдера (можно задать любое)
- `https://your-domain.com/` - адрес облака
- `https://your-domain.com/api-agent/v1/` - адрес агента облака. Адрес всегда будет: `адрес облака` + `/api-agent/v1/`

### 2. Привязать контроллер к пользователю

Перейдите в веб-интерфейс контроллера, выберите:

`Настройки` -> `Система` -> `Подключение к облаку (your-onpremise-name)`

> Если вы не видите в настройках пункт `Система`, значит у вас нет прав администратора. 
> 
> Перейдите в `Настройки` -> `Права доступа` и выберите пункт `Администратор` -> `Я принимаю всю ответственность...` -> `Применить`
> 
> После этого пункт `Система` появится в меню.

Перейдите по ссылке и авторизуйтесь в облаке.

Ваш контроллер успешно привязан к облаку.

---