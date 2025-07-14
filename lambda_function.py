import json
import boto3
import os
import sys
from wordcloud import WordCloud
import matplotlib
matplotlib.use('Agg')  
import matplotlib.pyplot as plt

s3 = boto3.client('s3')
bucket_name = os.environ['BUCKET_NAME']

def lambda_handler(event, context):
    try:
        print("Received event: " + json.dumps(event))
        
        if 'body' not in event:
            return {
                'statusCode': 400,
                'body': json.dumps({'error': 'Missing body in request'})
            }
            
        try:
            body = json.loads(event['body'])
        except json.JSONDecodeError:
            return {
                'statusCode': 400,
                'body': json.dumps({'error': 'Invalid JSON format'})
            }
        
        text = body.get('text', '')
        
        if not text:
            return {
                'statusCode': 400,
                'body': json.dumps({'error': 'Text input is required'})
            }
        
        wordcloud = WordCloud(width=800, height=400, background_color='white').generate(text)
        
        image_path = '/tmp/wordcloud.png'
        plt.figure(figsize=(8, 4))
        plt.imshow(wordcloud, interpolation='bilinear')
        plt.axis("off")
        plt.savefig(image_path, bbox_inches='tight', pad_inches=0)
        plt.close()
        
        s3_key = f"wordclouds/wordcloud_{context.aws_request_id}.png"
        s3.upload_file(
            image_path, 
            bucket_name, 
            s3_key, 
            ExtraArgs={
                'ContentType': 'image/png'
            }
        )
        
        s3_url = f"https://{bucket_name}.s3.amazonaws.com/{s3_key}"
        
        return {
            'statusCode': 200,
            'body': json.dumps({'image_url': s3_url}),
            'headers': {
                'Content-Type': 'application/json'
            }
        }
    
    except Exception as e:
        print(f"Error: {str(e)}")
        exc_type, exc_obj, exc_tb = sys.exc_info()
        print(f"Line: {exc_tb.tb_lineno}")
        return {
            'statusCode': 500,
            'body': json.dumps({'error': str(e)}),
            'headers': {
                'Content-Type': 'application/json'
            }
        }
