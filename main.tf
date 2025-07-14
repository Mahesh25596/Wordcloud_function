provider "aws" {
  region = "us-east-1"
}

# Random suffix for unique bucket name
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

# S3 Bucket with ACLs disabled (modern approach)
resource "aws_s3_bucket" "wordcloud_bucket" {
  bucket = "serverless-wordcloud-bucket-${random_id.bucket_suffix.hex}"
}

# Block ALL public access (we'll use bucket policy instead)
resource "aws_s3_bucket_public_access_block" "bucket_access" {
  bucket = aws_s3_bucket.wordcloud_bucket.id

  block_public_acls       = true
  block_public_policy     = false  # We need this false to allow our bucket policy
  ignore_public_acls      = true
  restrict_public_buckets = false
}

# Bucket policy for public read access to objects
resource "aws_s3_bucket_policy" "bucket_policy" {
  bucket = aws_s3_bucket.wordcloud_bucket.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.wordcloud_bucket.arn}/*"
      },
      {
        Effect    = "Allow"
        Principal = {
          AWS = aws_iam_role.lambda_exec_role.arn
        }
        Action    = [
          "s3:PutObject",
          "s3:PutObjectAcl"
        ]
        Resource  = "${aws_s3_bucket.wordcloud_bucket.arn}/*"
      }
    ]
  })
}

# IAM Role for Lambda
resource "aws_iam_role" "lambda_exec_role" {
  name = "lambda_exec_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
      Effect = "Allow"
    }]
  })
}

# Attach policies
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# More restricted S3 policy instead of full access
resource "aws_iam_role_policy" "lambda_s3" {
  name = "lambda_s3_policy"
  role = aws_iam_role.lambda_exec_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "s3:PutObject",
          "s3:PutObjectAcl",
          "s3:GetObject"
        ],
        Resource = "${aws_s3_bucket.wordcloud_bucket.arn}/*"
      }
    ]
  })
}

# Lambda Layer for dependencies
resource "aws_lambda_layer_version" "wordcloud_dependencies" {
  layer_name          = "wordcloud-dependencies"
  filename            = "wordcloud-layer.zip"
  source_code_hash    = filebase64sha256("wordcloud-layer.zip")
  compatible_runtimes = ["python3.10"]
}

# Lambda Function
resource "aws_lambda_function" "wordcloud_lambda" {
  function_name    = "wordcloud-generator"
  role             = aws_iam_role.lambda_exec_role.arn
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.10"
  timeout          = 30
  memory_size      = 512
  
  filename         = "lambda-function.zip"  # Your Lambda code zip file
  source_code_hash = filebase64sha256("lambda-function.zip")
  
  layers = [aws_lambda_layer_version.wordcloud_dependencies.arn]
  
  environment {
    variables = {
      BUCKET_NAME = aws_s3_bucket.wordcloud_bucket.id
    }
  }
}

# API Gateway
resource "aws_api_gateway_rest_api" "wordcloud_api" {
  name = "wordcloud-api"
}

resource "aws_api_gateway_resource" "wordcloud_resource" {
  rest_api_id = aws_api_gateway_rest_api.wordcloud_api.id
  parent_id   = aws_api_gateway_rest_api.wordcloud_api.root_resource_id
  path_part   = "generate"
}

resource "aws_api_gateway_method" "wordcloud_method" {
  rest_api_id   = aws_api_gateway_rest_api.wordcloud_api.id
  resource_id   = aws_api_gateway_resource.wordcloud_resource.id
  http_method   = "POST"
  authorization = "NONE"
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
  depends_on  = [aws_api_gateway_integration.wordcloud_integration]
  rest_api_id = aws_api_gateway_rest_api.wordcloud_api.id
  
  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.wordcloud_resource.id,
      aws_api_gateway_method.wordcloud_method.id,
      aws_api_gateway_integration.wordcloud_integration.id
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
}

output "api_gateway_endpoint" {
  value = "${aws_api_gateway_stage.prod.invoke_url}/generate"
}

output "s3_bucket_name" {
  value = aws_s3_bucket.wordcloud_bucket.bucket
}
