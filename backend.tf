terraform {
  backend "azurerm" {
    resource_group_name  = "rg-infra-gm-tma-infra-devsecops-01"
    storage_account_name = "stinfraf9vvq"
    container_name       = "infra-coder-templates-tfstate"
    key                  = "kubernetes-custom.tfstate"
    environment          = "usgovernment"
  }
}
