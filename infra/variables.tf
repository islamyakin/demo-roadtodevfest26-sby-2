# All inputs. Put your values in terraform.tfvars (copy terraform.tfvars.example; it is gitignored).

variable "project_id" {
  type        = string
  description = "Google Cloud project for the workshop (billing must be enabled)"
}

variable "region" {
  type        = string
  default     = "asia-southeast2"
  description = "Region for Cloud Run, Artifact Registry and Cloud Scheduler"
}
