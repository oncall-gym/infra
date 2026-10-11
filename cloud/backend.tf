terraform {
  backend "s3" {
    bucket  = "lab-tfstate-2a7416"
    key     = "cloud/terraform.tfstate"
    region  = "ru-central-1"
    profile = "cloudru"

    endpoints = {
      s3 = "https://s3.cloud.ru"
    }
    use_path_style = true

    # У cloud.ru нет сервисов AWS STS, IAM и EC2 metadata, отключаем обращения к ним
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true

    # Блокировка: файл .tflock рядом со state, чтобы два apply не шли одновременно
    use_lockfile = true
  }
}
