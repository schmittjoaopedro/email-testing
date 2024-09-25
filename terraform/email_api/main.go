package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/ssm"
	"io"
	"log"
	"mime"
	"mime/multipart"
	"mime/quotedprintable"
	"net/mail"
	"os"
	"sort"
	"strings"
	"time"
)

// For more details refer to: https://github.com/kirabou/parseMIMEemail.go
var s3BucketName string
var s3Client *s3.Client
var ssmApiKeyName string
var ssmClient *ssm.Client

// Cache clients to they are initialized only once
func init() {
	cfg, err := config.LoadDefaultConfig(context.TODO())
	if err != nil {
		log.Fatal(err)
	}

	// Create an Amazon S3 service client
	s3BucketName = os.Getenv("S3_BUCKET_NAME")
	s3Client = s3.NewFromConfig(cfg)

	// Create an Amazon SSM service client
	ssmApiKeyName = os.Getenv("BASIC_AUTH_SECRET_ID")
	ssmClient = ssm.NewFromConfig(cfg)

}

type Attachment struct {
	Filename      string
	ContentBase64 string
}

type Email struct {
	From        string
	To          string
	Subject     string
	Date        string
	ContentType string
	HTMLBody    string
	TEXTBody    string
	Attachments []Attachment
}

/**
 * Extract part content (text, html, attachments) and write to emailResponse
 */
func writePart(part *multipart.Part, emailResponse *Email) error {

	filename := part.FileName()
	mediaType, _, err := mime.ParseMediaType(part.Header.Get("Content-Type"))

	// Read the data for this MIME partx
	partData, err := io.ReadAll(part)
	if err != nil {
		return err
	}

	contentTransferEncoding := strings.ToUpper(part.Header.Get("Content-Transfer-Encoding"))

	switch {

	case strings.Compare(contentTransferEncoding, "BASE64") == 0:
		decodedContent, err := base64.StdEncoding.DecodeString(string(partData))
		if err != nil {
			return err
		} else {
			emailResponse.Attachments = append(emailResponse.Attachments, Attachment{
				Filename:      filename,
				ContentBase64: base64.StdEncoding.EncodeToString(decodedContent),
			})
		}

	case strings.Compare(contentTransferEncoding, "QUOTED-PRINTABLE") == 0:
		decodedContent, err := io.ReadAll(quotedprintable.NewReader(bytes.NewReader(partData)))
		if err != nil {
			return err
		} else {
			emailResponse.Attachments = append(emailResponse.Attachments, Attachment{
				Filename:      filename,
				ContentBase64: base64.StdEncoding.EncodeToString(decodedContent),
			})
		}

	case mediaType == "text/plain":
		emailResponse.TEXTBody = string(partData)

	case mediaType == "text/html":
		emailResponse.HTMLBody = string(partData)

	default:
		if err != nil {
			return err
		} else {
			emailResponse.Attachments = append(emailResponse.Attachments, Attachment{
				Filename:      filename,
				ContentBase64: base64.StdEncoding.EncodeToString(partData),
			})
		}
	}

	return nil
}

/**
 * Recursively process all parts of the email.
 * An email MIME file is formed of a tree structure of parts.
 * Depending on the email sender, the tree structure will vary.
 */
func parsePart(mimeData io.Reader, boundary string, emailResponse *Email) error {

	reader := multipart.NewReader(mimeData, boundary)
	if reader == nil {
		return fmt.Errorf("could not create multipart reader")
	}

	for {

		newPart, err := reader.NextPart()
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}

		// multipart/* media type indicates there are other sub-parts under this part
		mediaType, params, err := mime.ParseMediaType(newPart.Header.Get("Content-Type"))
		if err == nil && strings.HasPrefix(mediaType, "multipart/") {
			err = parsePart(newPart, params["boundary"], emailResponse)
			if err != nil {
				return err
			}
		} else {
			// No multipart/* media type indicates this is a leaf part (content)
			err = writePart(newPart, emailResponse)
			if err != nil {
				return err
			}
		}
	}

	return nil
}

/**
 * Find amongst all emails read from S3 objects the latest one sent to the recipient.
 */
func findLatestEmail(emailBytes map[string][]byte, recipientEmail string) (*Email, error) {

	var emailResponse *Email = nil
	var msg *mail.Message = nil
	var err error

	for key, value := range emailBytes {

		fmt.Println("Processing email: ", key)

		emailFile := bytes.NewReader(value)

		msg, err = mail.ReadMessage(emailFile)
		if err != nil {
			return nil, err
		}

		dec := new(mime.WordDecoder)

		from, _ := dec.DecodeHeader(msg.Header.Get("From"))
		to, _ := dec.DecodeHeader(msg.Header.Get("To"))
		subject, _ := dec.DecodeHeader(msg.Header.Get("Subject"))
		date := msg.Header.Get("Date")
		contentType := msg.Header.Get("Content-Type")

		// Check if the recipient is the same as the one we are looking for, then stop
		// search because this is the most recent email received by the recipient.
		if strings.Contains(to, recipientEmail) {
			emailResponse = &Email{
				From:        from,
				To:          to,
				Subject:     subject,
				Date:        date,
				ContentType: contentType,
			}
			break
		}

	}

	// Only process email parts if we found the email we are looking for
	// otherwise return nil. This makes the function more efficient.
	if msg != nil && emailResponse != nil {
		mediaType, params, err := mime.ParseMediaType(emailResponse.ContentType)
		if err != nil {
			return nil, err
		}
		if !strings.HasPrefix(mediaType, "multipart/") {
			return nil, fmt.Errorf("email is not multipart")
		}

		// Send the email response to be populated with the email parts
		err = parsePart(msg.Body, params["boundary"], emailResponse)
		if err != nil {
			return nil, err
		}
	}

	return emailResponse, nil
}

/**
 * Get all emails from S3 bucket that were received after a certain date.
 * Return a map of email file names and their content in bytes.
 */
func getAllEmailsBackToDate(utcReceivedAfter string) (map[string][]byte, error) {
	// Convert string to time
	utcReceivedAfterTime, err := time.Parse(time.RFC3339, utcReceivedAfter)

	// List all files in s3 bucket
	listObjectsOutput, err := s3Client.ListObjectsV2(context.TODO(), &s3.ListObjectsV2Input{
		Bucket: &s3BucketName,
	})
	if err != nil {
		return nil, err
	}

	// Sort contents by LastModified in descending order
	contents := listObjectsOutput.Contents
	sort.Slice(contents, func(i, j int) bool {
		return contents[i].LastModified.After(*contents[j].LastModified)
	})

	// Iterate over all objects in the bucket and select only the ones
	// received after the specified date
	emailBytes := make(map[string][]byte)
	for _, object := range contents {
		if object.LastModified.After(utcReceivedAfterTime) {

			log.Printf("Reading Key: %s", *object.Key)
			objectOutput, err := s3Client.GetObject(context.TODO(), &s3.GetObjectInput{
				Bucket: &s3BucketName,
				Key:    object.Key,
			})
			if err != nil {
				return nil, err
			}

			// Read object byte array and store in map with the object key
			objectBytes, err := io.ReadAll(objectOutput.Body)
			if err != nil {
				return nil, err
			}
			emailBytes[*object.Key] = objectBytes

			err = objectOutput.Body.Close()
			if err != nil {
				return nil, err
			}
		}
	}

	return emailBytes, nil

}

func getErrorResponse(err error) events.APIGatewayProxyResponse {
	return events.APIGatewayProxyResponse{
		Body:       fmt.Sprintf("Error: %v", err),
		StatusCode: 500,
	}
}

func validateAuthorization(request events.APIGatewayProxyRequest) (bool, error) {
	// Get request token from Authorization header
	authorization := request.Headers["Authorization"]
	if authorization == "" {
		return false, nil
	}
	// Replace auth keywords with empty string, this authentication is flexible because
	// accepts sending the token as Bearer, Basic, or just the token itself.
	var requestToken string
	requestToken = strings.Replace(authorization, "Bearer ", "", 1)
	requestToken = strings.Replace(authorization, "Basic ", "", 1)

	// Get backend token from SSM
	ssmToken, err := ssmClient.GetParameter(context.TODO(), &ssm.GetParameterInput{
		Name:           &ssmApiKeyName,
		WithDecryption: aws.Bool(true),
	})
	if err != nil {
		return false, err
	}
	fmt.Println(*ssmToken.Parameter.Value)

	if requestToken != *ssmToken.Parameter.Value {
		return false, nil
	} else {
		return true, nil
	}

}

func Handler(request events.APIGatewayProxyRequest) (events.APIGatewayProxyResponse, error) {
	// Example of request call:
	// https://api-email-testing.joaopedroschmitt.click/receive_email
	//   ?utcReceivedAfter=2024-09-24T02:00:00Z
	//   &recipient=test-user@email-testing.joaopedroschmitt.click

	// Get utcReceivedAfter from query parameter
	utcReceivedAfter := request.QueryStringParameters["utcReceivedAfter"]
	recipient := request.QueryStringParameters["recipient"]

	// Validate Authorization
	isAuthorized, err := validateAuthorization(request)
	if err != nil {
		return getErrorResponse(err), nil
	}
	if !isAuthorized {
		return events.APIGatewayProxyResponse{
			StatusCode: 401,
			Body:       "Unauthorized",
		}, nil
	}

	poolingStartTime := time.Now()

	// Keep pooling until the expected email is found or 25 seconds have passed
	for time.Since(poolingStartTime) < 25*time.Second {
		emailBytes, err := getAllEmailsBackToDate(utcReceivedAfter)
		if err != nil {
			return getErrorResponse(err), nil
		}

		// Find the latest received email
		emailResponse, err := findLatestEmail(emailBytes, recipient)
		if err != nil {
			return getErrorResponse(err), nil
		}

		if emailResponse != nil {
			// Return the email as JSON response
			jsonBytes, err := json.Marshal(emailResponse)
			if err != nil {
				return getErrorResponse(err), nil
			}
			return events.APIGatewayProxyResponse{
				StatusCode: 200,
				Body:       string(jsonBytes),
			}, nil
		} else {
			time.Sleep(1 * time.Second)
		}
	}

	return events.APIGatewayProxyResponse{
		StatusCode: 204,
		Body:       "No email found",
	}, nil
}

func main() {
	log.Printf("Starting lambda.")
	lambda.Start(Handler)
}
