import json
import boto3
import os
from wordcloud import WordCloud
import matplotlib.pyplot as plt

s3 = boto3.client('s3')
bucket_name = os.environ['BUCKET_NAME']

def lambda_handler(event, context):
    try:
        # Parse input text
        body = json.loads(event['body'])
        text = body.get('text', '')
        
        if not text:
            return {
                'statusCode': 400,
                'body': json.dumps({'error': 'Text input is required'})
            }
        
        # Generate WordCloud
        wordcloud = WordCloud(width=800, height=400, background_color='white').generate(text)
        
        # Save WordCloud image
        image_path = '/tmp/wordcloud.png'
        wordcloud.to_file(image_path)
        
        # Upload to S3
        s3_key = f"wordclouds/wordcloud_{context.aws_request_id}.png"
        s3.upload_file(image_path, bucket_name, s3_key, ExtraArgs={'ACL': 'public-read'})
        
        # Generate public URL
        s3_url = f"https://{bucket_name}.s3.amazonaws.com/{s3_key}"
        
        return {
            'statusCode': 200,
            'body': json.dumps({'image_url': s3_url})
        }
    
    except Exception as e:
        return {
            'statusCode': 500,
            'body': json.dumps({'error': str(e)})
        }

