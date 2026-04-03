#!/bin/bash
# LocalStack init script — creates the S3 bucket on container startup
echo "Creating S3 bucket: mofsl-experimentation-uploads"
awslocal s3 mb s3://mofsl-experimentation-uploads --region ap-south-1
echo "S3 bucket ready."
