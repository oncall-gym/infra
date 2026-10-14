terraform {
  required_version = ">= 1.6"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 6.0" }
    random = { source = "hashicorp/random" }
  }
}

# The AWS provider pointed at cloud.ru S3. The skip_* flags disable
# calls to AWS services that cloud.ru does not have (STS, IAM, metadata).
provider "aws" {
  profile                     = "cloudru"
  region                      = "ru-central-1"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
  s3_use_path_style           = true
  endpoints {
    s3 = "https://s3.cloud.ru"
  }
}

resource "random_id" "suffix" { byte_length = 3 }

# --- Terraform state ---
resource "aws_s3_bucket" "tfstate" {
  bucket = "lab-tfstate-${random_id.suffix.hex}"
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration { status = "Enabled" } # a broken state can be rolled back
}

# --- etcd snapshots ---
resource "aws_s3_bucket" "etcd_backup" {
  bucket              = "lab-etcd-backup-${random_id.suffix.hex}"
  object_lock_enabled = true # can only be enabled when the bucket is created
}

resource "aws_s3_bucket_versioning" "etcd_backup" {
  bucket = aws_s3_bucket.etcd_backup.id
  versioning_configuration { status = "Enabled" }
}

# For 14 days each snapshot can be neither deleted nor overwritten.
# GOVERNANCE: s3e.admin can lift the lock as a last resort; with COMPLIANCE nobody can.
resource "aws_s3_bucket_object_lock_configuration" "etcd_backup" {
  bucket = aws_s3_bucket.etcd_backup.id
  rule {
    default_retention {
      mode = "GOVERNANCE"
      days = 14
    }
  }
  depends_on = [aws_s3_bucket_versioning.etcd_backup]
}

locals {
  etcd_lifecycle = jsonencode({
    Rules = [{
      ID                          = "expire-old"
      Status                      = "Enabled"
      Filter                      = { Prefix = "" }
      Expiration                  = { Days = 30 }
      NoncurrentVersionExpiration = { NoncurrentDays = 7 }
    }]
  })
}

# aws_s3_bucket_lifecycle_configuration never gets a confirmation from cloud.ru:
# after the write it waits for response fields that this S3 does not return.
# So the rule is written with the AWS CLI; when the JSON changes it is written again.
resource "terraform_data" "etcd_lifecycle" {
  triggers_replace = [aws_s3_bucket.etcd_backup.id, local.etcd_lifecycle]

  provisioner "local-exec" {
    command = <<-EOT
      aws --profile cloudru --endpoint-url https://s3.cloud.ru \
        s3api put-bucket-lifecycle-configuration \
        --bucket ${aws_s3_bucket.etcd_backup.id} \
        --lifecycle-configuration '${local.etcd_lifecycle}'
    EOT
  }

  depends_on = [aws_s3_bucket_versioning.etcd_backup]
}

output "tfstate_bucket"     { value = aws_s3_bucket.tfstate.bucket }
output "etcd_backup_bucket" { value = aws_s3_bucket.etcd_backup.bucket }
