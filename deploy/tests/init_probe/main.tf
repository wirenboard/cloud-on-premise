terraform {
  required_version = ">= 1.6"
  required_providers {
    yandex    = { source = "yandex-cloud/yandex", version = ">= 0.250" }
    openstack = { source = "terraform-provider-openstack/openstack", version = ">= 3.4" }
    selectel  = { source = "selectel/selectel", version = ">= 9.7" }
    aws       = { source = "hashicorp/aws", version = ">= 6.0" }
  }
}
