terraform {
  required_version = ">= 1.6"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 6.0" }
    random = { source = "hashicorp/random" }
  }
}

# Провайдер AWS, направленный на S3 cloud.ru. Флаги skip_* отключают
# обращения к сервисам AWS, которых у cloud.ru нет (STS, IAM, метаданные).
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
  versioning_configuration { status = "Enabled" } # испорченный state можно откатить
}

# --- Снимки etcd ---
resource "aws_s3_bucket" "etcd_backup" {
  bucket              = "lab-etcd-backup-${random_id.suffix.hex}"
  object_lock_enabled = true # включается только при создании бакета
}

resource "aws_s3_bucket_versioning" "etcd_backup" {
  bucket = aws_s3_bucket.etcd_backup.id
  versioning_configuration { status = "Enabled" }
}

# 14 дней каждый снимок нельзя ни удалить, ни перезаписать.
# GOVERNANCE: s3e.admin в крайнем случае может снять блокировку, COMPLIANCE не может никто.
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

# aws_s3_bucket_lifecycle_configuration не дожидается подтверждения от cloud.ru:
# после записи он ждёт в ответе поля, которых этот S3 не возвращает.
# Поэтому правило записываем через AWS CLI; при изменении JSON оно перезапишется.
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
