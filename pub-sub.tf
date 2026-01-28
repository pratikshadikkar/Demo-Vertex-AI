resource "google_pubsub_topic" "ingestion_topic" {
  name = "ingestion-events"
}
