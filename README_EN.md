# Wiren Board Cloud On-Premise

> ⚠️ By using this repository or downloading Docker images, you accept the terms of the license agreement (see the LICENSE file).

---

## 📖 Description

Documentation for setting up and deploying Wiren Board Cloud in an On-Premise environment.

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

### On-Premise Version Features

The main differences between the local cloud and our [wirenboard.cloud](https://wirenboard.cloud) service are related to instance security and reduced server load.

#### User Registration and Demo Access

In On-Premise:
- new users cannot register without an invitation from the organization owner or admin;
- there is no “Demo” button.

#### Metrics

Currently, only the free version for up to 100 controllers is available, and it can be used for personal and commercial purposes. In this version, sending anonymized metrics to our server is required; you can see exactly what is sent in the instance backend under “On-Premise” → “Metrics”.

If your instance cannot connect to our metrics collection server [metrics.wirenboard.cloud](https://on-premise-metrics.wirenboard.cloud), the cloud will continue to work, but you will not be able to add controllers.

Paid plans that allow you to disable metric sending and add more controllers are planned.

Sent metrics, as shown in the backend of the On-Premise instance:
![metrics.png](./assets/metrics.png)

---

## ⚙️ Preconfiguration

Before deploying the application, the following steps must be completed:

### 1. DNS Records

In all examples below, `your-domain.com` means the **full public hostname of your cloud**. If the cloud will be available at `https://cloud.example.com`, use `cloud.example.com` everywhere, not the root domain `example.com`.

The following DNS A records must be configured:

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

> ⚠️ If any of these ports are already in use, you can override them in the `.env` file.

> If port `443` is already occupied by another web server, see: [Using with External Web Server](#-using-with-external-web-server-nginxapachecaddy)
>

### 3. DNS Records for Email

MX, SPF, DKIM, and DMARC records must be configured to enable email sending.
This is required for sending organization invitations, password resets, etc.


### 4. TLS Certificates

Certificates must be issued by a trusted CA:
- Let's Encrypt (DNS challenge)
- Commercial CAs (Sectigo, DigiCert, etc.)

> ❌ Self-signed certificates are not supported.

If you already have a certificate for this hostname, check the SANs (Subject Alternative Names):

The certificate must be issued for the same value as `ABSOLUTE_SERVER`, including the subdomain. For example, if the cloud runs on `cloud.example.com`, the certificate must cover `cloud.example.com`, `*.cloud.example.com`, `*.http.cloud.example.com`, and `*.ssh.cloud.example.com`.

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

Otherwise, you must obtain a new certificate.

Place `fullchain.pem` and `privkey.pem` in the `./tls` directory or set the `TLS_CERTS_PATH` environment variable.

To get a certificate using Certbot, see: [Manual Wildcard Certificate Setup Example](#-manual-wildcard-certificate-setup-example)

---

### 5. Custom Logo and Icons

This step is optional.

The frontend reads branding assets from the local `branding/` directory, which is mounted into the `frontend` container.
If you do not add your own files there, the application will continue using the default Wiren Board logo and icons.

To replace the logo and icons, place your files in that directory with the exact names listed below:

```text
branding/logo.svg
branding/favicon.svg
branding/favicon.ico
branding/favicon-192.png
branding/favicon-512.png
branding/apple-touch-icon.png
```

You can also replace only some of these files.

If the project is already running, restart the frontend after replacing the files:

```shell
docker compose restart frontend
```

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

`ABSOLUTE_SERVER` must match the full public hostname of the cloud. If the cloud will be available at `https://cloud.example.com`, set `ABSOLUTE_SERVER=cloud.example.com`.

```dotenv
ABSOLUTE_SERVER=my-domain-name.com

# Email setup
# Set smtp+ssl if using SSL
EMAIL_PROTOCOL=smtp+tls
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

# Tunnel Dashboard admin and port configuration
TUNNEL_DASHBOARD_USER=tunnel_admin
TUNNEL_DASHBOARD_PASSWORD=tunnel_password
TUNNEL_DASHBOARD_PORT=7501

# Tunnel port configuration – change if the port is already in use
TUNNEL_PORT=7107

# Postgres admin
POSTGRES_DB=db_name
POSTGRES_USER=postgres_user
POSTGRES_PASSWORD=postgres_password

#--------------------------------------------------------------------------
# Optional ----------------------------------------------------------------
#--------------------------------------------------------------------------

# Create MinIO admin
#MINIO_ROOT_USER=minio_admin
#MINIO_ROOT_PASSWORD=minio_password

# Set Docker network name if required. Default is "wb-net"
#DOCKER_NET_NAME=my-docker-network

# Set the path to the directory with TLS certificates if required. Default is "./tls"
#TLS_CERTS_PATH=path/to/my/certs/

# Set the external port for Traefik
#TRAEFIK_EXTERNAL_PORT="127.0.0.1:8443"

```

> ⚠️ **The `EMAIL_URL` variable is generated automatically.**
> It is assembled from `EMAIL_PROTOCOL`, `EMAIL_LOGIN`, `EMAIL_PASSWORD`, `EMAIL_SERVER`, `EMAIL_PORT`, etc.
> After changing any of these variables, you **must** run `make generate-email-url` or `make run` before starting the stack.
> This rebuilds `EMAIL_URL` and applies the new settings.
> Running `docker compose up` without a prior `make run` or `make generate-email-url` keeps the old value, and email delivery will fail.

### 2. Automatic Initialization and Launch

Install `make` if it is not already installed:

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

In all commands below, use the same external hostname as in `ABSOLUTE_SERVER`. If the cloud is deployed on a subdomain, use that full subdomain here.

##### In new releases starting with wb-2507 and testing (agent > 1.5.14)

```bash
wb-cloud-agent use-on-premise https://your-domain.com
```

> After `your-domain.com` becomes available on the network, the `wb-cloud-agent` command displays an activation link that allows you to link the controller to your cloud.

##### In older releases up to and including wb-2504 (agent <= 1.5.14)

Open the controller's console and execute the following command:
```bash
wb-cloud-agent add-provider your-onpremise-name https://your-domain.com/ https://your-domain.com/api-agent/v1/
```
Where:
- `your-onpremise-name` - provider name (can be any value)
- `https://your-domain.com/` - cloud address
- `https://your-domain.com/api-agent/v1/` - cloud agent address (always: `cloud address` + `/api-agent/v1/`)

> After `your-domain.com` becomes available on the network, go to the controller web UI, open Settings -> System, and use the activation link to link the controller to your cloud.

#### 2. Link the Controller to a User

Go to the controller’s web interface and select:

`Settings` -> `System` -> `Cloud Connection (your-onpremise-name)`

> If you do not see the System section in `Settings`, you do not have administrator rights.
>
> Go to `Settings` -> `Access Rights`, select `Administrator` -> `I accept all responsibility...` -> `Apply`.
>
> After this, the `System` section will appear in the menu.

Follow the link, log in to the cloud, and select the organization you want to add the controller to.

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

For JWT, place `private.pem` and `public.pem` in the `jwt` directory; otherwise, they will be generated automatically.

---

## 📦 Makefile Commands

Run all commands from the repo root.

### Main Commands

| Command                  | Description                                                  |
|--------------------------|--------------------------------------------------------------|
| `make help`              | Show all available commands                                  |
| `make check-env`         | Check required environment variables in `.env`               |
| `make check-certs`       | Check certificate availability and validity                  |
| `make generate-env`      | Generate missing tokens/secrets                              |
| `make generate-jwt`      | Generate or update JWT keys                                  |
| `generate-tunnel-token`  | Generate token for SSH/HTTP tunnels                          |
| `generate-influx-token`  | Generate Influx token                                        |
| `generate-django-secret` | Generate Django SECRET_KEY                                   |
| `generate-email-url`     | Generate/update email URL                                    |
| `make run`               | Full launch cycle (generate-env, build and start containers) |
| `make update`            | Stop containers, update images, rebuild and restart          |

### Usage Examples

```sh
# First launch (environment initialization and container startup)
make run

# Update the project to the latest state
make update

# Validate environment variables
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

Set the email and the full public hostname of the cloud. If the cloud will be available at `https://cloud.example.com`, then `DOMAIN_NAME=cloud.example.com`.

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

Certificates are saved to:

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

### 1. Set the following in `.env`:
```dotenv
TRAEFIK_EXTERNAL_PORT=127.0.0.1:8443
```

### 2. Proxy via an External Web Server

> ⚠️ **The `agent.*` subdomain uses mutual TLS (mTLS): the controller presents a hardware client certificate that Traefik verifies.**
> Standard L7 proxying (where Nginx terminates TLS) **does not forward the client certificate**, which breaks controller authentication.
> Therefore, all on-premise traffic must use **L4 TCP passthrough** via the `stream` module — Nginx forwards the raw TCP connection and Traefik handles TLS termination and mTLS verification itself.

#### Case A: Nginx is used only for on-premise traffic

Remove the existing `server { listen 443 ssl; ... }` block for on-premise domain names and add a `stream` block at the top level of your config:

```nginx
# /etc/nginx/nginx.conf — top-level, not inside http {}
stream {
    server {
        listen 443;
        ssl_preread on;
        proxy_pass 127.0.0.1:8443;
    }
}
```

All HTTPS requests on port 443 will be transparently forwarded to Traefik on port 8443.

#### Case B: Nginx also serves other sites on port 443

Use `ssl_preread` with a `map` to route by SNI: on-premise domain names go to Traefik, and everything else goes to a separate Nginx HTTP listener.

```nginx
# /etc/nginx/nginx.conf — top-level, not inside http {}
stream {
    map $ssl_preread_server_name $upstream {
        ~\.your-domain\.com  127.0.0.1:8443;  # on-premise → Traefik
        default              127.0.0.1:444;   # other sites → Nginx HTTP
    }

    server {
        listen 443;
        ssl_preread on;
        proxy_pass $upstream;
    }
}

# In the http {} block, other sites listen on port 444
server {
    listen 444 ssl;
    server_name your-domain.com;

    ssl_certificate     /etc/letsencrypt/live/your-domain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/your-domain.com/privkey.pem;

    location / {
        # your usual settings
    }
}
```

> Ensure port 8443 is bound only to 127.0.0.1 and not exposed publicly.

---
