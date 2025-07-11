# Wirenboard On-Premise Облако


> ⚠️ Используя этот репозиторий или загружая Docker образы, вы принимаете условия лицензионного соглашения (LICENSE файл).

---

## 📖 Описание

Документация по настройке и развертыванию облака Wirenboard в On-Premise окружении. 

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

## ⚙️ Предварительная настройка

Перед развертыванием приложения должны быть выполнены следующие шаги:

### 1. DNS-записи для TLS

Должны быть настроены следующие DNS-записи типа A:

```text
@.your-domain.com
*.your-domain.com
*.http.your-domain.com
*.ssh.your-domain.com
```

Они должны покрывать следующие поддомены:

```text
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

### 2. DNS-записи для почты

Должны быть настроены MX, SPF, DKIM и DMARC записи для корректной отправки email. 
Это необходимо для отправки электронных писем с приглашением в организацию, сброса пароля и тд.

### 3. Сертификаты TLS

Создайте и поместите файлы сертификатов (`fullchain.pem`, `privkey.pem`) в директорию:

```bash
path/to/your/cloud-on-premise/tls
```

Или укажите путь в переменной окружения `TLS_CERTS_PATH`.

---


## 🚀 Развертывание приложения

> Для запуска вам понадобится `docker compose` v1.21.0 и выше.

### 1. Настройка переменных окружения

Создайте копию файла окружения:

```bash
cp .env.example .env
nano .env
```

Заполните все обязательные переменные как в примере ниже:

```dotenv
ABSOLUTE_SERVER=my-domain-name.com

# Настройка отправки email
# Установите smtp+ssl если используете SSL
EMAIL_PROTOCOP=smtp+tls
EMAIL_LOGIN=mymail@mail.com
EMAIL_PASSWORD=password
EMAIL_SERVER=smtp.mail.com
EMAIL_PORT=587
EMAIL_NOTIFICATIONS_FROM=mymail@mail.com

# Создание администратора
ADMIN_EMAIL=admin@mail.com
ADMIN_USERNAME=admin
ADMIN_PASSWORD=password

# Создание администратора InfluxDB
INFLUXDB_USERNAME=influx_admin
INFLUXDB_PASSWORD=influx_password

# Создание администратора Tunnel Dashboard
TUNNEL_DASHBOARD_USER=tunnel_admin
TUNNEL_DASHBOARD_PASSWORD=tunnel_password

# Создание администратора Postgres
POSTGRES_DB=db_name
POSTGRES_USER=postgres_user
POSTGRES_PASSWORD=postgres_password

#--------------------------------------------------------------------------
# Optional ----------------------------------------------------------------
#--------------------------------------------------------------------------

# Создание администратора Minio
#MINIO_ROOT_USER=minio_admin
#MINIO_ROOT_PASSWORD=minio_password

# Установить имя докер сети если требуется. По умолчанию "wb-net"
#DOCKER_NET_NAME=my-docker-network

# Установить путь к директории с tls сертификатами если требуется. По умолчанию "./tls"
#TLS_CERTS_PATH=path/to/my/certs/

```

### 2. Автоматическая настройка и запуск

Установите пакет `make`, если он ещё не установлен:

```bash
apt install make
```

Выполните команду, которая сгенерирует все необходимые секретные ключи и токены и запустит проект:

```bash
make run
```

✅ Поздравляем! Ваше облако готово к работе. 

---

## Что дальше?

### Регистрация пользователей

В on-premise облаке регистрация сторонних пользователей отключена.
Доступ к системе изначально имеет только один пользователь с правами администратора, 
чьи логин и пароль берутся из переменных окружения `ADMIN_USERNAME` и `ADMIN_PASSWORD` при запуске проекта. 

> ⚠️ Вы можете сменить пароль в любое время и создать другого администратора, 
> но имейте в виду, что, если вы удалите пользователя, 
> который указан в переменных окружения, он создаться снова при перезапуске проекта.

Создание первой организации осуществляется администратором вручную.

Добавление новых пользователей возможно только через административную панель или посредством отправки приглашения на электронную почту. 

После получения приглашения пользователь может перейти по ссылке в письме и зарегистрироваться.


### Добавление контроллеров

⚠️ Нужно добавить как доделаем wb-cloud-agent

---

## Переменные окружения

Вы так же можете указать некоторые переменные окружения вручную, 
и тогда при запуске генерация указанных переменных будут пропущена. 

Пример заполнения доступных переменных окружения:

```dotenv

# Токен для открытия тоннелей
TUNNEL_AUTH_TOKEN=GLgTbKtCiwF8J4tI439NJba0pbXfW0a39E7jZOOr0qO67xonhhfaNIWiH7FzPP

# Токен для доступа к Influx
INFLUXDB_TOKEN=PvxahJmIuieFy1ieODoQ3JpKEVSCDSkRUQZjjePSlajJV6w1Sl2iAQcpY8f2z4s

# Секретный ключ для Django
SECRET_KEY=40h0EtROD1krOPzZ/PSiCgnZgbOc+x0omKJrpzH9JDDbwXBTf4

# Приватный и публичный JWT ключи
# Обязательно! Значение должно быть в ковычках "" и все переносы строк замененны на '\n'
PRIVATE_KEY="-----BEGIN PRIVATE KEY-----\nMIIEvAIBKYfZatYWB9N----YOUR_KEY----aUIZJC7fno2DqqH5fQ==\n-----END PRIVATE KEY-----"
PUBLIC_KEY="-----BEGIN PUBLIC KEY-----\nMIIBIjANBgkqhkiG9wT----YOUR_KEY----3UV8Hm2CS7x9E47QIQAB\n-----END PUBLIC KEY-----"

```

---

## 📦 Управление проектом через Makefile

Для работы с on-premise облаком используется набор команд Makefile.  
Все действия выполняются из корня репозитория. Перед первым запуском убедитесь, что у вас установлен Docker Compose и утилита make.

### Основные команды

| Команда                | Описание                                                                                     |
|------------------------|----------------------------------------------------------------------------------------------|
| `make help`            | Показать справку по всем доступным командам                                                  |
| `make init-env`        | Создать файл `.env` на основе `.env.example`, если он ещё не существует                      |
| `make check-env`       | Проверить наличие всех обязательных переменных окружения в `.env`                            |
| `make generate-env`    | Сгенерировать недостающие токены и секреты, заполнить переменные в `.env`                    |
| `make generate-jwt`    | Сгенерировать или обновить ключи для JWT                                                     |
| `make run`             | Запустить полный цикл развертывания: generate-env, сборка и запуск контейнеров               |
| `make update`          | Остановить контейнеры, обновить образы, пересобрать и запустить проект заново                |

### Примеры использования

```sh
# Первый запуск (инициализация окружения и запуск контейнеров)
make run

# Обновить проект до актуального состояния
make update

# Проверить корректность переменных окружения
make check-env

# Справка по командам
make help

