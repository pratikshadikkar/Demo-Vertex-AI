resource "google_cloud_run_service" "etl_trigger" {
  name     = "etl-trigger"
  location = var.region

  template {
    spec {
      service_account_name = google_service_account.ingestion_sa.email

      containers {
        image = "gcr.io/cloudrun/hello"  # demo image
      }
    }
  }

  traffics {
    percent         = 100
    latest_revision = true
  }
}

resource "google_cloud_run_service" "gateway_service" {
  name     = "vertex-gateway"
  location = var.region

  template {
    spec {
      service_account_name = google_service_account.gateway_sa.email

      containers {
        image = "gcr.io/cloudrun/hello"  # demo image
      }
    }
  }

  traffics {
    percent         = 100
    latest_revision = true
  }
}
