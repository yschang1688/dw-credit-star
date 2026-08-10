terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  features {
    resource_group {
      # 刻意打開：destroy 時若資源群組裡還留著本設定以外的東西，
      # 預設行為會擋下刪除、留下一個「以為拆乾淨了」的殘留群組。
      # 這個環境是短命的，群組裡本來就不該有別的東西。
      prevent_deletion_if_contains_resources = false
    }
  }
  subscription_id = var.subscription_id
}
