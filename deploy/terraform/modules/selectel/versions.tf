terraform {
  required_version = ">= 1.6"
  required_providers {
    openstack = { source = "terraform-provider-openstack/openstack", version = ">= 3.0" }
    selectel  = { source = "selectel/selectel", version = ">= 9.0" }
  }
}
