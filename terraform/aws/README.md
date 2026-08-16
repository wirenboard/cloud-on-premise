# Wiren Board Cloud On-Premise on AWS

Terraform module that deploys the cloud onto a single EC2 instance: the same
Docker Compose stack as a manual installation, with the DNS records, the
wildcard TLS certificate and its renewal set up for you.

## What you need

- an AWS account and credentials with rights to create EC2, IAM, Route53, Secrets Manager and (optionally) SES resources;
- a domain, or a subdomain, **delegated to a Route53 hosted zone** — the certificate is issued over the DNS-01 challenge, which is the only way to get the `*.ssh`, `*.http` and `*.apps` wildcards;
- Terraform 1.5+ or OpenTofu.

If the zone is not in Route53, this module does not apply. Install manually and
bring your own certificate — see the repository README.

## Usage

```hcl
module "wb_cloud" {
  source = "github.com/wirenboard/cloud-on-premise//terraform/aws?ref=v2.0.0"

  domain          = "cloud.example.com"
  route53_zone_id = "Z0123456789ABCDEFGHIJ"
  admin_email     = "admin@example.com"

  wb_cloud_version = "2.0.0"
}
```

```bash
terraform init
terraform apply
```

The first installation takes 15–20 minutes: the instance boots, pulls the
release, issues the certificate and starts twenty containers. Follow it with the
`install_log_command` output.

When it is done:

```bash
# administrator, Grafana, tunnel dashboard and database credentials
terraform output -raw credentials_command | bash
```

Open `https://<domain>`, sign in with `admin_email` and the `ADMIN_PASSWORD`
from that secret, and add your first controller.

## Email

Off by default: invitations and password resets are handled through the admin
panel, and nothing needs an SMTP server.

Turn it on with your own SMTP:

```hcl
email_enabled = true

smtp = {
  host               = "smtp.example.com"
  user               = "cloud@example.com"
  password           = var.smtp_password
  notifications_from = "cloud@example.com"
}
```

Or let the module set up SES for the domain — identity, DKIM, MAIL FROM, SPF and
DMARC records, and SMTP credentials for the cloud:

```hcl
email_enabled = true
enable_ses    = true
```

> A new SES account sits in the sandbox and only delivers to verified addresses.
> Production access is a request to AWS support that cannot be automated.

## Trying a change before it is released

By default the module installs a published release and reads the installer from
the matching tag. To test something that has not shipped yet, point it at a
branch — of this repository or of a fork:

```hcl
wb_cloud_ref  = "my-branch"
wb_cloud_repo = "wirenboard/cloud-on-premise"  # or your fork

# Untrusted by browsers and controllers, but not rate-limited.
letsencrypt_staging = true
```

Let's Encrypt allows five certificates a week for the same set of names, and a
few failed runs against a real domain use that up — keep `letsencrypt_staging`
on while iterating and turn it off for the run that has to be real. Switching
back means deleting `/etc/letsencrypt/live/<domain>` on the instance and
re-running the installer, or building a fresh instance.

## Upgrades

**Not through `terraform apply`.** The module deliberately ignores changes to
the AMI and the user data: recreating the instance is not how this stack is
upgraded, and doing it by accident would leave the databases behind on a volume
nobody mounts.

```bash
terraform output -raw shell_command | bash
cd /opt/wb-cloud && make update
```

Terraform owns the infrastructure. The cloud owns its own lifecycle — `make
update`, `make upgrade`, `make backup` all work exactly as they do on a manual
installation.

## What gets created

| Resource | Purpose |
|---|---|
| EC2 instance, `t3.large` by default | runs the stack. The images need `x86-64-v2`, so Graviton does not work |
| Elastic IP | a fixed address for the DNS records and for the controllers |
| EBS volume at `/var/lib/docker` | databases, object storage, Grafana. Separate from the root disk and protected from destroy |
| 5 Route53 A records | the host, plus the `*`, `*.ssh`, `*.http` and `*.apps` wildcards |
| Security group | 443 and the tunnel port open, dashboard closed, SSH only with `key_name` |
| IAM role | SSM access, DNS-01 in this one zone, writing the credentials secret |
| Secrets Manager secret | the credentials the installer generated |
| DLM policy | daily snapshots of the data volume |

Nothing is written to a shell history and no generated password passes through
the Terraform state: the instance creates them and publishes them itself.

Setting `admin_password` explicitly is the one exception — that value does land
in the state, so leave it unset unless you have a reason.

## Access

Port 22 stays closed and there is no SSH key by default. Shell access goes
through SSM Session Manager:

```bash
terraform output -raw shell_command | bash
```

## Data and backups

The data volume carries `prevent_destroy` and survives `terraform destroy` —
delete it by hand once you are sure. Daily snapshots cover a lost instance or
disk; for a restorable dump of the databases before an upgrade use `make backup`
on the instance, which is what the upgrade path expects.

## Cost

The default configuration is roughly one `t3.large`, a 50 GiB gp3 volume, the
Elastic IP and the snapshots. Traffic depends on how many controllers report in.
