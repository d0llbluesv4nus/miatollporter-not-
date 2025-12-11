#!/bin/bash

# Останавливать скрипт при критических ошибках
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

echo "=== [0/7] Подготовка папок ==="
mkdir -p "$INPUT_DIR" "$OUT_DIR" "$TEMP_DIR" "$TOOLS_DIR"

echo "=== [1/7] Загрузка инструментов (Direct Download) ==="

# 1. Payload Dumper
if [ ! -f "$TOOLS_DIR/pdg" ]; then
    echo "Скачивание payload-dumper-go..."
    wget -q "https://github.com/ssut/payload-dumper-go/releases/download/1.2.2/payload-dumper-go_1.2.2_linux_amd64.tar.gz" -O "$TOOLS_DIR/pdg.tar.gz"
    tar -xzf "$TOOLS_DIR/pdg.tar.gz" -C "$TOOLS_DIR"
    find "$TOOLS_DIR" -type f -name "payload-dumper-go" -exec mv {} "$TOOLS_DIR/pdg" \;
    chmod +x "$TOOLS_DIR/pdg"
fi

# 2. MagiskBoot
if [ ! -f "$TOOLS_DIR/magiskboot" ]; then
    echo "Скачивание magiskboot..."
    wget -q "https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk" -O "$TEMP_DIR/magisk.apk"
    unzip -oj "$TEMP_DIR/magisk.apk" "lib/x86_64/libmagiskboot.so" -d "$TOOLS_DIR"
    mv "$TOOLS_DIR/libmagiskboot.so" "$TOOLS_DIR/magiskboot"
    chmod +x "$TOOLS_DIR/magiskboot"
    rm -f "$TEMP_DIR/magisk.apk"
fi

# 3. sdat2img
if [ ! -f "$TOOLS_DIR/sdat2img.py" ]; then
    wget -q https://raw.githubusercontent.com/xpirt/sdat2img/master/sdat2img.py -O "$TOOLS_DIR/sdat2img.py"
fi

# 4. ИНСТРУМЕНТЫ ЗАПАКОВКИ (Скачиваем бинарники напрямую)
# Это решает проблему "command not found"
echo "Скачивание инструментов запаковки..."
BASE_TOOLS_URL="https://raw.githubusercontent.com/erfanoabdi/ErfanGSIs/master/tools"

wget -q "$BASE_TOOLS_URL/mkuserimg_mke2fs.sh" -O "$TOOLS_DIR/mkuserimg_mke2fs"
wget -q "$BASE_TOOLS_URL/e2fsdroid" -O "$TOOLS_DIR/e2fsdroid"
wget -q "$BASE_TOOLS_URL/make_ext4fs" -O "$TOOLS_DIR/make_ext4fs"
wget -q "$BASE_TOOLS_URL/mke2fs" -O "$TOOLS_DIR/mke2fs"

chmod +x "$TOOLS_DIR"/*
export PATH="$TOOLS_DIR:$PATH"

# --- ФУНКЦИИ ---

convert_dat_br() {
    FILE="$1"
    NAME="$2"
    echo "Распаковка Brotli: $NAME..."
    if [ -f "$FILE" ]; then
        brotli -d "$FILE" -o "$TEMP_DIR/$NAME.new.dat"
        python3 "$TOOLS_DIR/sdat2img.py" "${NAME}.transfer.list" "$TEMP_DIR/$NAME.new.dat" "$TEMP_DIR/$NAME.img"
        rm -f "$TEMP_DIR/$NAME.new.dat"
    fi
}

extract_img() {
    IMAGE="$1"
    FOLDER="$2"
    if [ ! -f "$IMAGE" ]; then return; fi
    echo "Обработка образа: $(basename "$IMAGE")"
    mkdir -p "$FOLDER"
    
    if file -sL "$IMAGE" | grep -q "EROFS"; then
        fsck.erofs --extract="$FOLDER" "$IMAGE"
    else
        if file -sL "$IMAGE" | grep -q "sparse"; then
            simg2img "$IMAGE" "$TEMP_DIR/raw.img"
            IMG_TO_MOUNT="$TEMP_DIR/raw.img"
        else
            IMG_TO_MOUNT="$IMAGE"
        fi
        
        mkdir -p "$TEMP_DIR/mnt_tmp"
        sudo mount -o loop,ro "$IMG_TO_MOUNT" "$TEMP_DIR/mnt_tmp"
        sudo cp -a "$TEMP_DIR/mnt_tmp/." "$FOLDER/"
        sudo umount "$TEMP_DIR/mnt_tmp"
        rm -rf "$TEMP_DIR/mnt_tmp" "$TEMP_DIR/raw.img"
        sudo chown -R $(whoami) "$FOLDER"
    fi
}

echo "=== [2/7] Загрузка прошивок ==="
echo "Скачивание Source..."
aria2c -x16 -s16 -k1M "$SOURCE_URL" -d "$INPUT_DIR" -o source.zip
echo "Скачивание Base..."
aria2c -x16 -s16 -k1M "$BASE_URL" -d "$INPUT_DIR" -o base.zip

echo "=== [3/7] Извлечение образов ==="

# --- SOURCE ---
mkdir -p "$TEMP_DIR/source_extracted"
unzip -o "$INPUT_DIR/source.zip" -d "$TEMP_DIR/source_extracted"

if [ -f "$TEMP_DIR/source_extracted/payload.bin" ]; then
    "$TOOLS_DIR/pdg" -o "$TEMP_DIR/source_imgs" -p "system,product,system_ext" "$TEMP_DIR/source_extracted/payload.bin"
    find "$TEMP_DIR/source_imgs" -name "system.img" -exec mv {} "$TEMP_DIR/system.img" \;
    find "$TEMP_DIR/source_imgs" -name "product.img" -exec mv {} "$TEMP_DIR/product.img" \;
    find "$TEMP_DIR/source_imgs" -name "system_ext.img" -exec mv {} "$TEMP_DIR/system_ext.img" \;
elif [ -f "$TEMP_DIR/source_extracted/system.new.dat.br" ]; then
    cd "$TEMP_DIR/source_extracted"
    convert_dat_br "system.new.dat.br" "system"
    convert_dat_br "product.new.dat.br" "product"
    convert_dat_br "system_ext.new.dat.br" "system_ext"
    mv *.img "$TEMP_DIR/" 2>/dev/null || true
    cd "$WORKDIR"
fi

# --- BASE ---
mkdir -p "$TEMP_DIR/base_extracted"
unzip -o "$INPUT_DIR/base.zip" -d "$TEMP_DIR/base_extracted"

echo "Обработка Base ROM..."
if [ -f "$TEMP_DIR/base_extracted/payload.bin" ]; then
    # Пробуем извлечь всё
    "$TOOLS_DIR/pdg" -o "$TEMP_DIR/base_imgs" -p "vendor,boot,dtbo,vbmeta" "$TEMP_DIR/base_extracted/payload.bin"
    
    find "$TEMP_DIR/base_imgs" -name "vendor.img" -exec mv {} "$TEMP_DIR/vendor.img" \;
    find "$TEMP_DIR/base_imgs" -name "boot.img" -exec cp {} "$TEMP_DIR/boot.img" \;
    find "$TEMP_DIR/base_imgs" -name "dtbo.img" -exec cp {} "$OUT_DIR/dtbo.img" \;
    find "$TEMP_DIR/base_imgs" -name "vbmeta.img" -exec cp {} "$OUT_DIR/vbmeta.img" \;

elif [ -f "$TEMP_DIR/base_extracted/vendor.new.dat.br" ]; then
    cd "$TEMP_DIR/base_extracted"
    convert_dat_br "vendor.new.dat.br" "vendor"
    cd "$WORKDIR"
    find "$TEMP_DIR/base_extracted" -type f -iname "boot.img" -exec cp {} "$TEMP_DIR/boot.img" \; -quit
fi

# СПАСЕНИЕ: Если boot.img нет
if [ ! -f "$TEMP_DIR/boot.img" ]; then
    echo "ВНИМАНИЕ: Boot.img не найден в Base! Скачиваем Rescue Boot (Stock Miatoll)..."
    wget -q "https://github.com/d0llbluesv4nus/miatollporter-not-/releases/download/tools/boot_miatoll_stock.img" -O "$TEMP_DIR/boot.img" || \
    echo "Не удалось скачать rescue boot."
fi

rm -rf "$TEMP_DIR/source_extracted" "$TEMP_DIR/base_extracted" "$INPUT_DIR"

echo "=== [4/7] Распаковка файловых систем ==="
[ -f "$TEMP_DIR/system.img" ] && extract_img "$TEMP_DIR/system.img" "$TEMP_DIR/d_system"
[ -f "$TEMP_DIR/product.img" ] && extract_img "$TEMP_DIR/product.img" "$TEMP_DIR/d_product"
[ -f "$TEMP_DIR/system_ext.img" ] && extract_img "$TEMP_DIR/system_ext.img" "$TEMP_DIR/d_system_ext"
[ -f "$TEMP_DIR/vendor.img" ] && extract_img "$TEMP_DIR/vendor.img" "$TEMP_DIR/d_vendor"

rm -f "$TEMP_DIR/"*.img

echo "=== [5/7] Патчинг Boot (Permissive) ==="
if [ -f "$TEMP_DIR/boot.img" ]; then
    mkdir -p "$TEMP_DIR/boot_edit"
    cp "$TEMP_DIR/boot.img" "$TEMP_DIR/boot_edit/boot.img"
    cd "$TEMP_DIR/boot_edit"
    
    "$TOOLS_DIR/magiskboot" unpack boot.img || true
    if [ -f "header" ]; then
        "$TOOLS_DIR/magiskboot" hexpatch header "736b69705f696e697472616d667300" "736b69705f696e697472616d667320616e64726f6964626f6f742e73656c696e75783d7065726d69737369766500" || true
        sed -i 's/cmdline=/cmdline=androidboot.selinux=permissive /' header
    fi
    "$TOOLS_DIR/magiskboot" repack boot.img || true
    
    if [ -f "new-boot.img" ]; then
        mv new-boot.img "$OUT_DIR/boot.img"
    else
        cp "$TEMP_DIR/boot.img" "$OUT_DIR/boot.img"
    fi
    cd "$WORKDIR"
fi

echo "=== [6/7] Патчинг системы для Miatoll ==="
if [ -f "$TEMP_DIR/d_system/system/build.prop" ]; then
    SYS_ROOT="$TEMP_DIR/d_system/system"
else
    SYS_ROOT="$TEMP_DIR/d_system"
fi
SYS_PROP="$SYS_ROOT/build.prop"

if [ -f "$SYS_PROP" ]; then
    sed -i 's/ro.product.device=.*/ro.product.device=miatoll/' "$SYS_PROP"
    sed -i 's/ro.product.system.device=.*/ro.product.system.device=miatoll/' "$SYS_PROP"
    sed -i 's/ro.product.model=.*/ro.product.model=Redmi Note 9 Pro/' "$SYS_PROP"
    sed -i 's/ro.product.name=.*/ro.product.name=miatoll/' "$SYS_PROP"
    echo "ro.secure=0" >> "$SYS_PROP"
    echo "ro.adb.secure=0" >> "$SYS_PROP"
    echo "ro.debuggable=1" >> "$SYS_PROP"
fi

rm -rf "$SYS_ROOT/bin/dfps" "$TEMP_DIR/d_vendor/bin/dfps"
rm -rf "$SYS_ROOT/recovery-from-boot.p"

echo "=== [7/7] Запаковка в EXT4 ==="

# Важно: добавляем tools в PATH перед запаковкой
export PATH="$TOOLS_DIR:$PATH"

make_ext4() {
    DIR="$1"
    NAME="$2"
    
    if [ -d "$DIR" ]; then
        echo "Расчет размера для $NAME..."
        SIZE_MB=$(du -sm "$DIR" | awk '{print $1}')
        NEW_SIZE=$((SIZE_MB + 150))
        
        echo "Запаковка $NAME.img..."
        # Вызываем скачанный скрипт напрямую
        bash "$TOOLS_DIR/mkuserimg_mke2fs" -s "$DIR" "$OUT_DIR/$NAME.img" ext4 "/$NAME" "${NEW_SIZE}M" -L "$NAME" -M "/$NAME" --inode_size 256
    fi
}

make_ext4 "$TEMP_DIR/d_system" "system"
make_ext4 "$TEMP_DIR/d_vendor" "vendor"
make_ext4 "$TEMP_DIR/d_product" "product"
make_ext4 "$TEMP_DIR/d_system_ext" "system_ext"

echo "=== ГОТОВО ==="
ls -lh "$OUT_DIR"
