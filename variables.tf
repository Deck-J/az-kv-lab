variable "subscription_id"     { type = string }
variable "tenant_id"           { type = string }
variable "resource_group_name" { type = string, default = "infra-lab-keyvaults" }
variable "location"            { type = string, default = "eastus" }
variable "env"                 { type = string, default = "prod" }
variable "eai"                 { type = string, default = "FXG" }