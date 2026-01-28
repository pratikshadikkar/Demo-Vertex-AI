resource "google_storage_bucket" "raw_bucket" {
  name     = "${var.project_id}-raw-${var.env}"
  location = var.region

  uniform_bucket_level_access = true
  versioning {
    enabled = true
  }
}

resource "google_storage_bucket" "staging_bucket" {
  name     = "${var.project_id}-staging-${var.env}"
  location = var.region

  uniform_bucket_level_access = true
}
