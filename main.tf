terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.1"
    }
  }
}

# Variables for better reusability
variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"
}

variable "project_name" {
  description = "Project name"
  type        = string
  default     = "wordcloud"
}

variable "lambda_timeout" {
  description = "Lambda function timeout in seconds"
  type        = number
  default     = 30
}

variable "lambda_memory_size" {
  description = "Lambda function memory size in MB"
  type        = number
  default     = 512
}

# Local values for consistent naming and tagging
locals {
  name_prefix = "${var.project_name}-${var.environment}"
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

provider "aws" {
  region = "us-east-1"
  
  default_tags {
    tags = local.common_tags
  }
}

# Random suffix for unique bucket name
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

# S3 bucket with proper configuration
resource "aws_s3_bucket" "wordcloud_bucket" {
  bucket = "${local.name_prefix}-bucket-${random_id.bucket_suffix.hex}"
}

# Separate S3 bucket configurations (AWS provider v4+ best practice)
resource "aws_s3_bucket_versioning" "wordcloud_bucket_versioning" {
  bucket = aws_s3_bucket.wordcloud_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "wordcloud_bucket_encryption" {
  bucket = aws_s3_bucket.wordcloud_bucket.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "wordcloud_bucket_lifecycle" {
  bucket = aws_s3_bucket.wordcloud_bucket.id

  rule {
    id     = "cleanup_old_versions"
    status = "Enabled"

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

resource "aws_s3_bucket_public_access_block" "bucket_access" {
  bucket = aws_s3_bucket.wordcloud_bucket.id

  block_public_acls       = false
  block_public_policy     = false  
  ignore_public_acls      = false
  restrict_public_buckets = false
}

# Improved bucket policy with conditions
resource "aws_s3_bucket_policy" "bucket_policy" {
  bucket = aws_s3_bucket.wordcloud_bucket.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicReadGetObject"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.wordcloud_bucket.arn}/*"
        Condition = {
          StringEquals = {
            "s3:ExistingObjectTag/public" = "true"
          }
        }
      },
      {
        Sid    = "LambdaObjectAccess"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.lambda_exec_role.arn
        }
        Action = [
          "s3:PutObject",
          "s3:PutObjectAcl",
          "s3:PutObjectTagging"
        ]
        Resource = "${aws_s3_bucket.wordcloud_bucket.arn}/*"
      }
    ]
  })
}

# CloudWatch Log Group for Lambda
resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = "/aws/lambda/${local.name_prefix}-generator"
  retention_in_days = 14
}

# IAM Role for Lambda with proper trust policy
resource "aws_iam_role" "lambda_exec_role" {
  name = "${local.name_prefix}-lambda-exec-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Principal = { 
        Service = "lambda.amazonaws.com" 
      }
      Effect = "Allow"
    }]
  })
}

# Attach basic execution policy
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Enhanced S3 policy for Lambda
resource "aws_iam_role_policy" "lambda_s3" {
  name = "${local.name_prefix}-lambda-s3-policy"
  role = aws_iam_role.lambda_exec_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3ObjectAccess"
        Effect = "Allow",
        Action = [
          "s3:PutObject",
          "s3:PutObjectAcl",
          "s3:PutObjectTagging",
          "s3:GetObject"
        ],
        Resource = "${aws_s3_bucket.wordcloud_bucket.arn}/*"
      },
      {
        Sid    = "S3BucketAccess"
        Effect = "Allow",
        Action = [
          "s3:ListBucket"
        ],
        Resource = aws_s3_bucket.wordcloud_bucket.arn
      }
    ]
  })
}

# Lambda Layer for dependencies
resource "aws_lambda_layer_version" "wordcloud_dependencies" {
  layer_name          = "${local.name_prefix}-dependencies"
  filename            = "wordcloud-layer.zip"
  source_code_hash    = filebase64sha256("wordcloud-layer.zip")
  compatible_runtimes = ["python3.10"]
  description         = "Dependencies for wordcloud generation"
}

# Lambda Function with enhanced configuration
resource "aws_lambda_function" "wordcloud_lambda" {
  function_name = "${local.name_prefix}-generator"
  role         = aws_iam_role.lambda_exec_role.arn
  handler      = "lambda_function.lambda_handler"
  runtime      = "python3.10"
  timeout      = var.lambda_timeout
  memory_size  = var.lambda_memory_size
  description  = "Generates wordcloud images from text input"
  
  filename         = "lambda-function.zip"
  source_code_hash = filebase64sha256("lambda-function.zip")
  
  layers = [aws_lambda_layer_version.wordcloud_dependencies.arn]
  
  environment {
    variables = {
      BUCKET_NAME = aws_s3_bucket.wordcloud_bucket.id
      LOG_LEVEL   = "INFO"
    }
  }
  
  # Enhanced monitoring
  tracing_config {
    mode = "Active"
  }

  depends_on = [
    aws_iam_role_policy_attachment.lambda_basic,
    aws_cloudwatch_log_group.lambda_logs,
  ]
}

# API Gateway with enhanced configuration
resource "aws_api_gateway_rest_api" "wordcloud_api" {
  name        = "${local.name_prefix}-api"
  description = "API for wordcloud generation service"
  
  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

# Usage Plan for API throttling
resource "aws_api_gateway_usage_plan" "wordcloud_usage_plan" {
  name         = "${local.name_prefix}-usage-plan"
  description  = "Usage plan for wordcloud API"

  api_stages {
    api_id = aws_api_gateway_rest_api.wordcloud_api.id
    stage  = aws_api_gateway_stage.prod.stage_name
  }

  quota_settings {
    limit  = 1000
    period = "DAY"
  }

  throttle_settings {
    rate_limit  = 10
    burst_limit = 20
  }
}

resource "aws_api_gateway_resource" "wordcloud_resource" {
  rest_api_id = aws_api_gateway_rest_api.wordcloud_api.id
  parent_id   = aws_api_gateway_rest_api.wordcloud_api.root_resource_id
  path_part   = "generate"
}

# OPTIONS method for CORS
resource "aws_api_gateway_method" "wordcloud_options" {
  rest_api_id   = aws_api_gateway_rest_api.wordcloud_api.id
  resource_id   = aws_api_gateway_resource.wordcloud_resource.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "wordcloud_options_integration" {
  rest_api_id = aws_api_gateway_rest_api.wordcloud_api.id
  resource_id = aws_api_gateway_resource.wordcloud_resource.id
  http_method = aws_api_gateway_method.wordcloud_options.http_method
  type        = "MOCK"
  
  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "wordcloud_options_response" {
  rest_api_id = aws_api_gateway_rest_api.wordcloud_api.id
  resource_id = aws_api_gateway_resource.wordcloud_resource.id
  http_method = aws_api_gateway_method.wordcloud_options.http_method
  status_code = "200"
  
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "wordcloud_options_integration_response" {
  rest_api_id = aws_api_gateway_rest_api.wordcloud_api.id
  resource_id = aws_api_gateway_resource.wordcloud_resource.id
  http_method = aws_api_gateway_method.wordcloud_options.http_method
  status_code = aws_api_gateway_method_response.wordcloud_options_response.status_code
  
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token'"
    "method.response.header.Access-Control-Allow-Methods" = "'OPTIONS,POST'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
}

# POST method with request validation
resource "aws_api_gateway_method" "wordcloud_method" {
  rest_api_id   = aws_api_gateway_rest_api.wordcloud_api.id
  resource_id   = aws_api_gateway_resource.wordcloud_resource.id
  http_method   = "POST"
  authorization = "NONE"
  
  request_validator_id = aws_api_gateway_request_validator.wordcloud_validator.id
  request_models = {
    "application/json" = aws_api_gateway_model.wordcloud_model.name
  }
}

# Request model for validation
resource "aws_api_gateway_model" "wordcloud_model" {
  rest_api_id  = aws_api_gateway_rest_api.wordcloud_api.id
  name         = "WordcloudRequest"
  content_type = "application/json"
  
  schema = jsonencode({
    "$schema" = "http://json-schema.org/draft-04/schema#"
    title     = "Wordcloud Request Schema"
    type      = "object"
    properties = {
      text = {
        type        = "string"
        minLength   = 1
        maxLength   = 10000
        description = "Text to generate wordcloud from"
      }
      options = {
        type = "object"
        properties = {
          width = {
            type    = "integer"
            minimum = 100
            maximum = 2000
          }
          height = {
            type    = "integer"
            minimum = 100
            maximum = 2000
          }
        }
      }
    }
    required = ["text"]
  })
}

resource "aws_api_gateway_request_validator" "wordcloud_validator" {
  name                        = "${local.name_prefix}-validator"
  rest_api_id                = aws_api_gateway_rest_api.wordcloud_api.id
  validate_request_body       = true
  validate_request_parameters = true
}

resource "aws_api_gateway_integration" "wordcloud_integration" {
  rest_api_id             = aws_api_gateway_rest_api.wordcloud_api.id
  resource_id             = aws_api_gateway_resource.wordcloud_resource.id
  http_method             = aws_api_gateway_method.wordcloud_method.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.wordcloud_lambda.invoke_arn
}

resource "aws_lambda_permission" "apigateway_permission" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.wordcloud_lambda.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.wordcloud_api.execution_arn}/*/*"
}

resource "aws_api_gateway_deployment" "wordcloud_deployment" {
  depends_on = [
    aws_api_gateway_integration.wordcloud_integration,
    aws_api_gateway_integration.wordcloud_options_integration
  ]
  rest_api_id = aws_api_gateway_rest_api.wordcloud_api.id
  
  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.wordcloud_resource.id,
      aws_api_gateway_method.wordcloud_method.id,
      aws_api_gateway_method.wordcloud_options.id,
      aws_api_gateway_integration.wordcloud_integration.id,
      aws_api_gateway_integration.wordcloud_options_integration.id,
      aws_api_gateway_model.wordcloud_model.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "prod" {
  deployment_id = aws_api_gateway_deployment.wordcloud_deployment.id
  rest_api_id   = aws_api_gateway_rest_api.wordcloud_api.id
  stage_name    = "prod"
  
  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gateway_logs.arn
    format = jsonencode({
      requestId      = "$requestId"
      ip             = "$requestId"
      requestTime    = "$requestTime"
      httpMethod     = "$httpMethod"
      resourcePath   = "$resourcePath"
      status         = "$status"
      responseLength = "$responseLength"
      responseTime   = "$responseTime"
    })
  }
  
  xray_tracing_enabled = true
}

# CloudWatch Log Group for API Gateway
resource "aws_cloudwatch_log_group" "api_gateway_logs" {
  name              = "API-Gateway-Execution-Logs_${aws_api_gateway_rest_api.wordcloud_api.id}/prod"
  retention_in_days = 14
}

# Enhanced outputs
output "api_gateway_endpoint" {
  description = "API Gateway endpoint URL"
  value       = "${aws_api_gateway_stage.prod.invoke_url}/generate"
}

output "s3_bucket_name" {
  description = "S3 bucket name for wordcloud storage"
  value       = aws_s3_bucket.wordcloud_bucket.bucket
}

output "s3_bucket_domain_name" {
  description = "S3 bucket domain name for direct access"
  value       = aws_s3_bucket.wordcloud_bucket.bucket_domain_name
}

output "lambda_function_name" {
  description = "Lambda function name"
  value       = aws_lambda_function.wordcloud_lambda.function_name
}

output "api_gateway_id" {
  description = "API Gateway REST API ID"
  value       = aws_api_gateway_rest_api.wordcloud_api.id
}
