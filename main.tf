provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

# Random suffix for globally unique storage account names
resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

# Resource Group to group all infrastructure resources for EpiSure
resource "azurerm_resource_group" "main" {
  name     = "episure-rg"
  location = "Central US"
}

# Azure Data Lake Gen2 - used to store all raw event data (important and non-important) from kits
resource "azurerm_storage_account" "datalake" {
  name                     = "episuredatalake${random_string.suffix.result}"
  resource_group_name      = azurerm_resource_group.main.name
  location                 = azurerm_resource_group.main.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  is_hns_enabled           = true
}

# Azure Event Hub Namespace - entry point for ingesting data at scale from mobile devices
resource "azurerm_eventhub_namespace" "main" {
  name                = "episureehnamespace${random_string.suffix.result}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "Basic"
  capacity            = 1
}

# Azure Event Hub - receives data from mobile apps, simulating sensor event uploads
resource "azurerm_eventhub" "main" {
  name                = "episureevents"
  namespace_name      = azurerm_eventhub_namespace.main.name
  resource_group_name = azurerm_resource_group.main.name
  partition_count     = 2
  message_retention   = 1
}

# Azure Storage Account - backing storage for Azure Function App
resource "azurerm_storage_account" "function" {
  name                     = "episurefunc${random_string.suffix.result}"
  resource_group_name      = azurerm_resource_group.main.name
  location                 = azurerm_resource_group.main.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

# Application Insights - used for full-stack monitoring, telemetry, and tracing
resource "azurerm_application_insights" "main" {
  name                = "episure-appinsights"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  application_type    = "web"

  lifecycle {
    ignore_changes = [tags]
  }
}

# Service Plan for hosting Azure Function (Linux, free tier)
resource "azurerm_service_plan" "main" {
  name                = "episure-plan"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  os_type             = "Linux"
  sku_name            = "Y1"
}

# Data source to get connection string after function storage account is created
data "azurerm_storage_account" "function" {
  name                = azurerm_storage_account.function.name
  resource_group_name = azurerm_resource_group.main.name
  depends_on          = [azurerm_storage_account.function]
}

# Azure Function App - processes real-time events, identifies critical cases, routes data accordingly
resource "azurerm_linux_function_app" "main" {
  name                       = "episure-function"
  resource_group_name        = azurerm_resource_group.main.name
  location                   = azurerm_resource_group.main.location
  service_plan_id            = azurerm_service_plan.main.id
  storage_account_name       = azurerm_storage_account.function.name
  storage_account_access_key = azurerm_storage_account.function.primary_access_key
  app_settings = {
    "FUNCTIONS_WORKER_RUNTIME"         = "python"
    "AzureWebJobsStorage"              = data.azurerm_storage_account.function.primary_connection_string
    "EVENT_HUB_CONN_STR"               = ""
    "APPINSIGHTS_INSTRUMENTATIONKEY"  = azurerm_application_insights.main.instrumentation_key
  }

  site_config {
    application_stack {
      python_version = "3.9"
    }
  }
}

# Azure Storage Queue - holds emergency events temporarily for async processing
resource "azurerm_storage_queue" "alerts" {
  name                 = "episure-alerts"
  storage_account_name = azurerm_storage_account.function.name
}

# Cosmos DB Account - stores processed, queryable event data (used in dashboard)
resource "azurerm_cosmosdb_account" "main" {
  name                = "episurecosmosdemo${random_string.suffix.result}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  offer_type          = "Standard"
  kind                = "GlobalDocumentDB"

  consistency_policy {
    consistency_level = "Session"
  }

  geo_location {
    location          = azurerm_resource_group.main.location
    failover_priority = 0
  }
}

# Cosmos DB SQL Database - required logical container for collections
resource "azurerm_cosmosdb_sql_database" "main" {
  name                = "episuredb"
  resource_group_name = azurerm_resource_group.main.name
  account_name        = azurerm_cosmosdb_account.main.name
}

# Cosmos DB SQL Container - stores structured, de-duplicated events for dashboard queries
resource "azurerm_cosmosdb_sql_container" "main" {
  name                  = "events"
  resource_group_name   = azurerm_resource_group.main.name
  account_name          = azurerm_cosmosdb_account.main.name
  database_name         = azurerm_cosmosdb_sql_database.main.name
  partition_key_paths   = ["/deviceId"]

  indexing_policy {
    indexing_mode = "consistent"
  }
}

# Output for Azure Function Storage connection string (for manual inspection if needed)
output "function_storage_connection_string" {
  value     = data.azurerm_storage_account.function.primary_connection_string
  sensitive = true
}
