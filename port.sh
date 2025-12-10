#!/bin/bash

# =================CONFIG=================
SOURCE_URL="$1"
BASE_URL="$2"
ROM_NAME="$3"

# Пути
WORKDIR=$(pwd)
INPUT="$WORKDIR/input"
OUT="$WORKDIR/out"
TEMP="$WORKDIR/temp"
TOOLS="$WORKDIR/tools"

# Создание папок
mkdir -p "$INPUT" "$OUT" "$TEMP" "$TOOLS"

# =================TOOLS SETUP=================
echo "=== [0/6] Настройка инструментов ==="

# Скачиваем sdat2img
wget -q https://raw.githubusercontent.com/xpirt/sdat2img/master/sdat2img.py -O "$TOOLS/sdat2img.py"
chmod +x "$TOOLS/sdat2img.py"

# Скачиваем make_ext4fs и img2sdat (из надежного источника, например, Erfan toolset)
# Для упрощения используем системный mkuserimg_mke2fs, если он есть, или качаем статику
# В Ubuntu 22.04 есть mkuserimg_mke2fs в пакете android-sdk-ext4-utils (мы установили e2fsprogs и sparse-utils)

# Функция конвертации dat.br -> img
convert_dat_br() {
    FILE="$1"
    NAME="$2"
    echo "Decompressing $NAME..."
    brotli -d "$FILE" -o "$TEMP/$NAME.new.dat"
    python3 "$TOOLS/sdat2img.py" "$TEMP/$NAME.transfer.list" "$TEMP/$NAME.new.dat" "$TEMP/$NAME.img"
    rm "$TEMP/$NAME.new.dat"
}

# =================DOWNLOAD=================
echo "=== [1/6] Загрузка прошивок ==="
aria2c -x16 -s16 "$SOURCE_URL" -d "$INPUT" -o source.zip
aria2c -x16 -s16 "$BASE_URL" -d "$INPUT" -o base.zip

# =================EXTRACT=================
echo "=== [2/6] Распаковка ==="

mkdir -p "$TEMP/source_raw" "$TEMP/base_raw"

# Распаковка Source
unzip -o "$INPUT/source.zip" -d "$TEMP/source_raw"
if [ -f "$TEMP/source_raw/payload.bin" ]; then
    echo "Обнаружен payload.bin в Source..."
    payload_dumper --input_file "$TEMP/source_raw/payload.bin" --output_directory "$TEMP/source_imgs"
    # Перемещаем нужные imgs
    mv "$TEMP/source_imgs/system.img" "$TEMP/system.img"
    mv "$TEMP/source_imgs/product.img" "$TEMP/product.img" 2>/dev/null
    mv "$TEMP/source_imgs/system_ext.img" "$TEMP/system_ext.img" 2>/dev/null
elif [ -f "$TEMP/source_raw/system.new.dat.br" ]; then
    echo "Обнаружен dat.br в Source..."
    cd "$TEMP/source_raw"
    convert_dat_br "system.new.dat.br" "system"
    convert_dat_br "product.new.dat.br" "product"
    convert_dat_br "system_ext.new.dat.br" "system_ext"
    mv system.img "$TEMP/"
    mv product.img "$TEMP/" 2>/dev/null
    mv system_ext.img "$TEMP/" 2>/dev/null
    cd "$WORKDIR"
fi

# Распаковка Base (Miatoll)
# Нам нужен только Vendor и Boot от базы
unzip -o "$INPUT/base.zip" -d "$TEMP/base_raw"
if [ -f "$TEMP/base_raw/vendor.new.dat.br" ]; then
    cd "$TEMP/base_raw"
    convert_dat_br "vendor.new.dat.br" "vendor"
    mv vendor.img "$TEMP/"
    mv boot.img "$OUT/" # Сразу в выходную папку
    mv dtbo.img "$OUT/" 2>/dev/null
    cd "$WORKDIR"
fi

# =================MOUNT & PATCH=================
echo "=== [3/6] Монтирование и Патчинг ==="

mkdir -p "$TEMP/mnt_system" "$TEMP/mnt_vendor" "$TEMP/mnt_product"

# Конвертация sparse в raw (чтобы смонтировать)
if [ -f "$TEMP/system.img" ]; then
    simg2img "$TEMP/system.img" "$TEMP/system_raw.img" 2>/dev/null || mv "$TEMP/system.img" "$TEMP/system_raw.img"
    sudo mount -o loop,rw "$TEMP/system_raw.img" "$TEMP/mnt_system"
fi

if [ -f "$TEMP/vendor.img" ]; then
    simg2img "$TEMP/vendor.img" "$TEMP/vendor_raw.img" 2>/dev/null || mv "$TEMP/vendor.img" "$TEMP/vendor_raw.img"
    sudo mount -o loop,rw "$TEMP/vendor_raw.img" "$TEMP/mnt_vendor"
fi

if [ -f "$TEMP/product.img" ]; then
    simg2img "$TEMP/product.img" "$TEMP/product_raw.img" 2>/dev/null || mv "$TEMP/product.img" "$TEMP/product_raw.img"
    sudo mount -o loop,rw "$TEMP/product_raw.img" "$TEMP/mnt_product"
fi

echo "--- Применение патчей Miatoll ---"

SYS_PROP="$TEMP/mnt_system/system/build.prop"
# Если build.prop не там, пробуем корень (для SAR)
[ ! -f "$SYS_PROP" ] && SYS_PROP="$TEMP/mnt_system/build.prop"

# 1. Изменение идентификаторов устройства
sudo sed -i 's/ro.product.device=.*/ro.product.device=miatoll/' "$SYS_PROP"
sudo sed -i 's/ro.product.system.device=.*/ro.product.system.device=miatoll/' "$SYS_PROP"
sudo sed -i 's/ro.product.name=.*/ro.product.name=miatoll/' "$SYS_PROP"

# 2. Добавление оверлеев (имитация)
# Копируем оверлеи из вендора базы в продукт порта (если есть место)
# sudo cp -r "$TEMP/mnt_vendor/overlay/"* "$TEMP/mnt_product/overlay/" 2>/dev/null

# 3. Фикс безопасного загрузчика (Secure Boot flag)
sudo echo "ro.secure=0" >> "$SYS_PROP"
sudo echo "ro.adb.secure=0" >> "$SYS_PROP"
sudo echo "ro.debuggable=1" >> "$SYS_PROP"

# 4. Удаление конфликтующих сервисов (Debloat для Miatoll)
# Часто удаляют dfps
sudo rm -rf "$TEMP/mnt_system/system/bin/dfps"
sudo rm -rf "$TEMP/mnt_vendor/bin/dfps"

# =================REPACK=================
echo "=== [4/6] Пересборка образов ==="

# Функция запаковки
repack_image() {
    NAME="$1"
    MNT_DIR="$2"
    SIZE_MB="$3" # Размер раздела в МБ (для Miatoll System ~3072, Vendor ~1024)
    
    echo "Repacking $NAME..."
    
    # Расчет размера байтах + запас 100Мб
    # sudo du -sb "$MNT_DIR"
    
    # Используем make_ext4fs (в Ubuntu это mkuserimg)
    # Аргументы: OutputFile, Size, MountPoint, SourceDir, fs_config(opt)
    
    # Размонтируем перед запаковкой? Нет, mkuserimg берет из папки.
    # Но для корректности лучше создать новую img из папки.
    
    # Важный момент: GHA может не иметь прав на чтение некоторых файлов root
    # Поэтому запаковываем через sudo
    
    # Размер: 3GB = 3221225472 (для System)
    # Размер: 1.5GB = 1610612736 (для Product)
    
    TARGET_SIZE=""
    if [ "$NAME" == "system" ]; then TARGET_SIZE="3500M"; fi
    if [ "$NAME" == "vendor" ]; then TARGET_SIZE="1200M"; fi
    if [ "$NAME" == "product" ]; then TARGET_SIZE="2000M"; fi
    if [ "$NAME" == "system_ext" ]; then TARGET_SIZE="1500M"; fi
    
    # Создаем образ
    sudo mkuserimg_mke2fs -s "$MNT_DIR" "$OUT/$NAME.img" ext4 "/$NAME" "$TARGET_SIZE" \
    -L "$NAME" -M "/$NAME"
}

repack_image "system" "$TEMP/mnt_system"
repack_image "vendor" "$TEMP/mnt_vendor"
[ -d "$TEMP/mnt_product" ] && repack_image "product" "$TEMP/mnt_product"

# =================CLEANUP=================
echo "=== [5/6] Очистка ==="
sudo umount "$TEMP/mnt_system" 2>/dev/null
sudo umount "$TEMP/mnt_vendor" 2>/dev/null
sudo umount "$TEMP/mnt_product" 2>/dev/null

# Удаляем исходники, оставляем только OUT
rm -rf "$INPUT" "$TEMP"

echo "=== Готово! Образы лежат в папке out/ ==="
ls -lh "$OUT"
