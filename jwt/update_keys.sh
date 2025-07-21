#!/bin/bash
set -e

#----- [ COLOR CODES ] ------------------------------------------------------
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
GRAY='\033[0;37m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

#----- [ ENV CHECK ] --------------------------------------------------------
if [[ ! -f .env ]]; then
    printf "${RED}ERROR: .env file not found! Please create .env and set environment variables!${NC}\n"
    exit 1
fi

# Export only VAR=VAL lines (no spaces or comments)
set -o allexport
grep -E '^[A-Za-z_][A-Za-z0-9_]*=' .env | while read -r line; do export "$line"; done
set +o allexport

printf "\n${WHITE}%s${NC}\n" "=====================[ GENERATING JWT KEYPAIR ]====================="

#----- [ FILES ] ------------------------------------------------------------
PRIVATE_KEY_FILE="jwt/private.pem"
PUBLIC_KEY_FILE="jwt/public.pem"

# Generation flags
GENERATE_PRIVATE=false
GENERATE_PUBLIC=false

printf "${GRAY}%s${NC}\n" "------ Checking private key presence ------"
if [[ -f "$PRIVATE_KEY_FILE" && -s "$PRIVATE_KEY_FILE" ]]; then
    printf "${GREEN}Private key found: $PRIVATE_KEY_FILE${NC}\n"
else
    printf "${YELLOW}Private key is missing or empty, generation required.${NC}\n"
    GENERATE_PRIVATE=true
fi

printf "\n${GRAY}%s${NC}\n" "------ Checking public key presence ------"
if [[ -f "$PUBLIC_KEY_FILE" && -s "$PUBLIC_KEY_FILE" ]]; then
    printf "${GREEN}Public key found: $PUBLIC_KEY_FILE${NC}\n"
else
    printf "${YELLOW}Public key is missing or empty, generation required.${NC}\n"
    GENERATE_PUBLIC=true
fi

if [[ -f "$PRIVATE_KEY_FILE" && -s "$PRIVATE_KEY_FILE" ]]; then
    printf "\n${GRAY}%s${NC}\n" "------ Validating private key integrity ------"
    if openssl rsa -in "$PRIVATE_KEY_FILE" -check -noout &>/dev/null; then
        printf "${GREEN}Private key is valid.${NC}\n"
    else
        printf "${RED}Private key is corrupted or invalid. Regenerating...${NC}\n"
        GENERATE_PRIVATE=true
    fi
fi

if [[ -f "$PUBLIC_KEY_FILE" && -s "$PUBLIC_KEY_FILE" ]]; then
    printf "\n${GRAY}%s${NC}\n" "------ Validating public key integrity ------"
    if openssl rsa -in "$PUBLIC_KEY_FILE" -pubin -noout &>/dev/null; then
        printf "${GREEN}Public key is valid.${NC}\n"
    else
        printf "${RED}Public key is corrupted or invalid. Regenerating...${NC}\n"
        GENERATE_PUBLIC=true
    fi
fi

printf "\n${GRAY}%s${NC}\n" "------ Generating new private key (if required) ------"
if [[ "$GENERATE_PRIVATE" == true ]]; then
    printf "Generating new private key...\n"
    mkdir -p "$(dirname "$PRIVATE_KEY_FILE")"
    openssl genrsa -out "$PRIVATE_KEY_FILE" 2048
    printf "${GREEN}Private key generated: $PRIVATE_KEY_FILE${NC}\n"
    GENERATE_PUBLIC=true  # Always regenerate public if private is new
else
    printf "${GREEN}Private key is OK, generation not required.${NC}\n"
fi

printf "\n${GRAY}%s${NC}\n" "------ Generating new public key (if required) ------"
if [[ "$GENERATE_PUBLIC" == true ]]; then
    printf "Generating new public key...\n"
    openssl rsa -in "$PRIVATE_KEY_FILE" -pubout -out "$PUBLIC_KEY_FILE"
    printf "${GREEN}Public key generated: $PUBLIC_KEY_FILE${NC}\n"
else
    printf "${GREEN}Public key is OK, generation not required.${NC}\n"
fi

printf "\n${GRAY}%s${NC}\n" "------ Final validation ------"
if [[ -f "$PRIVATE_KEY_FILE" && -s "$PRIVATE_KEY_FILE" && \
      -f "$PUBLIC_KEY_FILE" && -s "$PUBLIC_KEY_FILE" ]]; then
    printf "${GREEN}Both keys are valid and ready to use!${NC}\n"
else
    printf "${RED}ERROR: Keypair is not valid or missing!${NC}\n"
    exit 1
fi

printf "\n${GRAY}%s${NC}\n" "------ Injecting keys into .env ------"
PRIVATE_KEY=$(sed ':a;N;$!ba;s/\n/\\n/g' "$PRIVATE_KEY_FILE")
PUBLIC_KEY=$(sed ':a;N;$!ba;s/\n/\\n/g' "$PUBLIC_KEY_FILE")

sed -i '/^PRIVATE_KEY=/d' .env
sed -i '/^PUBLIC_KEY=/d' .env

echo "PRIVATE_KEY=\"$PRIVATE_KEY\"" >> .env
echo "PUBLIC_KEY=\"$PUBLIC_KEY\"" >> .env

printf "${GREEN}Keys have been successfully updated in .env${NC}\n"