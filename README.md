# Serverless Word Cloud Generator

This project provides a serverless solution for generating word clouds from input text. The solution uses AWS services including Lambda, API Gateway, and S3, provisioned via Terraform.

## Features
- Accepts text input via an API Gateway endpoint.
- Generates a word cloud image using a Lambda function.
- Stores the image in an S3 bucket and returns a public URL.

## Prerequisites
- AWS CLI configured with necessary permissions.
- Terraform installed on your system.
- Python 3.9 environment with required libraries for packaging the Lambda function (`wordcloud`, `matplotlib`, `boto3`).

## Setup Instructions

### 1. Clone the Repository
```bash
git clone https://github.com/Mahesh25596/Wordcloud_function.git
```
### 2. Deploy Terraform Resources
Navigate to the Terraform directory.
Initialize Terraform:
```bash
terraform init
```
Deploy the resources:
```bash
terraform apply
```
Note the API Gateway endpoint and S3 bucket name from the outputs.
###3. Package Lambda Function
Install required Python libraries:
```bash
pip install wordcloud matplotlib boto3 -t .
```
Create a zip file:
```bash
zip -r wordcloud_function.zip .
```
Replace the file path in the Terraform script for wordcloud_function.zip.
4. Test the API
Use a tool like Postman or curl to send a POST request to the API Gateway endpoint with the following JSON body:
```
{
  "text": "Your input text here to generate the word cloud"
}
```
5. View the Word Cloud
The API response will contain the public URL of the generated word cloud image. Open the URL in a browser to view it.
