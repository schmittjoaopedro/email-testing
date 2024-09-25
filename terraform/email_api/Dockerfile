# Use an official Golang image as the builder
FROM golang:1.22.3-alpine AS builder

# Set the working directory inside the container
WORKDIR /app

# Copy the Go module files to the container
COPY go.mod go.sum ./

# Download Go module dependencies
RUN go mod download

# Copy the entire Go project to the container
COPY . .

# Set environment variables for cross-compilation
ENV GOOS=linux
ENV GOARCH=amd64

# Build the Go application
# Lambda requires the binary to be named bootstrap
RUN go build -o /app/bootstrap

# Use a minimal image for the final output
FROM alpine:latest

# Copy the binary from the builder stage
COPY --from=builder /app/bootstrap /usr/local/bin/bootstrap

# Set the binary as the entry point (optional)
CMD ["bootstrap"]
