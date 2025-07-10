# Wirenboard On-Premise Cloud

> ⚠️ By using this repository or downloading Docker images, you accept the terms of the license agreement (see LICENSE file).

---

## 📖 Description

Documentation for setting up and deploying Wirenboard Cloud in an On-Premise environment.

### Minimum System Requirements:
- OS: Linux (Ubuntu 24)
- CPU: 2 Cores
- RAM: 6GB
- HDD: 20GB

### Recommended System Requirements:
- OS: Linux (Ubuntu 24)
- CPU: 4 Cores
- RAM: 8GB
- HDD: 40GB

---

## ⚙️ Pre-deployment Steps

Before deploying the application, the following steps must be completed:

### 1. DNS Records for TLS

The following A-type DNS records must be configured:

```text
@.your-domain.com
*.your-domain.com
*.http.your-domain.com
*.ssh.your-domain.com
```

These should cover the following subdomains:

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

### 2. DNS Records for Email

MX, SPF, DKIM, and DMARC records must be configured for correct email delivery. This is required for sending invitations, password reset emails, etc.

### 3. TLS Certificates

Create and place certificate files (`fullchain.pem`, `privkey.pem`) in the directory:

```bash
path/to/your/cloud-on-premise/tls
```

Or specify the path in the environment variable `TLS_CERTS_PATH`.

---

## 🚀 Application Deployment

> `docker compose` v1.21.0 or higher is required for launching.

### 1. Environment Variables Setup

Create a copy of the environment file:

```bash
cp .env.example .env
nano .env
```

Fill in all required variables as in the example below:

```dotenv
ABSOLUTE_SERVER=my-domain-name.com

# Email setup
# Set smtp+ssl if using SSL
EMAIL_PROTOCOP=smtp+tls
EMAIL_LOGIN=mymail@mail.com
EMAIL_PASSWORD=password
EMAIL_SERVER=smtp.mail.com
EMAIL_PORT=587
EMAIL_NOTIFICATIONS_FROM=mymail@mail.com

# Create admin user
ADMIN_EMAIL=admin@mail.com
ADMIN_USERNAME=admin
ADMIN_PASSWORD=password

# Create InfluxDB admin
INFLUXDB_USERNAME=influx_admin
INFLUXDB_PASSWORD=influx_password

# Create Tunnel Dashboard admin
TUNNEL_DASHBOARD_USER=tunnel_admin
TUNNEL_DASHBOARD_PASSWORD=tunnel_password

# Create Postgres admin
POSTGRES_DB=db_name
POSTGRES_USER=postgres_user
POSTGRES_PASSWORD=postgres_password

#--------------------------------------------------------------------------
# Optional ----------------------------------------------------------------
#--------------------------------------------------------------------------

# Create Minio admin
#MINIO_ROOT_USER=minio_admin
#MINIO_ROOT_PASSWORD=minio_password

# Set Docker network name if required. Default is "wb-net"
#DOCKER_NET_NAME=my-docker-network

# Set path to directory with tls certificates if required. Default is "./tls"
#TLS_CERTS_PATH=path/to/my/certs/

```

### 2. Automatic Setup and Launch

Run the Make command to generate all required secret keys and tokens and start the project:

```bash
make run
```

✅ Congratulations! Your cloud is ready.

---

## What’s Next?

### User Registration

In on-premise cloud, registration of external users is disabled.
Initially, only one user with admin rights has access, and their login and password are set via the environment variables `ADMIN_USERNAME` and `ADMIN_PASSWORD` at project startup.

> ⚠️ You can change the password at any time and create another admin user. However, if you delete the user specified in the environment variables, it will be recreated at the next project restart.

Creating the first organization is done manually by the administrator.

Adding new users is possible only via the admin panel or by sending an invitation by email.

Once the invitation is received, the user can follow the link in the email to register.

### Adding Controllers

⚠️ In development

---

## Environment Variables

You may also set some environment variables manually; in this case, their generation will be skipped at startup.

Example of available environment variables:

```dotenv
# Token for opening tunnels
TUNNEL_AUTH_TOKEN=GLgTbKtCiwF8J4tI439NJba0pbXfW0a39E7jZOOr0qO67xonhhfaNIWiH7FzPP

# Token for Influx access
INFLUXDB_TOKEN=PvxahJmIuieFy1ieODoQ3JpKEVSCDSkRUQZjjePSlajJV6w1Sl2iAQcpY8f2z4s

# Secret key for Django
SECRET_KEY=40h0EtROD1krOPzZ/PSiCgnZgbOc+x0omKJrpzH9JDDbwXBTf4

# Private and public JWT keys
# Required! The value must be in double quotes "" and all line breaks replaced with '\n'
PRIVATE_KEY="-----BEGIN PRIVATE KEY-----\nMIIEvAIBKYfZatYWB9N----YOUR_KEY----aUIZJC7fno2DqqH5fQ==\n-----END PRIVATE KEY-----"
PUBLIC_KEY="-----BEGIN PUBLIC KEY-----\nMIIBIjANBgkqhkiG9wT----YOUR_KEY----3UV8Hm2CS7x9E47QIQAB\n-----END PUBLIC KEY-----"
```

---

## 📦 Managing the Project via Makefile

A set of Makefile commands is used to work with the on-premise cloud. All actions are performed from the root of the repository. Before the first launch, make sure you have Docker Compose and the make utility installed.

### Main Commands

| Command                | Description                                                                        |
|------------------------|------------------------------------------------------------------------------------|
| `make help`            | Show all available commands                                                        |
| `make init-env`        | Create `.env` from `.env.example` if it does not exist                             |
| `make check-env`       | Check for required environment variables in `.env`                                 |
| `make generate-env`    | Generate missing tokens/secrets, fill them in `.env`                               |
| `make generate-jwt`    | Generate or update JWT keys                                                        |
| `make run`             | Full deployment cycle: generate-env, build and launch containers                   |
| `make update`          | Stop containers, update images, rebuild and relaunch project                       |

### Usage Examples

```sh
# First launch (environment initialization and container startup)
make run

# Update the project to the current state
make update

# Check the correctness of environment variables
make check-env

# Command help
make help
```

