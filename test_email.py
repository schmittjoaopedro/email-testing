import requests
import boto3
import os

aws_region = os.environ['AWS_REGION']
domain_email = f"email-testing.{os.environ['ROUTE_53_DOMAIN_NAME']}"
print(f"Start by sending an e-mail from your personal Gmail (or another e-mail provider)"
      f" to the following address: test-user@{domain_email}")

# Ask if the user has sent the e-mail
sent_email = input("Have you sent the e-mail? (yes/no): ")
if sent_email != "yes":
    print("Please send the e-mail and run the script again.")
    exit()

# Get API basic auth credentials
ssm = boto3.client('ssm', region_name=aws_region)
basic_auth = ssm.get_parameter(Name=f"/ses/email-testing/api-basic-username",
                               WithDecryption=True)['Parameter']['Value']

# Receive the last e-mail
domain_api = f"api-email-testing.{os.environ['ROUTE_53_DOMAIN_NAME']}"
response = requests.get(f"https://{domain_api}/receive_email?"
                        f"recipient=test-user@{domain_email}&"
                        f"utcReceivedAfter=2024-01-01T01:00:00Z",
                        headers={
                            'Authorization': f'Basic {basic_auth}',
                            'Content-Type': 'application/json'
                        })
response.raise_for_status()
email = response.json()
print(f"From: {email['From']}")
print(f"To: {email['To']}")
print(f"Date: {email['Date']}")
print(f"Subject: {email['Subject']}")
print(f"Attachments: {len(email['Attachments'])}")
print(f"\nBody Text:\n{email['TEXTBody']}")
print(f"\nBody HTML:\n{email['HTMLBody']}")
