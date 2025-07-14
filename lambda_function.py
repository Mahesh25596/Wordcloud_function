import json
import os
import sys
import tempfile
import logging
from typing import Dict, Any, Tuple

import boto3
import matplotlib
import matplotlib.pyplot as plt
from botocore.exceptions import ClientError
from wordcloud import WordCloud

matplotlib.use('Agg')

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Initialize S3 client outside handler for connection reuse
s3 = boto3.client('s3')
bucket_name = os.environ.get('BUCKET_NAME')

# Configuration constants
MAX_TEXT_LENGTH = 50000  # Prevent DoS attacks
MIN_TEXT_LENGTH = 10
WORDCLOUD_CONFIG = {
    'width': int(os.environ.get('WORDCLOUD_WIDTH', '800')),
    'height': int(os.environ.get('WORDCLOUD_HEIGHT', '400')),
    'background_color': os.environ.get('WORDCLOUD_BG_COLOR', 'white'),
    'max_words': int(os.environ.get('WORDCLOUD_MAX_WORDS', '100')),
    'colormap': os.environ.get('WORDCLOUD_COLORMAP', 'viridis')
}


def validate_environment() -> None:
    """Validate required environment variables."""
    if not bucket_name:
        raise ValueError("BUCKET_NAME environment variable is required")


def validate_input(body: Dict[str, Any]) -> Tuple[bool, str, str]:
    """
    Validate input parameters.

    Returns:
        Tuple of (is_valid, error_message, cleaned_text)
    """
    text = body.get('text', '').strip()

    if not text:
        return False, 'Text input is required and cannot be empty', ''

    if len(text) < MIN_TEXT_LENGTH:
        error_msg = f'Text must be at least {MIN_TEXT_LENGTH} characters long'
        return False, error_msg, ''

    if len(text) > MAX_TEXT_LENGTH:
        error_msg = f'Text cannot exceed {MAX_TEXT_LENGTH} characters'
        return False, error_msg, ''

    # Basic text sanitization
    if not any(c.isalpha() for c in text):
        error_msg = 'Text must contain at least some alphabetic characters'
        return False, error_msg, ''

    return True, '', text


def generate_wordcloud(text: str) -> str:
    """
    Generate wordcloud image and return the temporary file path.

    Args:
        text: Input text for wordcloud generation

    Returns:
        Path to the generated image file

    Raises:
        Exception: If wordcloud generation fails
    """
    try:
        # Create wordcloud with configuration
        wordcloud = WordCloud(**WORDCLOUD_CONFIG).generate(text)

        # Create temporary file
        with tempfile.NamedTemporaryFile(suffix='.png', delete=False) as tmp:
            image_path = tmp.name

        # Generate and save the plot
        width = WORDCLOUD_CONFIG['width'] / 100
        height = WORDCLOUD_CONFIG['height'] / 100
        plt.figure(figsize=(width, height))
        plt.imshow(wordcloud, interpolation='bilinear')
        plt.axis("off")
        plt.tight_layout(pad=0)
        plt.savefig(
            image_path,
            bbox_inches='tight',
            pad_inches=0,
            dpi=100,
            facecolor='white',
            edgecolor='none'
        )
        plt.close('all')  # Close all figures to free memory

        return image_path

    except Exception as e:
        plt.close('all')  # Ensure cleanup on error
        logger.error(f"WordCloud generation failed: {str(e)}")
        raise


def upload_to_s3(image_path: str, request_id: str) -> str:
    """
    Upload image to S3 and return the URL.

    Args:
        image_path: Local path to the image file
        request_id: AWS request ID for unique naming

    Returns:
        S3 URL of the uploaded image

    Raises:
        Exception: If S3 upload fails
    """
    s3_key = f"wordclouds/wordcloud_{request_id}.png"

    try:
        extra_args = {
            'ContentType': 'image/png',
            'CacheControl': 'max-age=31536000',  # Cache for 1 year
            'Metadata': {
                'generator': 'wordcloud-lambda',
                'version': '1.0'
            }
        }

        s3.upload_file(image_path, bucket_name, s3_key, ExtraArgs=extra_args)

        # Generate proper S3 URL using boto3
        region = s3.meta.region_name or 'us-east-1'
        s3_url = f"https://{bucket_name}.s3.{region}.amazonaws.com/{s3_key}"

        logger.info(f"Successfully uploaded wordcloud to S3: {s3_key}")
        return s3_url

    except ClientError as e:
        error_code = e.response['Error']['Code']
        logger.error(f"S3 upload failed with error {error_code}: {str(e)}")
        raise Exception(f"Failed to upload image to S3: {error_code}")
    except Exception as e:
        logger.error(f"Unexpected error during S3 upload: {str(e)}")
        raise


def cleanup_temp_file(file_path: str) -> None:
    """Safely remove temporary file."""
    try:
        if os.path.exists(file_path):
            os.remove(file_path)
            logger.debug(f"Cleaned up temporary file: {file_path}")
    except Exception as e:
        warning_msg = f"Failed to cleanup temporary file {file_path}: {str(e)}"
        logger.warning(warning_msg)


def create_response(status_code: int, body: Dict[str, Any],
                    include_cors: bool = True) -> Dict[str, Any]:
    """Create standardized API response."""
    headers = {'Content-Type': 'application/json'}

    if include_cors:
        cors_headers = {
            'Access-Control-Allow-Origin': '*',
            'Access-Control-Allow-Headers': 'Content-Type',
            'Access-Control-Allow-Methods': 'POST, OPTIONS'
        }
        headers.update(cors_headers)

    return {
        'statusCode': status_code,
        'body': json.dumps(body),
        'headers': headers
    }


def lambda_handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """
    Main Lambda handler function.

    Args:
        event: API Gateway event
        context: Lambda context

    Returns:
        API Gateway response
    """
    image_path = None

    try:
        logger.info(f"Processing request: {context.aws_request_id}")

        # Validate environment
        validate_environment()

        # Handle CORS preflight requests
        if event.get('httpMethod') == 'OPTIONS':
            return create_response(200, {'message': 'CORS preflight'})

        # Validate request structure
        if 'body' not in event:
            error_body = {'error': 'Missing body in request'}
            return create_response(400, error_body)

        # Parse JSON body
        try:
            if isinstance(event['body'], str):
                body = json.loads(event['body'])
            else:
                body = event['body']
        except json.JSONDecodeError as e:
            logger.warning(f"Invalid JSON in request body: {str(e)}")
            error_body = {'error': 'Invalid JSON format'}
            return create_response(400, error_body)

        # Validate input
        is_valid, error_msg, text = validate_input(body)
        if not is_valid:
            logger.warning(f"Input validation failed: {error_msg}")
            return create_response(400, {'error': error_msg})

        # Generate wordcloud
        logger.info("Generating wordcloud...")
        image_path = generate_wordcloud(text)

        # Upload to S3
        logger.info("Uploading to S3...")
        s3_url = upload_to_s3(image_path, context.aws_request_id)

        success_msg = (
            f"WordCloud generation completed successfully "
            f"for request {context.aws_request_id}"
        )
        logger.info(success_msg)

        response_body = {
            'image_url': s3_url,
            'request_id': context.aws_request_id,
            'word_count': len(text.split())
        }
        return create_response(200, response_body)

    except ValueError as e:
        logger.error(f"Configuration error: {str(e)}")
        error_body = {'error': 'Service configuration error'}
        return create_response(500, error_body)

    except Exception as e:
        request_id = getattr(context, 'aws_request_id', 'unknown')
        logger.error(f"Unexpected error in request {request_id}: {str(e)}")
        exc_type, exc_obj, exc_tb = sys.exc_info()
        if exc_tb:
            logger.error(f"Error occurred at line: {exc_tb.tb_lineno}")

        error_body = {
            'error': 'Internal server error',
            'request_id': request_id
        }
        return create_response(500, error_body)

    finally:
        # Always cleanup temporary files
        if image_path:
            cleanup_temp_file(image_path)
