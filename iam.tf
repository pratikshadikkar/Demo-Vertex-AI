resource "google_service_account" "ingestion_sa" {
  account_id   = "ingestion-sa"
  display_name = "Ingestion Pipeline SA"
}

resource "google_service_account" "gateway_sa" {
  account_id   = "gateway-sa"
  display_name = "Gateway Pipeline SA"
}

resource "google_project_iam_member" "ingestion_storage" {
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.ingestion_sa.email}"
}

resource "google_project_iam_member" "eventarc_receiver" {
  role   = "roles/eventarc.eventReceiver"
  member = "serviceAccount:${google_service_account.ingestion_sa.email}"
}

resource "google_project_iam_member" "gateway_eventarc" {
  role   = "roles/eventarc.eventReceiver"
  member = "serviceAccount:${google_service_account.gateway_sa.email}"
}
