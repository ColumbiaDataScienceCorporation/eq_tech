variable "subscription_id" {
  default = "0702e805-0c66-4bbd-9eb4-47ce81ecb369"
}

variable "tenant_id" {
  default = "e5e33b11-e89c-466a-bf06-e94151676845"
}

variable "location" {
  default = "centralus"
}

variable "resource_group" {
  default = "eq-tech-rg"
}

variable "aks_cluster_name" {
  default = "eq-tech-aks"
}

variable "acr_name" {
  # Must be globally unique, lowercase alphanumeric only
  default = "eqtechacr"
}

variable "postgres_server_name" {
  default = "eq-tech-pg"
}

variable "postgres_admin_user" {
  default = "airflow_admin"
}

variable "postgres_admin_password" {
  sensitive = true
}

variable "keyvault_name" {
  default = "eq-tech-kv"
}

variable "environment" {
  description = "Deployment environment: dev, uat, or prod"
  type        = string
  default     = "dev"
}

variable "aks_node_count" {
  description = "Number of AKS system nodes"
  type        = number
  default     = 2
}

variable "aks_vm_size" {
  description = "AKS node VM size"
  type        = string
  default     = "Standard_D4pls_v5"
}

variable "postgres_sku" {
  description = "PostgreSQL Flexible Server SKU"
  type        = string
  default     = "B_Standard_B1ms"
}

variable "postgres_storage_mb" {
  description = "PostgreSQL storage in MB"
  type        = number
  default     = 32768
}
