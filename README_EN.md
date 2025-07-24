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


> ⚠️ Your CPU or VM hypervisor must support the `x86-64-v2` instruction set. When using a VM, the `host-passthrough` option (or `CPU=host`) may be required.

---

## ⚙️ Preconfiguration

Before deploying the application, the following steps must be completed:

### 1. DNS Records

The following A-type DNS records must be configured:

```text
@.your-domain.com
*.your-domain.com
```

These cover the required subdomains:

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

### 2. Ports

The following ports must be open for the cloud to operate:

- `443` – cloud access  
- `7107` – tunnels  
- `7501` – tunnel dashboard access (optional)

> ⚠️ If any of these ports are already in use, you can uncomment the corresponding parameters in the `.env` file: `TRAEFIK_EXTERNAL_PORT`, `TUNNEL_EXTERNAL_PORT`, or `TUNNEL_DASHBOARD_EXTERNAL_PORT`.

> If port `443` is already occupied by another web server, see: [Using with External Web Server](#-using-with-external-web-server-nginxapachecaddy)
> 

### 3. DNS Records for Email

MX, SPF, DKIM, and DMARC records must be configured to enable email sending. 
This is required for sending organization invites, password resets, etc.


### 4. TLS Certificates

Certificates must be issued by a trusted CA:
- Let's Encrypt (DNS challenge)
- Commercial CAs (Sectigo, DigiCert, etc.)

> ❌ Self-signed certificates are not supported.

If you already have a certificate for your domain, check the SANs (Subject Alternative Names):

```bash
openssl x509 -in "path/to/your/certs/fullchain.pem" -noout -text | grep -A1 "Subject Alternative Name"
```

The certificate must include:

```text
your-domain.com
*.your-domain.com
*.http.your-domain.com
*.ssh.your-domain.com
```

If not, you must obtain a new certificate.

Place `fullchain.pem` and `privkey.pem` in the `./tls` directory or set the `TLS_CERTS_PATH` environment variable.

To get a certificate using Certbot, see: [Manual Wildcard Certificate Setup Example](#-manual-wildcard-certificate-setup-example)

---

## 🚀 Application Deployment

> You need `docker compose v1.21.0` or higher to run the application.

### 1. Configure Environment Variables

Copy the sample environment file:

```bash
cp .env.example .env
nano .env
```

Fill in the required variables, e.g.:

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

# Admin credentials
ADMIN_EMAIL=admin@mail.com
ADMIN_USERNAME=admin
ADMIN_PASSWORD=password

# InfluxDB admin
INFLUXDB_USERNAME=influx_admin
INFLUXDB_PASSWORD=influx_password

# Tunnel Dashboard admin
TUNNEL_DASHBOARD_USER=tunnel_admin
TUNNEL_DASHBOARD_PASSWORD=tunnel_password

# Postgres admin
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

# Set external ports
#TRAEFIK_EXTERNAL_PORT="127.0.0.1:8443
#TUNNEL_EXTERNAL_PORT=7108
#TUNNEL_DASHBOARD_EXTERNAL_PORT=7502

```

### 2. Automatic Initialization and Launch

Install `make` if not yet installed:

```bash
apt install make
```

Then run:

```bash
make run
```

✅ Your cloud is now ready.

---

## ▶️ Usage

### User Registration

User self-registration is disabled in the On-Premise cloud.
Only one admin user will be available initially, using credentials from `ADMIN_USERNAME` and `ADMIN_PASSWORD`.

> ⚠️ You may change the password or create another admin user. However, the user specified in `.env` will be recreated on each restart if deleted.

The admin must create the first organization manually. New users can be added via an admin panel or email invitation.

### Controller Setup

To configure your controller to work with your on-premises cloud, follow these steps:

#### 1. Add a Cloud Provider

##### Provider version <= 1.5.14

Open the controller’s console and execute the following command:
```bash
wb-cloud-agent add-provider your-onpremise-name https://your-domain.com/ https://your-domain.com/api-agent/v1/
```
where:
- `your-onpremise-name` - provider name (can be any value)
- `https://your-domain.com/` - cloud address
- `https://your-domain.com/api-agent/v1/` - cloud agent address (always: `cloud address` + `/api-agent/v1/`)

> After your-domain.com If it is available online, go to the web UI of the controller in the Settings -> System section and click on the activation link with which you can link the controller to your cloud.

##### Provider version > 1.5.14

```bash
wb-cloud-agent use-on-premise https://your-domain.com
```

> After your-domain.com When it is available on the network, the `wb-cloud-agent` command displays an activation link that allows you to link the controller to your cloud.

#### 2. Link the Controller to a User

Go to the controller’s web interface and select:

`Settings` -> `System` -> `Cloud Connection (your-onpremise-name)`

> If you do not see the System section in the `settings`, you do not have administrator rights.
>
> Go to `Settings` -> `Access Rights`, select `Administrator` -> `I accept all responsibility...` -> `Apply`.
>
> After this, the `System` section will appear in the menu.

Follow the link, log in to the cloud, and select the organization to which you want to add the controller.

Your controller is now successfully linked to the cloud.

---

## 🎛 Environment Variables

You can override some environment variables manually in `.env`. If a variable is already set, it won’t be generated again.

Example:

```dotenv
# Token for opening tunnels
TUNNEL_AUTH_TOKEN=GLgTbKtCiwF8J4tI439NJba0pbXfW0a39E7jZOOr0qO67xonhhfaNIWiH7FzPP

# Token for Influx access
INFLUXDB_TOKEN=PvxahJmIuieFy1ieODoQ3JpKEVSCDSkRUQZjjePSlajJV6w1Sl2iAQcpY8f2z4s

# Secret key for Django
SECRET_KEY=40h0EtROD1krOPzZ/PSiCgnZgbOc+x0omKJrpzH9JDDbwXBTf4

```

For JWT, place `private.pem` and `public.pem` in the `jwt` directory, or they’ll be generated.

---

## 📦 Makefile Commands

Run all commands from the repo root.

### Main Commands

| Command                  | Description                                                |
|--------------------------|------------------------------------------------------------|
| `make help`              | Show all available commands                                |
| `make check-env`         | Check required environment variables in `.env`             |
| `make check-certs`       | Check availability and validity of certificates            |
| `make generate-env`      | Generate missing tokens/secrets                            |
| `make generate-jwt`      | Generate or update JWT keys                                |
| `generate-tunnel-token`  | Generate token for SSH/HTTP tunnels                        |
| `generate-influx-token`  | Generate Influx token                                      |
| `generate-django-secret` | Generate Django SECRET_KEY                                 |
| `make run`               | Full launch cycle (generate-env, build and start containers) |
| `make update`            | Stop containers, update images, rebuild and restart        |

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

---

## 🛠 Manual Wildcard Certificate Setup Example

### Install Certbot

```bash
sudo apt update && sudo apt install certbot -y
```

### Obtain Wildcard Certificate

```bash
export EMAIL=admin@email.com
export DOMAIN_NAME=your-domain-name.com
```

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

Add DNS TXT records as prompted by Certbot. Use `dig` to verify.

Certs saved to:

```
/etc/letsencrypt/live/your-domain.com/fullchain.pem
/etc/letsencrypt/live/your-domain.com/privkey.pem
```

### Verify RSA Key

```bash
openssl rsa -in /etc/letsencrypt/live/$DOMAIN_NAME/privkey.pem -check -noout
```

---

## 🛡 Using with External Web Server (Nginx/Apache/Caddy)

If port 443 is already used by another web server, configure as follows:

### 1. Set this in `.env`:
```dotenv
TRAEFIK_EXTERNAL_PORT=127.0.0.1:8443
```

### 2. Proxy via External Web Server

Example Nginx config:

```nginx
server {
    listen 443 ssl;
    server_name your-domain.com;

    ssl_certificate     /etc/letsencrypt/live/your-domain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/your-domain.com/privkey.pem;

    location / {
        proxy_pass https://127.0.0.1:8443;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

> TLS must be terminated in the external web server. Traefik does not need certificates in this case.

> Ensure port 8443 is bound only to 127.0.0.1 and not exposed publicly.

---

