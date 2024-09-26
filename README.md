# Automated Email Testing using AWS SES, S3, Lambda, and API Gateway

If your application send emails it's important to test them. Testing emails include verifying recipient, subject, body, and attachments. E-mail testing is challenging because it's not as trivial as testing code in your app. Tools like Mailosaur and Mailtrap provide a huge amount of features to help you with your testing. However, these tools are to some degree expensive depending on your current available budget. If you don't need a blasting expensive e-mail testing tool, this AWS solution might be suitable for you.

## The Problem

How can you verify the e-mails sent from your application contain correct recipient, subject, body, and attachments in an automated way? Let's say you have an integration test pipeline which runs every time you push changes to the codebase. Basically we want a method like the `wait_receive_email` below to fetch the new emails for us. Notice in the code below that `start_time` is used to filter for emails sent after your test started.

```python
def test_send_email():
    start_time = time.time()
    recipient = "test_send_email@email-testing.mycompany.com"
    send_welcome_email_to_user(recipient)

    # We want a method like this to fetch the email
    email = wait_receive_email(recipient, start_time)

    assert email['To'] == recipient
    assert email['Subject'] == "Welcome to My Company"
    assert email['TEXTBody'] == "Welcome to My Company! We are glad to have you here."
```

A cross-language simple way to implement this solution is by providing it via a simple REST API. The code below presents what we expect the interface of this API to look like. Notice we also include an `Authorization` header in the API to make it private only for the internal testing.

```python
def wait_receive_email(recipient, start_time):
    response = requests.get(
        url="https://api-email-testing.mycompany.com/receive_email",
        params={
            "recipient": recipient,
            "utcReceivedAfter": start_time.strftime("%Y-%m-%dT%H:%M:%S.%fZ")
        },
        headers={
            "Authorization": "Bearer <api_key>"
        })
    return response.json()
```

## The Solution

The solution proposed here is fully AWS compliant, it uses the following components: SES, S3, Lambda, API Gateway, Parameter Store, and Route 53. The architecture is presented in the diagram below.

![Architecture](assets/EmailTesting.png)

Solution highlights:

- This solution sets a subdomain to receive emails `email-testing.mycompany.com`, this allows to isolate test emails and does not affect your main domain `mycompany.com` used for production emails.
- This solution receives any email sent to any user at `email-testing.mycompany.com` and stores it in an S3 bucket. So you have total flexibility to set any emails for your tests, e.g.: `user1@email-testing.mycompany.com`, `user2@email-testing.mycompany.com`, etc...
- This solution uses Lambda and API Gateway to be fully serverless, so you don't have to worry about scaling or maintaining servers.
- The S3 bucket is configured to expire email files after 1 day to save on costs and maintain the lambda performant.
- The code is implemented to keep pooling the bucket until the email is received or the request times out after 25 seconds. Therefore, both Lambda and API Gateway are aligned to this timeout limit.
- The lambda is implemented in GoLang, if you are building this project from your local machine make sure you have Docker installed and running. This is necessary to build the Go binary for Linux from MacOS or Windows.

## The implementation

The implementation is available in this repo: https://github.com/schmittjoaopedro/email-testing

### Running the project

The lambda function was developed in Go and to compile it this project is using Docker. This is so because for MacOS and Windows users the go binary has to be generated for linux compatible images, so it can run in lambda linux. Make sure you have Docker installed and running on your machine.

Terraform apply it might fail in the middle of the process because it takes some time to verify the ACM certificate. If that happens, wait a minute, and then run the command again.

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

## Cost analysis

This analysis used the AWS cost calculator and `us-east-1` region. For the sake of this analysis lets also assume email testing with 20000 emails per month, each email with an average size of 300kb. In summary for this scenario, the total cost of this solution would be around **4.73 USD** per month.

```text
SES
--------
20,000 messages per month x 0.0001 USD = 2.00 USD (Messages received cost)
300 KB / 256 chunk size factor = 1.171875 chunk size in 256KB
RoundDown (1.171875) = 1 billable chunk factor
20,000 messages per month x 1 billable chunk factor x 0.00009 USD = 1.80 USD (Email chunks received cost)
2.00 USD + 1.80 USD = 3.80 USD SES usage cost
SES usage cost (monthly): 3.80 USD

S3
--------
Tiered price for: 6 GB
6 GB x 0.023 USD = 0.14 USD
Total tier cost = 0.138 USD (S3 Standard storage cost)
20,000 PUT requests for S3 Standard Storage x 0.000005 USD per request = 0.10 USD (S3 Standard PUT requests cost)
200,000 GET requests in a month x 0.0000004 USD per request = 0.08 USD (S3 Standard GET requests cost)
0.138 USD + 0.08 USD + 0.10 USD = 0.32 USD (Total S3 Standard Storage, data requests, S3 select cost)
S3 Standard cost (monthly): 0.32 USD

Inbound:
Internet: 6 GB x 0 USD per GB = 0.00 USD
Outbound:
Internet: 6 GB x 0.09 USD per GB = 0.54 USD
Data Transfer cost (monthly): 0.54 USD

Lambda
--------
Unit conversions
Amount of memory allocated: 128 MB x 0.0009765625 GB in a MB = 0.125 GB
Amount of ephemeral storage allocated: 512 MB x 0.0009765625 GB in a MB = 0.5 GB
Pricing calculations
20,000 requests x 30,000 ms x 0.001 ms to sec conversion factor = 600,000.00 total compute (seconds)
0.125 GB x 600,000.00 seconds = 75,000.00 total compute (GB-s)
75,000.00 GB-s - 400000 free tier GB-s = -325,000.00 GB-s
Max (-325000.00 GB-s, 0 ) = 0.00 total billable GB-s
Tiered price for: 0.00 GB-s
Total tier cost = 0.00 USD (monthly compute charges)
Monthly compute charges: 0.00 USD
20,000 requests - 1000000 free tier requests = -980,000 monthly billable requests
Max (-980000 monthly billable requests, 0 ) = 0.00 total monthly billable requests
Monthly request charges: 0 USD
0.50 GB - 0.5 GB (no additional charge) = 0.00 GB billable ephemeral storage per function
Monthly ephemeral storage charges: 0 USD
Lambda costs - With Free Tier (monthly): 0.00 USD

API Gateway
--------
20,000 requests x 1 unit multiplier = 20,000 total REST API requests
Tiered price for: 20,000 requests
20,000 requests x 0.0000035 USD = 0.07 USD
Total tier cost = 0.07 USD (REST API requests)
Tiered price total for REST API requests: 0.07 USD
0 USD per hour x 730 hours in a month = 0.00 USD for cache memory
Dedicated cache memory total price: 0.00 USD
REST API cost (monthly): 0.07 USD

Total cost
--------
SES usage cost (monthly): 3.80 USD
S3 Standard cost (monthly): 0.32 USD
Data Transfer cost (monthly): 0.54 USD
Lambda costs - With Free Tier (monthly): 0.00 USD
REST API cost (monthly): 0.07 USD
Total cost: 4.73 USD
```

## Conclusion

This solution is a cost-effective way to test emails sent from your application. It's fully automated and can be integrated into your CI/CD pipeline. The solution is fully serverless and can scale to any number of emails sent. The cost of this solution is around 4.73 USD per month for 20,000 emails sent. This solution is a good alternative to expensive email testing tools like Mailosaur and Mailtrap.