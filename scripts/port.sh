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

echo "=== [0/7] Инициализация и Загрузка инструментов ==="
mkdir -p "$INPUT_DIR" "$OUT_DIR" "$TEMP_DIR" "$TOOLS_DIR"

# 1. Скачивание payload-dumper-go
if [ ! -f "$TOOLS_DIR/pdg" ]; then
    echo "Скачивание payload-dumper-go..."
    wget -q "https://github.com/ssut/payload-dumper-go/releases/download/1.2.2/payload-dumper-go_1.2.2_linux_amd64.tar.gz" -O "$TOOLS_DIR/pdg.tar.gz"
    tar -xzf "$TOOLS_DIR/pdg.tar.gz" -C "$TOOLS_DIR"
    find "$TOOLS_DIR" -type f -name "payload-dumper-go" -exec mv {} "$TOOLS_DIR/pdg" \;
    chmod +x "$TOOLS_DIR/pdg"
fi

# 2. Скачивание magiskboot (для патчинга boot.img)
if [ ! -f "$TOOLS_DIR/magiskboot" ]; then
    echo "Скачивание magiskboot..."
    # Используем проверенный бинарник magiskboot
    wget -q "https://github.com/d0llbluesv4nus/miatollporter-not-/raw/main/tools/magiskboot" -O "$TOOLS_DIR/magiskboot" || \
    wget -q "https://raw.githubusercontent.com/xiaoxindada/magiskboot_ndk_on_linux/master/magiskboot" -O "$TOOLS_DIR/magiskboot"
    chmod +x "$TOOLS_DIR/magiskboot"
fi

# 3. Скачивание sdat2img
if [ ! -f "$TOOLS_DIR/sdat2img.py" ]; then
    wget -q https://raw.githubusercontent.com/xpirt/sdat2img/master/sdat2img.py -O "$TOOLS_DIR/sdat2img.py"
fi

# 4. Проверка наличия mkuserimg_mke2fs
# В GitHub Actions (Ubuntu) он обычно есть в пакете android-sdk-libsparse-utils, но на всякий случай берем из Erfan
if ! command -v mkuserimg_mke2fs &> /dev/null; then
    echo "Клонирование инструментов ErfanGSIs..."
    git clone --depth 1 https://github.com/erfanoabdi/ErfanGSIs.git "$TEMP_DIR/ErfanGSIs"
    cp -r "$TEMP_DIR/ErfanGSIs/tools/"* "$TOOLS_DIR/"
    rm -rf "$TEMP_DIR/ErfanGSIs"
    export PATH="$TOOLS_DIR:$PATH"
fi

chmod +x "$TOOLS_DIR"/*

# Функция конвертации dat.br -> img
convert_dat_br() {
    FILE="$1"
    NAME="$2"
    echo "Распаковка Brotli: $NAME..."
    brotli -d "$FILE" -o "$TEMP_DIR/$NAME.new.dat"
    echo "Конвертация sdat в img..."
    python3 "$TOOLS_DIR/sdat2img.py" "${NAME}.transfer.list" "$TEMP_DIR/$NAME.new.dat" "$TEMP_DIR/$NAME.img"
    rm -f "$TEMP_DIR/$NAME.new.dat"
}

# Функция извлечения содержимого IMG
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
        echo " >> Обнаружен EXT4/Sparse. Монтирование..."
        # Конвертируем sparse в raw, если нужно
        if file -sL "$IMAGE" | grep -q "sparse"; then
            simg2img "$IMAGE" "$TEMP_DIR/raw.img"
            IMG_TO_MOUNT="$TEMP_DIR/raw.img"
        else
            IMG_TO_MOUNT="$IMAGE"
        fi
        
        # Монтируем с sudo (нужно для loop)
        mkdir -p "$TEMP_DIR/mnt_tmp"
        sudo mount -o loop,ro "$IMG_TO_MOUNT" "$TEMP_DIR/mnt_tmp"
        # Копируем с сохранением атрибутов
        sudo cp -a "$TEMP_DIR/mnt_tmp/." "$FOLDER/"
        sudo umount "$TEMP_DIR/mnt_tmp"
        rm -rf "$TEMP_DIR/mnt_tmp" "$TEMP_DIR/raw.img"
        # Исправляем права на владение файлами (делаем доступными для runner)
        sudo chown -R $(whoami) "$FOLDER"
    fi
}

echo "=== [1/7] Загрузка прошивок ==="
echo "Скачивание Source..."
aria2c -x16 -s16 -k1M "$SOURCE_URL" -d "$INPUT_DIR" -o source.zip
echo "Скачивание Base..."
aria2c -x16 -s16 -k1M "$BASE_URL" -d "$INPUT_DIR" -o base.zip

echo "=== [2/7] Извлечение образов ==="

# 1. Source
mkdir -p "$TEMP_DIR/source_extracted"
unzip -o "$INPUT_DIR/source.zip" -d "$TEMP_DIR/source_extracted"

if [ -f "$TEMP_DIR/source_extracted/payload.bin" ]; then
    echo "Тип Source: Payload.bin"
    "$TOOLS_DIR/pdg" -o "$TEMP_DIR/source_imgs" -p "system,product,system_ext" "$TEMP_DIR/source_extracted/payload.bin"
    find "$TEMP_DIR/source_imgs" -name "system.img" -exec mv {} "$TEMP_DIR/system.img" \;
    find "$TEMP_DIR/source_imgs" -name "product.img" -exec mv {} "$TEMP_DIR/product.img" \;
    find "$TEMP_DIR/source_imgs" -name "system_ext.img" -exec mv {} "$TEMP_DIR/system_ext.img" \;
elif [ -f "$TEMP_DIR/source_extracted/system.new.dat.br" ]; then
    echo "Тип Source: Dat.br"
    cd "$TEMP_DIR/source_extracted"
    convert_dat_br "system.new.dat.br" "system"
    [ -f "product.new.dat.br" ] && convert_dat_br "product.new.dat.br" "product"
    [ -f "system_ext.new.dat.br" ] && convert_dat_br "system_ext.new.dat.br" "system_ext"
    # Перемещаем созданные img в TEMP_DIR (если convert_dat_br сохранил их в extracted)
    mv *.img "$TEMP_DIR/" 2>/dev/null || true
    cd "$WORKDIR"
fi

# 2. Base
mkdir -p "$TEMP_DIR/base_extracted"
unzip -o "$INPUT_DIR/base.zip" -d "$TEMP_DIR/base_extracted"

if [ -f "$TEMP_DIR/base_extracted/vendor.new.dat.br" ]; then
    echo "Тип Base: Dat.br"
    cd "$TEMP_DIR/base_extracted"
    convert_dat_br "vendor.new.dat.br" "vendor"
    # !!! ИСПРАВЛЕНИЕ: convert_dat_br уже кладет файл в $TEMP_DIR/vendor.img
    # Поэтому мы НЕ делаем mv vendor.img "$TEMP_DIR/", если его тут нет.
    
    # Копируем Boot файлы
    if [ -f "boot.img" ]; then cp boot.img "$TEMP_DIR/boot.img"; fi
    cp dtbo.img "$OUT_DIR/" 2>/dev/null || true
    cp vbmeta.img "$OUT_DIR/" 2>/dev/null || true
    cd "$WORKDIR"
fi

rm -rf "$TEMP_DIR/source_extracted" "$TEMP_DIR/base_extracted" "$INPUT_DIR"

echo "=== [3/7] Распаковка файловых систем ==="
extract_img "$TEMP_DIR/system.img" "$TEMP_DIR/d_system"
extract_img "$TEMP_DIR/product.img" "$TEMP_DIR/d_product"
extract_img "$TEMP_DIR/system_ext.img" "$TEMP_DIR/d_system_ext"
extract_img "$TEMP_DIR/vendor.img" "$TEMP_DIR/d_vendor"

rm -f "$TEMP_DIR/"*.img

echo "=== [4/7] Патчинг Boot (Permissive) ==="
# Это критически важно для загрузки порта
if [ -f "$TEMP_DIR/boot.img" ]; then
    echo "Патчинг boot.img на Permissive..."
    mkdir -p "$TEMP_DIR/boot_edit"
    cp "$TEMP_DIR/boot.img" "$TEMP_DIR/boot_edit/boot.img"
    cd "$TEMP_DIR/boot_edit"
    
    "$TOOLS_DIR/magiskboot" unpack boot.img
    
    # Добавляем androidboot.selinux=permissive в cmdline
    if [ -f "header" ]; then
        "$TOOLS_DIR/magiskboot" hexpatch header \
        "736b69705f696e697472616d667300" \
        "736b69705f696e697472616d667320616e64726f6964626f6f742e73656c696e75783d7065726d69737369766500" || true
        # На всякий случай простой метод через sed (если hexpatch не сработал или заголовок текстовый)
        sed -i 's/cmdline=/cmdline=androidboot.selinux=permissive /' header
    fi
    
    "$TOOLS_DIR/magiskboot" repack boot.img
    mv new-boot.img "$OUT_DIR/boot.img"
    cd "$WORKDIR"
else
    echo "Внимание: boot.img не найден, пропускаем патчинг!"
fi

echo "=== [5/7] Патчинг системы для Miatoll ==="
# Определяем путь к системе
if [ -f "$TEMP_DIR/d_system/system/build.prop" ]; then
    SYS_ROOT="$TEMP_DIR/d_system/system"
else
    SYS_ROOT="$TEMP_DIR/d_system"
fi
SYS_PROP="$SYS_ROOT/build.prop"

echo "Патчинг $SYS_PROP..."
if [ -f "$SYS_PROP" ]; then
    sed -i 's/ro.product.device=.*/ro.product.device=miatoll/' "$SYS_PROP"
    sed -i 's/ro.product.system.device=.*/ro.product.system.device=miatoll/' "$SYS_PROP"
    sed -i 's/ro.product.model=.*/ro.product.model=Redmi Note 9 Pro/' "$SYS_PROP"
    sed -i 's/ro.product.name=.*/ro.product.name=miatoll/' "$SYS_PROP"
    # Отключаем проверки безопасности
    echo "ro.secure=0" >> "$SYS_PROP"
    echo "ro.adb.secure=0" >> "$SYS_PROP"
    echo "ro.debuggable=1" >> "$SYS_PROP"
    # Разрешаем установку APK из неизвестных источников по умолчанию
    echo "ro.unknown.sources.enabled=1" >> "$SYS_PROP"
else
    echo "ВНИМАНИЕ: build.prop не найден!"
fi

# Удаляем конфликтующие файлы
rm -rf "$SYS_ROOT/bin/dfps" "$TEMP_DIR/d_vendor/bin/dfps"
rm -rf "$SYS_ROOT/recovery-from-boot.p"

echo "=== [6/7] Запаковка в EXT4 ==="

make_ext4() {
    DIR="$1"
    NAME="$2"
    
    if [ -d "$DIR" ]; then
        echo "Расчет размера для $NAME..."
        # Считаем размер файлов в МБ и добавляем 150МБ запаса
        SIZE_MB=$(du -sm "$DIR" | awk '{print $1}')
        NEW_SIZE=$((SIZE_MB + 150))
        echo "Размер: ${NEW_SIZE}M"
        
        echo "Запаковка $NAME.img..."
        # file_contexts по умолчанию "u:object_r:system_file:s0" для всех файлов,
        # это "грязный" хак, но он работает в паре с permissive ядром.
        mkuserimg_mke2fs -s "$DIR" "$OUT_DIR/$NAME.img" ext4 "/$NAME" "${NEW_SIZE}M" -L "$NAME" -M "/$NAME" --inode_size 256
    fi
}

make_ext4 "$TEMP_DIR/d_system" "system"
make_ext4 "$TEMP_DIR/d_vendor" "vendor"
make_ext4 "$TEMP_DIR/d_product" "product"
make_ext4 "$TEMP_DIR/d_system_ext" "system_ext"

echo "=== [7/7] Завершено ==="
ls -lh "$OUT_DIR"    mkdir -p "$FOLDER"
    
    # Проверка на EROFS
    if file -sL "$IMAGE" | grep -q "EROFS"; then
        echo " >> Обнаружен EROFS. Распаковка..."
        fsck.erofs --extract="$FOLDER" "$IMAGE"
    else
        echo " >> Обнаружен EXT4/Sparse. Конвертация и монтирование..."
        # Попытка разжать sparse
        simg2img "$IMAGE" "$TEMP_DIR/raw.img" 2>/dev/null || cp "$IMAGE" "$TEMP_DIR/raw.img"
        
        # Монтируем
        mkdir -p "$TEMP_DIR/mnt_tmp"
        mount -o loop,ro "$TEMP_DIR/raw.img" "$TEMP_DIR/mnt_tmp"
        cp -a "$TEMP_DIR/mnt_tmp/." "$FOLDER/"
        umount "$TEMP_DIR/mnt_tmp"
        rm -rf "$TEMP_DIR/mnt_tmp" "$TEMP_DIR/raw.img"
    fi
}

echo "=== [1/6] Загрузка прошивок ==="
echo "Скачивание Source..."
aria2c -x16 -s16 -k1M "$SOURCE_URL" -d "$INPUT_DIR" -o source.zip
echo "Скачивание Base..."
aria2c -x16 -s16 -k1M "$BASE_URL" -d "$INPUT_DIR" -o base.zip

echo "=== [2/6] Извлечение образов ==="

# 1. Source
mkdir -p "$TEMP_DIR/source_extracted"
unzip -o "$INPUT_DIR/source.zip" -d "$TEMP_DIR/source_extracted"

if [ -f "$TEMP_DIR/source_extracted/payload.bin" ]; then
    echo "Тип Source: Payload.bin"
    "$TOOLS_DIR/pdg" -o "$TEMP_DIR/source_imgs" -p "system,product,system_ext" "$TEMP_DIR/source_extracted/payload.bin"
    # Перемещаем (ищем гибко, так как имена могут отличаться)
    find "$TEMP_DIR/source_imgs" -name "system.img" -exec mv {} "$TEMP_DIR/system.img" \;
    find "$TEMP_DIR/source_imgs" -name "product.img" -exec mv {} "$TEMP_DIR/product.img" \;
    find "$TEMP_DIR/source_imgs" -name "system_ext.img" -exec mv {} "$TEMP_DIR/system_ext.img" \;
elif [ -f "$TEMP_DIR/source_extracted/system.new.dat.br" ]; then
    echo "Тип Source: Dat.br"
    cd "$TEMP_DIR/source_extracted"
    convert_dat_br "system.new.dat.br" "system"
    [ -f "product.new.dat.br" ] && convert_dat_br "product.new.dat.br" "product"
    [ -f "system_ext.new.dat.br" ] && convert_dat_br "system_ext.new.dat.br" "system_ext"
    mv *.img "$TEMP_DIR/" 2>/dev/null || true
    cd "$WORKDIR"
fi

# 2. Base
mkdir -p "$TEMP_DIR/base_extracted"
unzip -o "$INPUT_DIR/base.zip" -d "$TEMP_DIR/base_extracted"

if [ -f "$TEMP_DIR/base_extracted/vendor.new.dat.br" ]; then
    echo "Тип Base: Dat.br"
    cd "$TEMP_DIR/base_extracted"
    convert_dat_br "vendor.new.dat.br" "vendor"
    mv vendor.img "$TEMP_DIR/"
    
    # Копируем Boot файлы (подавляем ошибки, если их нет)
    cp boot.img "$OUT_DIR/" 2>/dev/null || echo "Info: boot.img not found"
    cp dtbo.img "$OUT_DIR/" 2>/dev/null || echo "Info: dtbo.img not found"
    cp vbmeta.img "$OUT_DIR/" 2>/dev/null || echo "Info: vbmeta.img not found"
    cd "$WORKDIR"
fi

rm -rf "$TEMP_DIR/source_extracted" "$TEMP_DIR/base_extracted" "$INPUT_DIR"

echo "=== [3/6] Распаковка файловых систем ==="
extract_img "$TEMP_DIR/system.img" "$TEMP_DIR/d_system"
extract_img "$TEMP_DIR/product.img" "$TEMP_DIR/d_product"
extract_img "$TEMP_DIR/system_ext.img" "$TEMP_DIR/d_system_ext"
extract_img "$TEMP_DIR/vendor.img" "$TEMP_DIR/d_vendor"

rm -f "$TEMP_DIR/"*.img

echo "=== [4/6] Патчинг для Miatoll ==="
# Определяем где лежит build.prop (для System-as-root или нет)
if [ -f "$TEMP_DIR/d_system/system/build.prop" ]; then
    SYS_ROOT="$TEMP_DIR/d_system/system"
else
    SYS_ROOT="$TEMP_DIR/d_system"
fi
SYS_PROP="$SYS_ROOT/build.prop"

echo "Патчинг $SYS_PROP..."
if [ -f "$SYS_PROP" ]; then
    sed -i 's/ro.product.device=.*/ro.product.device=miatoll/' "$SYS_PROP"
    sed -i 's/ro.product.system.device=.*/ro.product.system.device=miatoll/' "$SYS_PROP"
    sed -i 's/ro.product.model=.*/ro.product.model=Redmi Note 9 Pro/' "$SYS_PROP"
    sed -i 's/ro.product.name=.*/ro.product.name=miatoll/' "$SYS_PROP"
    echo "ro.secure=0" >> "$SYS_PROP"
    echo "ro.adb.secure=0" >> "$SYS_PROP"
    echo "ro.debuggable=1" >> "$SYS_PROP"
else
    echo "ВНИМАНИЕ: build.prop не найден, патчинг пропущен!"
fi

# Debloat (удаление проблемных файлов)
rm -rf "$SYS_ROOT/bin/dfps" "$TEMP_DIR/d_vendor/bin/dfps"

echo "=== [5/6] Запаковка в EXT4 ==="

make_ext4() {
    DIR="$1"
    NAME="$2"
    SIZE="$3"
    
    if [ -d "$DIR" ]; then
        echo "Запаковка $NAME..."
        # Используем mkuserimg_mke2fs (он теперь точно есть в PATH)
        mkuserimg_mke2fs -s "$DIR" "$OUT_DIR/$NAME.img" ext4 "/$NAME" "$SIZE" -L "$NAME" -M "/$NAME" --inode_size 256
    fi
}

make_ext4 "$TEMP_DIR/d_system" "system" "3500M"
make_ext4 "$TEMP_DIR/d_vendor" "vendor" "1500M"
make_ext4 "$TEMP_DIR/d_product" "product" "2500M"
make_ext4 "$TEMP_DIR/d_system_ext" "system_ext" "2000M"

echo "=== [6/6] Завершено ==="
ls -lh "$OUT_DIR"
