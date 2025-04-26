terraform {
  required_providers {
    # AzureRM for Azure resources
    azurerm = { source = "hashicorp/azurerm" version = "~> 3.0" }
    # AzureAD for AAD objects
    azuread = { source = "hashicorp/azuread" version = "~> 2.0" }
    # External data source for JSON import
    external = { source = "hashicorp/external" version = "~> 2.0" }
    # Random for password generation
    random  = { source = "hashicorp/random" version = "~> 3.0" }
  }
}

# Configure providers
provider "azurerm" { features = {} }
provider "azuread" {}

# Retrieve current tenant/subscription
data "azurerm_client_config" "current" {}

data "azurerm_resource_group" "rg" {
  name = var.resource_group_name
}

# VARIABLES
variable "resource_group_name" {
  description = "Resource group to host Key Vaults"
  type        = string
  default     = "infra-lab-keyvaults"
}

variable "location" {
  description = "Azure region for Key Vaults"
  type        = string
  default     = "eastus"
}

variable "env" {
  description = "Environment label (dev, qa, prod)"
  type        = string
  default     = "prod"
}

variable "eai" {
  description = "EAI identifier prefix"
  type        = string
  default     = "FXG"
}

# IMPORT ACCOUNT DATA
data "external" "accounts" {
  program = ["bash","-c","cat ${path.module}/accounts.json"]
}

locals {
  accounts     = jsondecode(data.external.accounts.result)
  vault_names  = distinct([for a in local.accounts: "kv-${var.eai}-${a.deviceName}-${var.env}"])
}

# LAB AD GROUPS
# Human reader group
resource "azuread_group" "reader_group" {
  display_name     = "DSOE-Reader"
  security_enabled = true
}
# Human writer group
resource "azuread_group" "writer_group" {
  display_name     = "DSOE-Writer"
  security_enabled = true
}
# External DBA write-only group
resource "azuread_group" "dba_group" {
  display_name     = "DBA-Write-Only"
  security_enabled = true
}

# MACHINE IDENTITY FOR AUTOMATION
# Create an Azure AD App registration
resource "azuread_application" "pipeline_app" {
  display_name = "DSOE-Pipeline-App"
}
# Create the Service Principal
resource "azuread_service_principal" "pipeline_sp" {
  application_id = azuread_application.pipeline_app.application_id
}
# Generate a strong password for the SP
resource "random_password" "pipeline_pwd" {
  length  = 32
  special = true
}
# Assign the password to the SP
resource "azuread_service_principal_password" "pipeline_sp_pwd" {
  service_principal_id = azuread_service_principal.pipeline_sp.id
  value                = random_password.pipeline_pwd.result
  end_date_relative    = "8760h"  # 1 year
}

# Create one Key Vault per deviceName
resource "azurerm_key_vault" "vaults" {
  for_each            = toset(local.vault_names)
  name                = each.key
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = var.location
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  soft_delete_retention_days = 90
  purge_protection_enabled   = true
}

# ASSIGN ROLES on each vault
# Human readers
resource "azurerm_role_assignment" "readers" {
  for_each             = azurerm_key_vault.vaults
  scope                = each.value.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azuread_group.reader_group.id
}
# Human writers
resource "azurerm_role_assignment" "writers" {
  for_each             = azurerm_key_vault.vaults
  scope                = each.value.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = azuread_group.writer_group.id
}
# External DBA write-only
resource "azurerm_role_assignment" "dba_writers" {
  for_each             = azurerm_key_vault.vaults
  scope                = each.value.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = azuread_group.dba_group.id
}
# Pipeline SP (machine identity) read-only
resource "azurerm_role_assignment" "pipeline_readers" {
  for_each             = azurerm_key_vault.vaults
  scope                = each.value.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azuread_service_principal.pipeline_sp.id
}

# IMPORT account secrets into each vault
resource "azurerm_key_vault_secret" "secrets" {
  for_each = {
    for acct in local.accounts :
    "${acct.deviceName}-${acct.applicationId}-${acct.accountName}" => acct
  }

  name         = each.key
  value        = each.value.Account_Password
  key_vault_id = azurerm_key_vault.vaults["kv-${var.eai}-${each.value.deviceName}-${var.env}"].id

  tags = {
    appId    = each.value.applicationId
    deviceId = each.value.DeviceIDNUM
    policy   = each.value.Account_Policy_Group_IDs
    rotation = "none"
  }

  lifecycle {
    # Ignore any external change to secret value to keep static
    ignore_changes = [value]
  }
}

# OUTPUTS for pipeline credentials
output "pipeline_sp_app_id" {
  description = "Application (Client) ID for automation SP"
  value       = azuread_application.pipeline_app.application_id
}
output "pipeline_sp_password" {
  sensitive   = true
  description = "Password for the automation SP"
  value       = random_password.pipeline_pwd.result
}
