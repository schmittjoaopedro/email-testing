# Build Golang binary in MAC using docker
# Usage: ./build.sh

# Build a Linux-compatible binary using Docker
docker build -t my-go-app .

# Extract the Linux Binary
docker run --rm -v $(pwd)/output:/output my-go-app cp /usr/local/bin/bootstrap /output

# Verify the binary is Linux compatible, e.g.:
# bootstrap: ELF 64-bit LSB executable, x86-64, ...
file_type=$(file output/bootstrap)
if [[ $file_type == *"ELF 64-bit"* ]]; then
  echo "Binary is Linux compatible"
else
  echo "Binary is not Linux compatible"
  exit 1
fi

# Sleep to make sure the binary is flushed to fs before zipped by terraform
sleep 1