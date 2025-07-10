#!/bin/bash
set -e

# Проверяем, существует ли .env
if [[ ! -f .env ]]; then
    if [[ -f .env.example ]]; then
        echo "Файл .env не найден, создаю его из .env.example..."
        mv .env.example .env
    else
        echo "Ошибка: .env и .env.example не найдены! Создайте .env и укажите переменные окружения!"
        exit 1
    fi
fi

# Экспортируем только строки вида VAR=VAL, без пробелов и комментариев
set -o allexport
grep -E '^[A-Za-z_][A-Za-z0-9_]*=' .env | while read -r line; do export "$line"; done
set +o allexport

# Файлы ключей
PRIVATE_KEY_FILE="jwt/private.pem"
PUBLIC_KEY_FILE="jwt/public.pem"

# Флаги для генерации
GENERATE_PRIVATE=false
GENERATE_PUBLIC=false

echo "Проверяю файлы ключей..."

# Проверяем, существует ли приватный ключ и не пуст ли он
if [[ ! -f "$PRIVATE_KEY_FILE" || ! -s "$PRIVATE_KEY_FILE" ]]; then
    echo "Приватный ключ отсутствует или пустой, требуется генерация."
    GENERATE_PRIVATE=true
fi

# Проверяем, существует ли публичный ключ и не пуст ли он
if [[ ! -f "$PUBLIC_KEY_FILE" || ! -s "$PUBLIC_KEY_FILE" ]]; then
    echo "Публичный ключ отсутствует или пустой, требуется генерация."
    GENERATE_PUBLIC=true
fi

# Проверяем валидность существующего приватного ключа
if [[ -f "$PRIVATE_KEY_FILE" && -s "$PRIVATE_KEY_FILE" ]]; then
    if ! openssl rsa -in "$PRIVATE_KEY_FILE" -check -noout &>/dev/null; then
        echo "Приватный ключ поврежден или невалиден. Перегенерирую..."
        GENERATE_PRIVATE=true
    fi
fi

# Проверяем валидность существующего публичного ключа
if [[ -f "$PUBLIC_KEY_FILE" && -s "$PUBLIC_KEY_FILE" ]]; then
    if ! openssl rsa -in "$PUBLIC_KEY_FILE" -pubin -noout &>/dev/null; then
        echo "Публичный ключ поврежден или невалиден. Перегенерирую..."
        GENERATE_PUBLIC=true
    fi
fi

# Если приватный ключ поврежден или отсутствует, пересоздаем оба ключа
if [[ "$GENERATE_PRIVATE" == true ]]; then
    echo "Генерирую новый приватный ключ..."
    openssl genrsa -out "$PRIVATE_KEY_FILE" 2048
    GENERATE_PUBLIC=true  # Если приватный ключ новый, публичный тоже нужно обновить
fi

# Генерируем публичный ключ, если требуется
if [[ "$GENERATE_PUBLIC" == true ]]; then
    echo "Генерирую новый публичный ключ..."
    openssl rsa -in "$PRIVATE_KEY_FILE" -pubout -out "$PUBLIC_KEY_FILE"
fi

echo "Оба ключа валидны и готовы к использованию!"

# -------------------------------------------------------------------

# Читаем файлы и заменяем переносы строк на \n
PRIVATE_KEY=$(sed ':a;N;$!ba;s/\n/\\n/g' $PRIVATE_KEY_FILE)
PUBLIC_KEY=$(sed ':a;N;$!ba;s/\n/\\n/g' $PUBLIC_KEY_FILE)

# Обновляем .env (замена или добавление переменных)
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

echo "Ключи успешно обновлены в .env"