terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
  }

  backend "s3" {
    bucket       = "nyt-game-solvers-tfstate-159820161626"
    key          = "prod/terraform.tfstate"
    region       = "eu-west-1"
    use_lockfile = true # native S3 locking, no DynamoDB table
    encrypt      = true
  }
}

provider "aws" {
  region = "eu-west-1"
}

data "aws_caller_identity" "current" {}

locals {
  name       = "nyt-game-solvers"
  account_id = data.aws_caller_identity.current.account_id
}
