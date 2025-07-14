Serverless WordCloud Generator on AWS
====================================

A serverless application that generates word clouds from text input using AWS Lambda, API Gateway, and S3.

Features
--------
- Fully serverless architecture
- Automatic scaling
- Secure S3 bucket configuration
- Dependency management via Lambda Layers
- Public API endpoint

Architecture
------------
API Gateway -> Lambda Function -> S3 Bucket -> Public URL

Prerequisites
-------------
- AWS account with CLI configured
- Terraform installed
- Docker (for building Lambda layer)
- Python 3.10

Deployment
----------

## 1. Build Lambda Layer
---------------------


Create layer with Docker (recommended)
mkdir -p python
docker run -v "$PWD":/var/task "public.ecr.aws/sam/build-python3.10" /bin/sh -c \
"pip install numpy==1.24.4 matplotlib==3.7.1 pillow==9.5.0 wordcloud==1.8.2.2 -t python \
&& find python -name '*.so' | xargs strip -Sx \
&& find python -type d -name '__pycache__' -exec rm -rf {} + \
&& rm -rf python/*.dist-info \
&& zip -r9 wordcloud-layer.zip python"

##2. Prepare Lambda Function
-------------------------
Create lambda_function.py with the provided code and zip it:

zip lambda-function.zip lambda_function.py

##3. Deploy Infrastructure
------------------------
terraform init
terraform apply

Usage
-----

API Endpoint:
POST https://[api-id].execute-api.us-east-1.amazonaws.com/prod/generate

Example Request:
curl -X POST "https://[api-id].execute-api.us-east-1.amazonaws.com/prod/generate" \
-H "Content-Type: application/json" \
-d '{"text":"hello world hello cloud hello serverless"}'

Example Response:
{
  "image_url": "https://your-bucket.s3.amazonaws.com/wordclouds/wordcloud_abc123.png"
}

Configuration
-------------
Environment Variables:
BUCKET_NAME - S3 bucket for word clouds

Troubleshooting
---------------

Common Issues:

1. Docker Permission Denied
   sudo usermod -aG docker $USER
   newgrp docker

2. Lambda Import Errors
   - Verify layer is properly built
   - Check CloudWatch logs

3. S3 Access Issues
   - Verify bucket policy allows public reads
   - Check IAM permissions

View Logs:
aws logs tail /aws/lambda/wordcloud-generator --follow

Clean Up
--------
To remove all resources:
terraform destroy

