variable "aws_region" {
  description = "The AWS region to deploy the resources"
  type        = string
}

variable "route53_zone" {
  description = "The Route53 zone ID to deploy the resources"
  type        = string
}

variable "route53_domain_name" {
  description = "The Route53 domain name to deploy the resources"
  type        = string
}