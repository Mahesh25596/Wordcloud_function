provider "aws" {
  region = "us-east-1"
}

# S3 Bucket to store WordCloud images
resource "aws_s3_bucket" "wordcloud_bucket" {
  bucket = "serverless-wordcloud-bucket"
  acl    = "public-read"

  website {
    index_document = "index.html"
  }
}

# IAM Role for Lambda
resource "aws_iam_role" "lambda_exec_role" {
  name = "lambda_exec_role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_iam_policy_attachment" "lambda_s3_policy" {
  name       = "lambda_s3_policy_attachment"
  roles      = [aws_iam_role.lambda_exec_role.name]
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

# Lambda Function
resource "aws_lambda_function" "wordcloud_lambda" {
  filename         = "wordcloud_function.zip" # This should be the zipped Python code.
  function_name    = "wordcloud_function"
  role             = aws_iam_role.lambda_exec_role.arn
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.9"
  timeout          = 15

  source_code_hash = filebase64sha256("wordcloud_function.zip")

  environment {
    variables = {
      BUCKET_NAME = aws_s3_bucket.wordcloud_bucket.bucket
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
  rest_api_id = aws_api_gateway_rest_api.wordcloud_api.id
  resource_id = aws_api_gateway_resource.wordcloud_resource.id
  http_method = aws_api_gateway_method.wordcloud_method.http_method
  type        = "AWS_PROXY"

  integration_http_method = "POST"
  uri                     = aws_lambda_function.wordcloud_lambda.invoke_arn
}

resource "aws_lambda_permission" "apigateway_permission" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.wordcloud_lambda.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.wordcloud_api.execution_arn}/*/*"
}

output "api_gateway_endpoint" {
  value = "${aws_api_gateway_rest_api.wordcloud_api.execution_arn}/generate"
}

output "s3_bucket_name" {
  value = aws_s3_bucket.wordcloud_bucket.bucket
}

