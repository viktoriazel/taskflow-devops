variable "name" {
  description = "Name of the Jenkins node IAM role"
  type        = string
}

variable "tags" {
  description = "Tags applied to the IAM role"
  type        = map(string)
  default     = {}
}
