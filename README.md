# Email Testing using AWS SES, S3, Lambda, and API Gateway


## Running the project

The lambda function was developed in Go and to compile it this project is using Docker. This is so because for MacOS and
Windows users the go binary has to be generated for linux compatible images to it can be run in lambda. So make sure you
have Docker installed and running on your machine.

During terraform apply it might fail because it takes some time to verify the ACM certificate. If that happens wait a bit
and run the command again.

```shell
# Check docker is running
docker --version

# Set the environment variables
export AWS_REGION=<your_region>
export AWS_ACCESS_KEY_ID=<your_access_key>
export AWS_SECRET_ACCESS_KEY=<your_secret_key>
export ROUTE_53_ZONE_ID=<your_zone_id>
export ROUTE_53_DOMAIN_NAME=<your_domain_name>

# Deploy project in AWS
cd terraform

terraform init

terraform apply \
  -var route53_zone="$ROUTE_53_ZONE_ID" \
  -var route53_domain_name="$ROUTE_53_DOMAIN_NAME" \
  -var aws_region="$AWS_REGION"
  
# Test the application is working
cd ..

pip install -r requirements.txt

python test_email.py

# Delete the resources
cd terraform

terraform destroy \
  -var route53_zone="$ROUTE_53_ZONE_ID" \
  -var route53_domain_name="$ROUTE_53_DOMAIN_NAME" \
  -var aws_region="$AWS_REGION"
```

If all steps are completed successfully, you should see the following output:

```
Start by sending an e-mail from your personal Gmail (or another e-mail provider) to the following address: test-user@email-testing.youraddress.com
Have you sent the e-mail? (yes/no): yes
From: my-email@gmail.com
To: test-user@email-testing.youraddress.com
Date: Wed, 04 Sep 2024 20:05:51 -0700
Subject: Test Subject
Size: 4810
Attachments: 0
Body Text: Test Body
Body HTML: <div dir=3D"ltr"><br clear=3D"all"><div>Test Body</div>...
```
