#!/bin/bash
set -e

# Check if .env exists
if [[ ! -f .env ]]; then
    if [[ -f .env.example ]]; then
        echo ".env file not found, creating from .env.example..."
        mv .env.example .env
    else
        echo "Error: .env and .env.example not found! Please create .env and set environment variables!"
        exit 1
    fi
fi

# Export only VAR=VAL lines (no spaces or comments)
set -o allexport
grep -E '^[A-Za-z_][A-Za-z0-9_]*=' .env | while read -r line; do export "$line"; done
set +o allexport

# Key files
PRIVATE_KEY_FILE="jwt/private.pem"
PUBLIC_KEY_FILE="jwt/public.pem"

# Generation flags
GENERATE_PRIVATE=false
GENERATE_PUBLIC=false

echo "Checking key files..."

# Check if private key exists and is not empty
if [[ ! -f "$PRIVATE_KEY_FILE" || ! -s "$PRIVATE_KEY_FILE" ]]; then
    echo "Private key is missing or empty, generation required."
    GENERATE_PRIVATE=true
fi

# Check if public key exists and is not empty
if [[ ! -f "$PUBLIC_KEY_FILE" || ! -s "$PUBLIC_KEY_FILE" ]]; then
    echo "Public key is missing or empty, generation required."
    GENERATE_PUBLIC=true
fi

# Validate existing private key
if [[ -f "$PRIVATE_KEY_FILE" && -s "$PRIVATE_KEY_FILE" ]]; then
    if ! openssl rsa -in "$PRIVATE_KEY_FILE" -check -noout &>/dev/null; then
        echo "Private key is corrupted or invalid. Regenerating..."
        GENERATE_PRIVATE=true
    fi
fi

# Validate existing public key
if [[ -f "$PUBLIC_KEY_FILE" && -s "$PUBLIC_KEY_FILE" ]]; then
    if ! openssl rsa -in "$PUBLIC_KEY_FILE" -pubin -noout &>/dev/null; then
        echo "Public key is corrupted or invalid. Regenerating..."
        GENERATE_PUBLIC=true
    fi
fi

# If private key is corrupted or missing, regenerate both keys
if [[ "$GENERATE_PRIVATE" == true ]]; then
    echo "Generating new private key..."
    openssl genrsa -out "$PRIVATE_KEY_FILE" 2048
    GENERATE_PUBLIC=true  # Public key must be updated as well
fi

# Generate public key if required
if [[ "$GENERATE_PUBLIC" == true ]]; then
    echo "Generating new public key..."
    openssl rsa -in "$PRIVATE_KEY_FILE" -pubout -out "$PUBLIC_KEY_FILE"
fi

echo "Both keys are valid and ready to use!"

# -------------------------------------------------------------------

# Read files and replace line breaks with \n
PRIVATE_KEY=$(sed ':a;N;$!ba;s/\n/\\n/g' $PRIVATE_KEY_FILE)
PUBLIC_KEY=$(sed ':a;N;$!ba;s/\n/\\n/g' $PUBLIC_KEY_FILE)

# Update .env (replace or add variables)
if grep -q "^PRIVATE_KEY=" .env; then
    sed -i "s|^PRIVATE_KEY=.*|PRIVATE_KEY=\"$PRIVATE_KEY\"|" .env
else
    echo "PRIVATE_KEY=\"$PRIVATE_KEY\"" >> .env
fi

if grep -q "^PUBLIC_KEY=" .env; then
    sed -i "s|^PUBLIC_KEY=.*|PUBLIC_KEY=\"$PUBLIC_KEY\"|" .env
else
    echo "PUBLIC_KEY=\"$PUBLIC_KEY\"" >> .env
fi

echo "Keys have been successfully updated in .env"