resource "google_eventarc_trigger" "raw_to_pubsub" {
  name     = "raw-bucket-trigger"
  location = var.region

  matching_criteria {
    attribute = "type"
    value     = "google.cloud.storage.object.v1.finalized"
  }

  matching_criteria {
    attribute = "bucket"
    value     = google_storage_bucket.raw_bucket.name
  }

  destination {
    pubsub {
      topic = google_pubsub_topic.ingestion_topic.id
    }
  }

  service_account = google_service_account.ingestion_sa.email
}

resource "google_eventarc_trigger" "staging_to_gateway" {
  name     = "staging-bucket-trigger"
  location = var.region

  matching_criteria {
    attribute = "type"
    value     = "google.cloud.storage.object.v1.finalized"
  }

  matching_criteria {
    attribute = "bucket"
    value     = google_storage_bucket.staging_bucket.name
  }

  destination {
    cloud_run_service {
      service = google_cloud_run_service.gateway_service.name
      region  = var.region
    }
  }

  service_account = google_service_account.gateway_sa.email
}

