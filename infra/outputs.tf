output "site_url" {
  value = "http://${aws_s3_bucket_website_configuration.site.website_endpoint}"
}

output "site_bucket" {
  value = aws_s3_bucket.site.bucket
}
