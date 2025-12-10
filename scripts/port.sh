#!/bin/bash

# Остановка при ошибках
set -e

# Аргументы
SOURCE_URL="$1"
BASE_URL="$2"
ROM_NAME="$3"

# Переменные путей
WORKDIR=$(pwd)
INPUT_DIR="$WORKDIR/input"
OUT_DIR="$WORKDIR/out"
TEMP_DIR="$WORKDIR/temp"
TOOLS_DIR="$WORKDIR/tools"

echo "=== [0/6] Инициализация ==="
mkdir -p "$INPUT_DIR" "$OUT_DIR" "$TEMP_DIR" "$TOOLS_DIR"

# Скачивание sdat2img (конвертер для MIUI прошивок)
wget -q https://raw.githubusercontent.com/xpirt/sdat2img/master/sdat2img.py -O "$TOOLS_DIR/sdat2img.py"
chmod +x "$TOOLS_DIR/sdat2img.py"

# Функция конвертации dat.br -> img
convert_dat_br() {
    FILE="$1"
    NAME="$2"
    echo "Распаковка Brotli: $NAME..."
    brotli -d "$FILE" -o "$TEMP_DIR/$NAME.new.dat"
    echo "Конвертация sdat в img..."
    python3 "$TOOLS_DIR/sdat2img.py" "$TEMP_DIR/$NAME.transfer.list" "$TEMP_DIR/$NAME.new.dat" "$TEMP_DIR/$NAME.img"
    rm "$TEMP_DIR/$NAME.new.dat" "$TEMP_DIR/$NAME.transfer.list"
}

# Функция извлечения содержимого IMG (Поддержка EXT4 и EROFS)
extract_img() {
    IMAGE="$1"
    FOLDER="$2"
    
    if [ ! -f "$IMAGE" ]; then return; fi
    
    echo "Обработка образа: $(basename "$IMAGE")"
    mkdir -p "$FOLDER"
    
    # Проверка на EROFS
    if file -sL "$IMAGE" | grep -q "EROFS"; then
        echo " >> Обнаружен EROFS. Распаковка..."
        fsck.erofs --extract="$FOLDER" "$IMAGE"
    else
        echo " >> Обнаружен EXT4/Sparse. Конвертация и монтирование..."
        # Попытка разжать sparse, если нужно
        simg2img "$IMAGE" "$TEMP_DIR/raw.img" 2>/dev/null || cp "$IMAGE" "$TEMP_DIR/raw.img"
        
        # Монтируем и копируем содержимое (чтобы избавиться от Read-Only)
        mkdir -p "$TEMP_DIR/mnt_tmp"
        mount -o loop,ro "$TEMP_DIR/raw.img" "$TEMP_DIR/mnt_tmp"
        cp -a "$TEMP_DIR/mnt_tmp/." "$FOLDER/"
        umount "$TEMP_DIR/mnt_tmp"
        rm -rf "$TEMP_DIR/mnt_tmp" "$TEMP_DIR/raw.img"
    fi
}

echo "=== [1/6] Загрузка прошивок ==="
echo "Скачивание Source ROM..."
aria2c -x16 -s16 -k1M "$SOURCE_URL" -d "$INPUT_DIR" -o source.zip
echo "Скачивание Base ROM..."
aria2c -x16 -s16 -k1M "$BASE_URL" -d "$INPUT_DIR" -o base.zip

echo "=== [2/6] Извлечение образов ==="

# 1. Обработка Source
mkdir -p "$TEMP_DIR/source_extracted"
unzip -o "$INPUT_DIR/source.zip" -d "$TEMP_DIR/source_extracted"

if [ -f "$TEMP_DIR/source_extracted/payload.bin" ]; then
    echo "Тип Source: Payload.bin"
    payload_dumper --input_file "$TEMP_DIR/source_extracted/payload.bin" --output_directory "$TEMP_DIR/source_imgs"
    # Перемещаем нужные разделы
    mv "$TEMP_DIR/source_imgs/system.img" "$TEMP_DIR/system.img"
    mv "$TEMP_DIR/source_imgs/product.img" "$TEMP_DIR/product.img" 2>/dev/null || true
    mv "$TEMP_DIR/source_imgs/system_ext.img" "$TEMP_DIR/system_ext.img" 2>/dev/null || true
elif [ -f "$TEMP_DIR/source_extracted/system.new.dat.br" ]; then
    echo "Тип Source: Dat.br"
    cd "$TEMP_DIR/source_extracted"
    convert_dat_br "system.new.dat.br" "system"
    [ -f "product.new.dat.br" ] && convert_dat_br "product.new.dat.br" "product"
    [ -f "system_ext.new.dat.br" ] && convert_dat_br "system_ext.new.dat.br" "system_ext"
    mv *.img "$TEMP_DIR/"
    cd "$WORKDIR"
fi

# 2. Обработка Base (Берем Vendor, Boot, DTBO)
mkdir -p "$TEMP_DIR/base_extracted"
unzip -o "$INPUT_DIR/base.zip" -d "$TEMP_DIR/base_extracted"

# Логика для Miatoll Base (обычно это .dat.br)
if [ -f "$TEMP_DIR/base_extracted/vendor.new.dat.br" ]; then
    cd "$TEMP_DIR/base_extracted"
    convert_dat_br "vendor.new.dat.br" "vendor"
    mv vendor.img "$TEMP_DIR/"
    # Перемещаем boot файлы сразу в output
    cp boot.img "$OUT_DIR/"
    cp dtbo.img "$OUT_DIR/" 2>/dev/null || true
    cp vbmeta.img "$OUT_DIR/" 2>/dev/null || true
    cd "$WORKDIR"
fi

# Очистка места после распаковки
rm -rf "$TEMP_DIR/source_extracted" "$TEMP_DIR/base_extracted" "$INPUT_DIR"

echo "=== [3/6] Распаковка файловых систем ==="
# Мы распаковываем всё в папки, чтобы можно было редактировать даже EROFS
extract_img "$TEMP_DIR/system.img" "$TEMP_DIR/d_system"
extract_img "$TEMP_DIR/product.img" "$TEMP_DIR/d_product"
extract_img "$TEMP_DIR/system_ext.img" "$TEMP_DIR/d_system_ext"
extract_img "$TEMP_DIR/vendor.img" "$TEMP_DIR/d_vendor"

# Удаляем тяжелые исходные .img файлы
rm "$TEMP_DIR/"*.img

echo "=== [4/6] Патчинг для Miatoll ==="

# Определяем пути к build.prop (учет SAR - System As Root)
if [ -f "$TEMP_DIR/d_system/system/build.prop" ]; then
    SYS_ROOT="$TEMP_DIR/d_system/system"
else
    SYS_ROOT="$TEMP_DIR/d_system"
fi
SYS_PROP="$SYS_ROOT/build.prop"

# 1. Изменение идентификаторов в system
echo "Патчинг build.prop..."
sed -i 's/ro.product.device=.*/ro.product.device=miatoll/' "$SYS_PROP"
sed -i 's/ro.product.system.device=.*/ro.product.system.device=miatoll/' "$SYS_PROP"
sed -i 's/ro.product.model=.*/ro.product.model=Redmi Note 9 Pro/' "$SYS_PROP"
sed -i 's/ro.product.name=.*/ro.product.name=miatoll/' "$SYS_PROP"

# 2. Secure Boot и Debug
echo "ro.secure=0" >> "$SYS_PROP"
echo "ro.adb.secure=0" >> "$SYS_PROP"
echo "ro.debuggable=1" >> "$SYS_PROP"

# 3. Miatoll специфичные фиксы (избежание бутлупов)
# Удаление dfps (Dynamic FPS), часто ломает порты
rm -rf "$SYS_ROOT/bin/dfps"
rm -rf "$TEMP_DIR/d_vendor/bin/dfps"

# 4. Копирование оверлеев (опционально, если структура совпадает)
# echo "Копирование Overlay..."
# cp -rf "$TEMP_DIR/d_vendor/overlay/"* "$TEMP_DIR/d_product/overlay/" 2>/dev/null || true

echo "=== [5/6] Запаковка в EXT4 ==="

# Функция запаковки
make_ext4() {
    DIR="$1"
    NAME="$2"
    SIZE="$3"
    
    if [ -d "$DIR" ]; then
        echo "Запаковка $NAME (Size: $SIZE)..."
        # Используем mkuserimg_mke2fs (стандартный инструмент Android SDK)
        # Синтаксис: src_dir output_file ext4 mount_point size
        mkuserimg_mke2fs -s "$DIR" "$OUT_DIR/$NAME.img" ext4 "/$NAME" "$SIZE" -L "$NAME" \
        -M "/$NAME" --inode_size 256
    fi
}

# Размеры задаем с запасом (Miatoll partition sizes)
# System: ~3.5GB, Vendor: ~1.2GB, Product: ~2.5GB
make_ext4 "$TEMP_DIR/d_system" "system" "3500M"
make_ext4 "$TEMP_DIR/d_vendor" "vendor" "1500M"
make_ext4 "$TEMP_DIR/d_product" "product" "2500M"
make_ext4 "$TEMP_DIR/d_system_ext" "system_ext" "2000M"

echo "=== [6/6] Завершено ==="
echo "Файлы для прошивки:"
ls -lh "$OUT_DIR"
