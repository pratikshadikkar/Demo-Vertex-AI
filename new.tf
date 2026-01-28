terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
  }
  required_version = ">= 1.3.0"
}

provider "google" {
  project = var.project_id
  region  = var.region
}

data "google_project" "this" {
  project_id = var.project_id
}

resource "google_project_service" "services" {
  for_each = toset([
    "storage.googleapis.com",
    "pubsub.googleapis.com",
    "dataflow.googleapis.com",
    "run.googleapis.com",
    "aiplatform.googleapis.com",
    "artifactregistry.googleapis.com",
  ])
  service = each.value
  disable_on_destroy = false
}

# Create GCS bucket for raw data
resource "google_storage_bucket" "docs_bucket" {
  name     = "${var.project_id}-embedded-raw-docs"
  location = var.region
  uniform_bucket_level_access = true
}

# Create Pub/Sub topic
resource "google_pubsub_topic" "ingest" {
  name = "embedded-doc-ingest"
}
# Create Pub/Sub subscription
resource "google_pubsub_subscription" "subscription" {
  name  = "gcs-doc-events-sub"
  topic = google_pubsub_topic.ingest.name

  ack_deadline_seconds = 10
}

# To Allow GCS to publish notifications into the topic
resource "google_pubsub_topic_iam_member" "allow_gcs_publish" {
  topic  = google_pubsub_topic.ingest.name
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:service-${data.google_project.this.number}@gs-project-accounts.iam.gserviceaccount.com"
}

# Send notifications for new/modified objects to Pub/Sub
resource "google_storage_notification" "docs_to_pubsub" {
  bucket         = google_storage_bucket.docs_bucket.name
  topic          = google_pubsub_topic.ingest.id
  payload_format = "JSON_API_V1"
  event_types    = ["OBJECT_FINALIZE"]
}


# Create IAM Service Account for Cloud Run
resource "google_service_account" "cloudrun_sa" {
  account_id   = "cloudrun-embeddings"
  display_name = "Cloud Run Embeddings Service Account"
}


resource "google_cloud_run_v2_service" "embed_svc" {
  name     = "embeddings-api"
  location = var.region

  template {
    service_account = google_service_account.cloudrun_sa.email
    containers {
      image = var.embed_service_image
      ports { container_port = 8080 }
      env { 
        name = "PROJECT_ID" 
        value = var.project_id 
      }
      env { 
        name = "REGION"     
        value = var.region
      }
    }
  }
}

# Grant GCS and Pub/Sub permissions to Cloud Run
resource "google_project_iam_member" "cloudrun_gcs" {
  project = var.project_id
  role    = "roles/storage.objectAdmin"
  member  = "serviceAccount:${google_service_account.cloudrun_sa.email}"
}

resource "google_project_iam_member" "cloudrun_pub" {
  project = var.project_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.cloudrun_sa.email}"
}

resource "google_project_iam_member" "cloudrun_sub" {
  project = var.project_id
  role    = "roles/pubsub.subscriber"
  member  = "serviceAccount:${google_service_account.cloudrun_sa.email}"
}

# Vertex AI Vector Search (Index + Endpoint)
resource "google_vertex_ai_index" "embeddings_index" {
  display_name = "my-embeddings-batch-index"
  description  = "Index for batch update embeddings search"
  region       = var.region
  metadata {
    contents_delta_uri  = "gs://${google_storage_bucket.docs_bucket.name}/contents"
    config {
      dimensions       = 256
      approximate_neighbors_count  = 100
      distance_measure_type = "DOT_PRODUCT_DISTANCE"
      shard_size = "SHARD_SIZE_SMALL"
      algorithm_config {
        tree_ah_config {
          leaf_node_embedding_count    = 1000
          leaf_nodes_to_search_percent = 0.05
        }
      }
    }
  }

  index_update_method = "BATCH_UPDATE"
   timeouts {
    create = "2h"
    update = "1h"
  }
}

resource "google_vertex_ai_index_endpoint" "vector_search_endpoint" {
  display_name = "my-embeddings-index-endpoint"
  region       = var.region
}

# Deploy index to endpoint
resource "google_vertex_ai_index_endpoint_deployed_index" "deploy_index" {
  deployed_index_id  = "my-vector-index-deployed"
  index_endpoint     = google_vertex_ai_index_endpoint.vector_search_endpoint.id
  index              = google_vertex_ai_index.embeddings_index.id
  region             = var.region # Required
}

# Dataflow: create service account
resource "google_service_account" "dataflow_sa" {
  account_id   = "dataflow-ingest-sa"
  display_name = "Dataflow SA - Ingest/Embed/Index"
}

#Grant GCS, Pub/Sub, AI permissions to Dataflow
resource "google_project_iam_member" "dataflow_pubsub_sub" {
  project = var.project_id
  role    = "roles/pubsub.subscriber"
  member  = "serviceAccount:${google_service_account.dataflow_sa.email}"
}

resource "google_project_iam_member" "dataflow_gcs_read" {
  project = var.project_id
  role    = "roles/storage.objectViewer"
  member  = "serviceAccount:${google_service_account.dataflow_sa.email}"
}

resource "google_project_iam_member" "dataflow_aiplatform_user" {
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_service_account.dataflow_sa.email}"
}

# Allow Dataflow to invoke the embeddings Cloud Run service - incomplete
resource "google_cloud_run_v2_service_iam_member" "embed_invoker" {
  location = var.region
  name     = google_cloud_run_v2_service.embed_svc.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.dataflow_sa.email}"
}

resource "google_dataflow_flex_template_job" "embeddings_processor" {
  name             = "embeddings-dataflow-pipeline"
  service_account_email   = google_service_account.dataflow_sa.email
  container_spec_gcs_path = var.dataflow_flex_template_spec_gcs_path



# Cloud Run: Semantic Search API (vector search,results) - Optional

resource "google_service_account" "search_sa" {
  account_id   = "search-sa"
  display_name = "CloudRun - Search API"
}

resource "google_project_iam_member" "search_aiplatform_user" {
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_service_account.search_sa.email}"
}

#Search API calls the embeddings service
resource "google_cloud_run_v2_service_iam_member" "embed_invoker_search" {
  location = var.region
  name     = google_cloud_run_v2_service.embed_svc.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.search_sa.email}"
}

resource "google_cloud_run_v2_service" "search_svc" {
  name     = "semantic-search-api"
  location = var.region

  template {
    service_account = google_service_account.search_sa.email
    containers {
      image = var.search_service_image
      ports { container_port = 8080 }

      env { 
        name = "PROJECT_ID"           
        value = var.project_id
      }
      env { 
        name = "REGION"               
        value = var.region 
      }
      env { 
        name = "VECTOR_INDEX_EP_ID"   
        value = google_vertex_ai_index_endpoint.vs_endpoint.id 
      }
      env { 
        name = "DEPLOYED_INDEX_ID"    
        value = google_vertex_ai_index_endpoint_deployed_index.vs_deploy.deployed_index_id 
      }
      env { 
        name = "EMBEDDINGS_URL"       
        value = google_cloud_run_v2_service.embed_svc.uri 
      }
    }
  }
}

# To make Search API public (optional)
resource "google_cloud_run_v2_service_iam_member" "search_public_invoker" {
  location = var.region
  name     = google_cloud_run_v2_service.search_svc.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "project_id" {
  type = string
  default = "project-732bb1ba-bdd8-4edb-b30"
}

variable "dataflow_flex_template_spec_gcs_path" {
  type        = string
  description = "GCS bucket URI for dataflow ingestion"
  
}

# Container images (Artifact Registry or GCR images you build/push)
variable "embed_service_image" {
  type        = string
  description = "Cloud Run image for embeddings service"
  default = "us-docker.pkg.dev/cloudrun/container/hello"
}

variable "search_service_image" {
  type        = string
  description = "Cloud Run image for semantic search API"
  default = "us-docker.pkg.dev/cloudrun/container/hello"
}

output "bucket_name" {
  value = google_storage_bucket.docs_bucket.name
}

output "pubsub_topic" {
  value = google_pubsub_topic.ingest.name
}

output "cloud_run_url" {
  value = google_cloud_run_v2_service.embeddings_service.uri
}
output "search_service_url" { 
  value = google_cloud_run_v2_service.search_svc.uri 
}

output "vector_index_id" {
  value = google_vertex_ai_index.embeddings_index.name
}

output "vector_index_endpoint_id" { 
  value = google_vertex_ai_index_endpoint.vs_endpoint.id 
}

output "deployed_index_id" { 
  value = google_vertex_ai_index_endpoint_deployed_index.vs_deploy.deployed_index_id 
}
