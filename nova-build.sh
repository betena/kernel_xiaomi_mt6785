#!/bin/bash

set -euo pipefail

SECONDS=0
KERNEL_PATH=$PWD
AK3_DIR="$KERNEL_PATH/Anykernel"
DEFCONFIG="${2:-begonia_user_defconfig}"
BUILD_USER="Abdul7852"
BUILD_HOST="NoVA"
TOOLCHAIN_DIR="$KERNEL_PATH/toolchain"
OUT_DIR="$KERNEL_PATH/out"

export KBUILD_BUILD_USER="$BUILD_USER"
export KBUILD_BUILD_HOST="$BUILD_HOST"
export ARCH=arm64
export PATH="$TOOLCHAIN_DIR/bin:$PATH"
export USE_HOST_LEX=yes

install_tools() {
    mkdir -p "$TOOLCHAIN_DIR" && cd "$TOOLCHAIN_DIR"
    curl -LO "https://raw.githubusercontent.com/Neutron-Toolchains/antman/main/antman"
    chmod +x antman && ./antman -S
    cd "$KERNEL_PATH"
}

regen_defconfig() {
    make O="$OUT_DIR" ARCH=arm64 "$DEFCONFIG" savedefconfig
    cp "$OUT_DIR/defconfig" "arch/arm64/configs/$DEFCONFIG"
}

build_kernel() {
    [[ ! -d "$TOOLCHAIN_DIR/bin" ]] && install_tools
    mkdir -p "$OUT_DIR"
    make O="$OUT_DIR" CROSS_COMPILE=aarch64-linux-gnu- LLVM=1 "$DEFCONFIG"
    exec 2> >(tee -a "$OUT_DIR/error.log" >&2)
    make -j"$(nproc)" \
        O="$OUT_DIR" \
        CC=clang LLVM=1 LLVM_IAS=1 \
        AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy \
        OBJDUMP=llvm-objdump STRIP=llvm-strip \
        LD=ld.lld \
        CROSS_COMPILE=aarch64-linux-gnu- \
        CROSS_COMPILE_ARM32=arm-linux-gnueabi-

    echo "=== [ОТЛАДКА] Начинаем проверку результатов компиляции ядра ==="
    
    # Задаем базовые типы выходов для проверки
    KERNEL_IMG_GZ_DTB="$OUT_DIR/arch/arm64/boot/Image.gz-dtb"
    KERNEL_IMG_GZ="$OUT_DIR/arch/arm64/boot/Image.gz"
    KERNEL_IMG_RAW="$OUT_DIR/arch/arm64/boot/Image"
    
    # Проверяем, что вообще сгенерировал компилятор в папке boot
    if [ -d "$OUT_DIR/arch/arm64/boot" ]; then
        echo "=== [ТРАССИРОВКА] Рекурсивный вывод файлов в out/.../boot перед проверкой: ==="
        ls -laR "$OUT_DIR/arch/arm64/boot"
    else
        echo "❌ КРИТИЧЕСКАЯ ОШИБКА: Директория сборки ядра '$OUT_DIR/arch/arm64/boot' вообще не создана!"
        echo "Это означает, что компиляция упала на этапе сборки исходников драйверов или ядра."
        exit 1
    fi

    # Автоматически определяем, какой именно тип ядра собрался
    if [[ -f "$KERNEL_IMG_GZ_DTB" ]]; then
        echo "   Выходной формат: Обнаружен классический Image.gz-dtb"
        KERNEL_IMG="$KERNEL_IMG_GZ_DTB"
    elif [[ -f "$KERNEL_IMG_GZ" ]]; then
        echo "   Выходной формат: Обнаружено универсальное сжатое ядро Image.gz"
        KERNEL_IMG="$KERNEL_IMG_GZ"
    elif [[ -f "$KERNEL_IMG_RAW" ]]; then
        echo "   Выходной формат: Обнаружено несжатое ядро Image"
        KERNEL_IMG="$KERNEL_IMG_RAW"
    else
        echo "❌ КРИТИЧЕСКАЯ ОШИБКА: Компилятор успешно завершил шаг, но файлы ядра (Image/Image.gz/Image.gz-dtb) отсутствуют!"
        echo "Проверьте лог компиляции Clang выше на наличие скрытых предупреждений, прервавших сборку."
        exit 1
    fi

    # Очищаем старые зипки в корне перед новой упаковкой
    rm -f ./*.zip
    
    SUBREV="4.14.$(grep "SUBLEVEL =" Makefile | awk '{print $3}')"
    REVISION="Nova-Begonia"
    ZIPBASE="${REVISION}-${SUBREV}"
    ZIPNAME="${ZIPBASE}.zip"
    i=1
    
    while [[ -f "$ZIPNAME" ]]; do
        ZIPNAME="${ZIPBASE}_v${i}.zip"
        ((i++))
    done

    echo "=== [ОТЛАДКА] Начинаем подготовку упаковщика Anykernel ==="
    # Скачиваем репозиторий Anykernel от автора, если папки еще нет
    if [[ ! -d Anykernel ]]; then
        echo "   Папка Anykernel не найдена. Клонируем репозиторий Wahid7852..."
        git clone --depth=1 https://github.com/Wahid7852/Anykernel Anykernel || {
            echo "❌ ОШИБКА: Не удалось склонировать репозиторий Anykernel с GitHub. Проверьте сеть или доступность репозитория."
            exit 1
        }
    fi

    # Копируем скомпилированное ядро в папку упаковщика под правильным именем для скрипта
    echo "   Копируем бинарник ядра из $KERNEL_IMG в Anykernel/Image.gz..."
    cp "$KERNEL_IMG" Anykernel/Image.gz || {
        echo "❌ ОШИБКА: Не удалось скопировать файл ядра в папку Anykernel."
        exit 1
    }
    
    # Копируем скомпилированные деревья устройств (DTB) в Anykernel
    DTB_SRC="$OUT_DIR/arch/arm64/boot/dts/mediatek/begonia.dtb"
    if [ -f "$DTB_SRC" ]; then
        echo "   Обнаружено дерево устройств begonia.dtb. Копируем в Anykernel..."
        cp "$DTB_SRC" Anykernel/dtb 2>/dev/null || cp "$DTB_SRC" Anykernel/ || {
            echo "⚠️ ПРЕДУПРЕЖДЕНИЕ: Не удалось скопировать dtb файл, но сборка продолжается."
        }
    else
        echo "⚠️ ПРЕДУПРЕЖДЕНИЕ: Файл дерева устройств begonia.dtb не найден по пути $DTB_SRC."
    fi
    
    # Удаляем временную папку boot, как это и было задумано автором
    rm -rf "$OUT_DIR/arch/arm64/boot"
    
    # Переходим в Anykernel, проверяем ветку и упаковываем строго через относительные пути
    cd Anykernel || {
        echo "❌ КРИТИЧЕСКАЯ ОШИБКА: Не удалось перейти в директорию Anykernel."
        exit 1
    }
    
    echo "   Переключаем ветку Anykernel на master..."
    git checkout master >/dev/null 2>&1 || true
    
    echo "=== [ТРАССИРОВКА] Полный список файлов внутри Anykernel перед финальной упаковкой в ZIP: ==="
    ls -laR
    
    echo "=== [ОТЛАДКА] Запускаем архиватор zip... ==="
    # Чистый синтаксис архивации без конфликтов масок Bash
    zip -r9 "../$ZIPNAME" . -x "*.git*" "README.md" "*placeholder*" || {
        echo "❌ КРИТИЧЕСКАЯ ОШИБКА: Сбой при упаковке файлов в ZIP-архив."
        cd ..
        exit 1
    }
    cd ..

    echo -e "\n🎉 СБОРКА УСПЕШНО ЗАВЕРШЕНА: $ZIPNAME"
    echo -e "Общее время: $((SECONDS / 60)) min $((SECONDS % 60)) sec"
}


case "${1:-}" in
    -r|--regen) regen_defconfig ;;
    -b|--build) build_kernel ;;
    *) echo -e "\nUsage: $0 [option] [defconfig]\n  -b, --build    Build kernel\n  -r, --regen    Regenerate defconfig\n"; exit 1 ;;
esac
