variable "domain" {
  description = "Full public hostname of the cloud, e.g. cloud.example.com. Becomes ABSOLUTE_SERVER."
  type        = string
}

variable "route53_zone_id" {
  description = "Route53 hosted zone that holds the domain. The instance issues its wildcard certificate through this zone over DNS-01."
  type        = string
}

variable "admin_email" {
  description = "Cloud administrator. In 2.x the email is also the login."
  type        = string
}

variable "admin_password" {
  description = "Administrator password. Leave null and the instance generates one and writes it into Secrets Manager — a value set here lands in the Terraform state instead."
  type        = string
  default     = null
  sensitive   = true
}

variable "name_prefix" {
  description = "Prefix for the names of the created resources."
  type        = string
  default     = "wb-cloud"
}

variable "wb_cloud_version" {
  description = "Release to install, e.g. \"2.0.0\". Null installs the latest one; pin it for a reproducible deployment."
  type        = string
  default     = null
}

variable "wb_cloud_ref" {
  description = "Branch or tag to install instead of a release, and where the installer itself is taken from. For trying a change before it ships — leave null in production."
  type        = string
  default     = null
}

variable "wb_cloud_repo" {
  description = "Repository the release and the installer come from. Point it at a fork to test one."
  type        = string
  default     = "wirenboard/cloud-on-premise"
}

variable "letsencrypt_staging" {
  description = "Issue the certificate from the Let's Encrypt staging CA: untrusted by browsers and controllers, but not rate-limited. For repeated test runs against the same domain."
  type        = bool
  default     = false
}

variable "instance_type" {
  description = "The images require x86-64-v2, so Graviton (arm64) types do not work. t3.large matches the recommended configuration."
  type        = string
  default     = "t3.large"
}

variable "root_volume_size" {
  description = "Root disk, GiB. Holds the system only — the cloud's data lives on the data volume."
  type        = number
  default     = 20
}

variable "data_volume_size" {
  description = "Data disk, GiB, mounted at /var/lib/docker. Sized by how long metrics are kept."
  type        = number
  default     = 50
}

variable "vpc_id" {
  description = "VPC to deploy into. Null uses the account's default VPC."
  type        = string
  default     = null
}

variable "subnet_id" {
  description = "Subnet to deploy into. Null picks one from the default VPC. It must be public — controllers connect to the cloud."
  type        = string
  default     = null
}

variable "allowed_web_cidrs" {
  description = "Who may reach 443. Controllers and browsers both come through it."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "allowed_tunnel_cidrs" {
  description = "Who may reach the tunnel port. Controllers open the connection towards the cloud."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "tunnel_dashboard_cidrs" {
  description = "Who may reach the tunnel dashboard. Empty keeps the port closed, which is the recommended setting."
  type        = list(string)
  default     = []
}

variable "tunnel_port" {
  description = "Tunnel port published on the host."
  type        = number
  default     = 7107
}

variable "tunnel_dashboard_port" {
  description = "Tunnel dashboard port."
  type        = number
  default     = 7501
}

variable "email_enabled" {
  description = "Turn on email. With it off, invitations and password resets are handled through the admin panel and no SMTP is needed."
  type        = bool
  default     = false
}

variable "enable_ses" {
  description = "Set up SES for the domain: identity, DKIM, the DNS records and SMTP credentials for the cloud. Requires email_enabled."
  type        = bool
  default     = false
}

variable "smtp" {
  description = "External SMTP, used when email_enabled is on and enable_ses is off."
  type = object({
    host               = string
    port               = optional(number, 587)
    user               = optional(string, "")
    password           = optional(string, "")
    use_ssl            = optional(bool, false)
    notifications_from = string
  })
  default   = null
  sensitive = true
}

variable "metrics_retention_days" {
  description = "How long controller metrics are kept. Set before the first start: on a running installation it can be lowered but not raised."
  type        = number
  default     = 30
}

variable "extra_env" {
  description = "Any further .env variables — branding, worker concurrency, and so on. Passed through to the installer as they are."
  type        = map(string)
  default     = {}
}

variable "enable_daily_snapshots" {
  description = "Daily snapshots of the data volume through Data Lifecycle Manager."
  type        = bool
  default     = true
}

variable "snapshot_retention_days" {
  description = "How many days of snapshots to keep."
  type        = number
  default     = 7
}

variable "key_name" {
  description = "EC2 key pair for SSH. Null leaves port 22 closed and access goes through SSM Session Manager."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags added to every created resource."
  type        = map(string)
  default     = {}
}
