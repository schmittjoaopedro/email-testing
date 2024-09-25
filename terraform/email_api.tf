resource "random_pet" "api_basic_username" {
  length = 2
}

resource "random_password" "api_basic_password" {
  length  = 16
  special = false
  upper   = false
}

# Store the basic api in a secret parameter store
resource "aws_ssm_parameter" "api_basic_username" {
  name  = "/ses/email-testing/api-basic-username"
  type  = "SecureString"
  value = base64encode("${random_pet.api_basic_username.id}:${random_password.api_basic_password.result}")
}

data "aws_iam_policy_document" "assume_role" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

data "aws_iam_policy_document" "lambda_policies" {
  statement {
    effect  = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["arn:aws:logs:*:*:*"]
  }
  statement {
    effect  = "Allow"
    actions = [
      "s3:Get*",
      "s3:List*"
    ]
    resources = [
      "arn:aws:s3:::${aws_s3_bucket.email_testing.bucket}/*",
      "arn:aws:s3:::${aws_s3_bucket.email_testing.bucket}"
    ]
  }
  statement {
    effect  = "Allow"
    actions = [
      "ssm:GetParameter",
    ]
    resources = [aws_ssm_parameter.api_basic_username.arn]
  }
}

resource "aws_iam_role" "email_testing_lambda" {
  name               = "email_testing_lambda"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

resource "aws_iam_role_policy" "lambda_policies" {
  name   = "lambda_policies"
  role   = aws_iam_role.email_testing_lambda.id
  policy = data.aws_iam_policy_document.lambda_policies.json
}

resource "null_resource" "run_build_script" {
  provisioner "local-exec" {
    # Runs a custom shell script to generate the Go binary to be deployed in the Lambda function
    command = "cd email_api && ./build.sh"
  }
  triggers = {
    # Re-build the binary if the source code changes
    always_run = "${sha1(file("email_api/main.go"))}-${sha1(file("email_api/go.mod"))}"
  }
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "email_api/output/bootstrap"
  output_path = "email_api/output/bootstrap.zip"
  depends_on  = [null_resource.run_build_script]
}

resource "aws_lambda_function" "email_testing_lambda" {
  filename      = data.archive_file.lambda_zip.output_path
  function_name = "email_testing_lambda"
  role          = aws_iam_role.email_testing_lambda.arn
  handler       = "bootstrap" # GoLang projects must set handler as bootstrap
  timeout       = 30
  memory_size   = 1024

  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  runtime = "provided.al2023"

  environment {
    variables = {
      S3_BUCKET_NAME       = aws_s3_bucket.email_testing.bucket
      BASIC_AUTH_SECRET_ID = aws_ssm_parameter.api_basic_username.name
    }
  }
}


resource "aws_api_gateway_rest_api" "email_testing" {
  name        = "email-testing-api"
  description = "Email testing API"

  body = jsonencode({
    openapi = "3.0.1"
    info    = {
      title   = "Email Testing API"
      version = "1.0-${aws_lambda_function.email_testing_lambda.source_code_hash}"
    }
    paths = {
      "/receive_email" = {
        "get" = {
          "parameters" : [
            {
              "name" : "recipient",
              "in" : "query",
              "required" : true,
              "type" : "string"
            },
            {
              "name" : "utcReceivedAfter",
              "in" : "query",
              "required" : true,
              "type" : "string"
            },
            {
              "name" : "Authorization",
              "in" : "header",
              "required" : true,
              "type" : "string"
            }
          ],
          x-amazon-apigateway-integration = {
            type                 = "AWS_PROXY"
            httpMethod           = "POST"
            payloadFormatVersion = "1.0"
            timeoutInMillis      = 29000
            uri                  = aws_lambda_function.email_testing_lambda.invoke_arn
          }
        }
      }
    }
  })

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

resource "aws_api_gateway_deployment" "ses_email_testing_tool" {
  rest_api_id = aws_api_gateway_rest_api.email_testing.id

  triggers = {
    redeployment = sha1(jsonencode(aws_api_gateway_rest_api.email_testing.body))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "ses_email_testing_tool" {
  deployment_id = aws_api_gateway_deployment.ses_email_testing_tool.id
  rest_api_id   = aws_api_gateway_rest_api.email_testing.id
  stage_name    = "default"
}


resource "aws_lambda_permission" "lambda_permission" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.email_testing_lambda.arn
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.email_testing.execution_arn}/*"
}

resource "aws_acm_certificate" "ses_email_testing_tool" {
  domain_name       = local.api_domain
  validation_method = "DNS"
}

resource "aws_route53_record" "acm_validation" {
  for_each = {
    for record in aws_acm_certificate.ses_email_testing_tool.domain_validation_options : record.domain_name => {
      name    = record.resource_record_name
      type    = record.resource_record_type
      ttl     = 60
      records = [record.resource_record_value]
    }
  }

  zone_id = local.route53_zone
  name    = each.value.name
  type    = each.value.type
  ttl     = each.value.ttl
  records = each.value.records
}

resource "aws_api_gateway_domain_name" "ses_email_testing_tool" {
  domain_name              = local.api_domain
  regional_certificate_arn = aws_acm_certificate.ses_email_testing_tool.arn

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

resource "aws_api_gateway_base_path_mapping" "ses_email_testing_tool" {
  api_id      = aws_api_gateway_rest_api.email_testing.id
  stage_name  = aws_api_gateway_stage.ses_email_testing_tool.stage_name
  domain_name = aws_api_gateway_domain_name.ses_email_testing_tool.domain_name
}


resource "aws_route53_record" "api_domain" {
  zone_id = local.route53_zone
  name    = local.api_domain
  type    = "CNAME"
  ttl     = 300
  records = [aws_api_gateway_domain_name.ses_email_testing_tool.regional_domain_name]
}