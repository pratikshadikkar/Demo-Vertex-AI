resource "google_storage_bucket" "dataflow_templates" {
  name     = "${var.project_id}-dataflow-templates-${var.env}"
  location = var.region

  uniform_bucket_level_access = true
}
