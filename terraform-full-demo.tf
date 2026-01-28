terraform {
  required_version = ">= 1.4.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.10"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}
##  variables.tf
variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "region" {
  description = "GCP Region"
  type        = string
  default     = "us-central1"
}

variable "env" {
  description = "Environment name"
  type        = string
  default     = "sandbox"
}

variable "dataflow_temp_location" {
  description = "GCS temp location for Dataflow"
  type        = string
}

## storage.tf (Raw + Staging buckets)
resource "google_storage_bucket" "raw" {
  project  = var.project_id
  name     = "${var.project_id}-raw-bucket"
  location = var.region

  uniform_bucket_level_access = true

  labels = {
    env  = var.env
    zone = "raw"
  }
}

resource "google_storage_bucket" "staging" {
  project  = var.project_id
  name     = "${var.project_id}-staging-bucket"
  location = var.region

  uniform_bucket_level_access = true

  labels = {
    env  = var.env
    zone = "staging"
  }
}
## pubsub.tf
resource "google_pubsub_topic" "raw_events" {
  project = var.project_id
  name    = "raw-gcs-events"
}

resource "google_pubsub_subscription" "raw_events_sub" {
  project = var.project_id
  name    = "raw-gcs-events-sub"
  topic  = google_pubsub_topic.raw_events.id
}
##  iam.tf (Enterprise IAM split)
resource "google_service_account" "ingestion_sa" {
  project      = var.project_id
  account_id   = "ingestion-sa"
  display_name = "Ingestion Pipeline Service Account"
}

resource "google_service_account" "dataflow_sa" {
  project      = var.project_id
  account_id   = "dataflow-sa"
  display_name = "Dataflow Service Account"
}

# ---- Storage access ----
resource "google_project_iam_member" "ingestion_storage" {
  project = var.project_id
  role    = "roles/storage.objectAdmin"
  member  = "serviceAccount:${google_service_account.ingestion_sa.email}"
}

# ---- Pub/Sub ----
resource "google_project_iam_member" "ingestion_pubsub" {
  project = var.project_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.ingestion_sa.email}"
}

resource "google_project_iam_member" "dataflow_pubsub" {
  project = var.project_id
  role    = "roles/pubsub.subscriber"
  member  = "serviceAccount:${google_service_account.dataflow_sa.email}"
}

# ---- Dataflow ----
resource "google_project_iam_member" "dataflow_worker" {
  project = var.project_id
  role    = "roles/dataflow.worker"
  member  = "serviceAccount:${google_service_account.dataflow_sa.email}"
}
##  eventarc.tf (GCS → Pub/Sub)
resource "google_eventarc_trigger" "raw_bucket_trigger" {
  project  = var.project_id
  name     = "raw-bucket-finalize-trigger"
  location = var.region

  matching_criteria {
    attribute = "type"
    value     = "google.cloud.storage.object.v1.finalized"
  }

  matching_criteria {
    attribute = "bucket"
    value     = google_storage_bucket.raw.name
  }

  destination {
    pubsub {
      topic = google_pubsub_topic.raw_events.id
    }
  }

  service_account = google_service_account.ingestion_sa.email
}
## dataflow.tf (Flex Template Job – default VPC)
resource "google_dataflow_flex_template_job" "etl_job" {
  project                 = var.project_id
  name                    = "etl-dataflow-job"
  region                  = var.region
  container_spec_gcs_path = "gs://my-templates/dataflow/etl-spec.json"

  parameters = {
    input_subscription = google_pubsub_subscription.raw_events_sub.id
    output_bucket      = google_storage_bucket.staging.name
  }

  service_account_email = google_service_account.dataflow_sa.email
  temp_location         = var.dataflow_temp_location

  labels = {
    env = var.env
    app = "data-pipeline"
  }
}

##  outputs.tf
output "raw_bucket_name" {
  value = google_storage_bucket.raw.name
}

output "staging_bucket_name" {
  value = google_storage_bucket.staging.name
}

output "pubsub_topic" {
  value = google_pubsub_topic.raw_events.name
}
