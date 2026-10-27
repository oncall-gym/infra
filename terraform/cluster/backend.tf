terraform {
  backend "s3" {
    bucket  = "lab-tfstate-2a7416"
    key     = "talos/terraform.tfstate"
    region  = "ru-central-1"
    profile = "cloudru"

    endpoints = {
      s3 = "https://s3.cloud.ru"
    }
    use_path_style = true

    # cloud.ru has no AWS STS, IAM or EC2 metadata services, so calls to them are disabled
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true

    # Locking: a .tflock file next to the state, so that two applies never run at once
    use_lockfile = true
  }
}
