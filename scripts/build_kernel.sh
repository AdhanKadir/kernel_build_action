#!/usr/bin/env bash
set -euo pipefail

error() {
    echo "Error: $1" >&2
    exit 1
}

SU() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

normalize_toolchain_dir() {
    local dir_path=$1
    local dir_name=$2

    if [ ! -d "$dir_path" ]; then
        return
    fi

    if [ ! -d "$dir_path/bin" ]; then
        echo "Normalizing $dir_name directory structure..."
        for nested_dir in "$dir_path"/*/*; do
            if [ -d "$nested_dir" ]; then
                mv "$nested_dir"/* "$dir_path/" 2>/dev/null || true
                break
            fi
        done
    fi
}

download_and_extract() {
    local url=$1
    local output_name=$2
    local extract_dir=$3
    local branch=${4:-main}

    mkdir -p -v "$extract_dir"
    case "$url" in
        *.zip)
            aria2c -o "${output_name}.zip" "$url"
            unzip -q "${output_name}.zip" -d "$extract_dir"
            ;;
        *.tar.*|*.gz|*.xz|*.bz2)
            aria2c -o "${output_name}.${url##*.}" "$url"
            tar -C "$extract_dir" -xf "${output_name}.${url##*.}"
            ;;
        *)
            git clone --depth="$INPUT_DEPTH" -b "$branch" "$url" "$extract_dir"
            ;;
    esac
}

install_android_sdk() {
    local sdk_root="$HOME/android-sdk"
    local cmdline_tools_zip="commandlinetools-linux-11076708_latest.zip"
    local cmdline_tools_url="https://dl.google.com/android/repository/${cmdline_tools_zip}"

    mkdir -p "$sdk_root/cmdline-tools"
    if [ ! -d "$sdk_root/cmdline-tools/latest" ]; then
        echo "Downloading Android command line tools"
        aria2c -o "$cmdline_tools_zip" "$cmdline_tools_url"
        unzip -q "$cmdline_tools_zip" -d "$sdk_root/cmdline-tools"
        rm -f "$cmdline_tools_zip"
        mv "$sdk_root/cmdline-tools/cmdline-tools" "$sdk_root/cmdline-tools/latest"
        chmod +x "$sdk_root/cmdline-tools/latest/bin"/*
    fi

    export ANDROID_SDK_ROOT="$sdk_root"
    export SDKMANAGER_BIN="$ANDROID_SDK_ROOT/cmdline-tools/latest/bin/sdkmanager"
    export PATH="$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$PATH"
}

install_ndk() {
    local ndk_version="$1"
    local sdk_root="$HOME/android-sdk"

    install_android_sdk

    set +o pipefail
    yes | "$SDKMANAGER_BIN" --sdk_root="$sdk_root" --licenses >/dev/null
    yes | "$SDKMANAGER_BIN" --sdk_root="$sdk_root" "ndk;$ndk_version"
    set -o pipefail

    NDK_HOME="$sdk_root/ndk/$ndk_version"
    if [ ! -d "$NDK_HOME" ]; then
        error "Failed to install Android NDK $ndk_version"
    fi

    export NDK_HOME
}

if [[ ${GITHUB_ACTIONS} != "true" || ${OSTYPE} != "linux-gnu" || ( ! -f /bin/apt && ! -f /bin/pacman ) ]]; then
    error "This action requires GitHub Actions Linux runners (Debian-based or ArchLinux-based). Current: OSTYPE=${OSTYPE}, GITHUB_ACTIONS=${GITHUB_ACTIONS}"
fi

echo "::group::Installing dependency packages"
if [ -f /bin/apt ]; then
    SU apt-get update
    SU apt-get install --no-install-recommends -y \
        binutils git make bc bison openssl curl zip kmod cpio flex libelf-dev \
        libssl-dev libtfm-dev libc6-dev device-tree-compiler ca-certificates \
        python3 xz-utils aria2 build-essential ccache pigz parallel jq opam libpcre3-dev
else
    pacman -Syyu --noconfirm git base-devel opam aria2 python3 ccache pigz parallel jq pcre2
fi
echo "::endgroup::"

if [ "$INPUT_AOSP_CLANG" == "true" ]; then
    echo "::group::Installing Android NDK toolchain via sdkmanager"
    install_ndk "$INPUT_NDK_VERSION"
    NDK_LLVM_ROOT="$NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64"
    NDK_LLVM_BIN="$NDK_LLVM_ROOT/bin"
    if [ ! -d "$NDK_LLVM_BIN" ]; then
        error "Android NDK LLVM toolchain not found at $NDK_LLVM_BIN"
    fi
    if [ -x "$NDK_LLVM_BIN/ld.lld" ]; then
        ln -sf "$NDK_LLVM_BIN/ld.lld" "$NDK_LLVM_BIN/aarch64-linux-android-ld"
        ln -sf "$NDK_LLVM_BIN/ld.lld" "$NDK_LLVM_BIN/arm-linux-androideabi-ld"
    fi

    LLVM_TOOLCHAINS=(nm objcopy objdump readelf strip size ranlib addr2line ar)
    for tool in "${LLVM_TOOLCHAINS[@]}"; do
        llvm_tool="$NDK_LLVM_BIN/llvm-$tool"
        if [ -x "$llvm_tool" ]; then
            ln -sf "$llvm_tool" "$NDK_LLVM_BIN/aarch64-linux-android-$tool"
            ln -sf "$llvm_tool" "$NDK_LLVM_BIN/arm-linux-androideabi-$tool"
        fi
    done
    rm -rf "$HOME/clang"
    ln -s "$NDK_LLVM_ROOT" "$HOME/clang"
    echo "::endgroup::"
elif [ -n "$INPUT_OTHER_CLANG_URL" ]; then
    echo "::group::Downloading Third-party Clang"
    download_and_extract "$INPUT_OTHER_CLANG_URL" "clang" "$HOME/clang" "$INPUT_OTHER_CLANG_BRANCH"
    normalize_toolchain_dir "$HOME/clang" "Clang"
    if ! ls "$HOME/clang"/*-linux-* &>/dev/null; then
        echo "Binutils not found in clang directory. Downloading AOSP GCC"
        export NEED_GCC=1
    fi
    echo "::endgroup::"
else
    if [ -f /bin/apt ]; then
        SU apt-get install -y clang lld binutils-aarch64-linux-gnu binutils-arm-linux-gnueabihf
    else
        pacman -S --noconfirm clang lld llvm
    fi
fi

if { [ "$INPUT_AOSP_GCC" == "true" ] && [ "$INPUT_AOSP_CLANG" != "true" ]; } || [ -n "${NEED_GCC:-}" ]; then
    echo "::group::Downloading AOSP GCC"
    if [ -n "$INPUT_ANDROID_VERSION" ]; then
        AOSP_GCC64_URL="https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9"
        AOSP_GCC32_URL="https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/arm/arm-linux-androideabi-4.9"
        AOSP_GCC_BRANCH="android$INPUT_ANDROID_VERSION-release"
    else
        AOSP_GCC64_URL="https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9/+archive/refs/tags/android-12.1.0_r27.tar.gz"
        AOSP_GCC32_URL="https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/arm/arm-linux-androideabi-4.9/+archive/refs/tags/android-12.1.0_r27.tar.gz"
    fi
    download_and_extract "$AOSP_GCC64_URL" "gcc-aarch64" "$HOME/gcc-64" "${AOSP_GCC_BRANCH:-main}"
    download_and_extract "$AOSP_GCC32_URL" "gcc-arm" "$HOME/gcc-32" "${AOSP_GCC_BRANCH:-main}"
    echo "::endgroup::"
elif [ -n "$INPUT_OTHER_GCC64_URL" ] || [ -n "$INPUT_OTHER_GCC32_URL" ]; then
    echo "::group::Downloading Third-party GCC"
    if [ -n "$INPUT_OTHER_GCC64_URL" ]; then
        download_and_extract "$INPUT_OTHER_GCC64_URL" "gcc-aarch64" "$HOME/gcc-64" "$INPUT_OTHER_GCC64_BRANCH"
    fi
    if [ -n "$INPUT_OTHER_GCC32_URL" ]; then
        download_and_extract "$INPUT_OTHER_GCC32_URL" "gcc-arm" "$HOME/gcc-32" "$INPUT_OTHER_GCC32_BRANCH"
    fi
    echo "::endgroup::"
fi

normalize_toolchain_dir "$HOME/gcc-64" "GCC64"
normalize_toolchain_dir "$HOME/gcc-32" "GCC32"

echo "::group::Pulling Kernel Source"
git clone --recursive -b "$INPUT_KERNEL_BRANCH" --depth="$INPUT_DEPTH" "$INPUT_KERNEL_URL" "kernel/$INPUT_KERNEL_DIR"
echo "::endgroup::"

if [ "$INPUT_VENDOR" == "true" ]; then
    echo "::group::Pulling Kernel Vendor Source"
    git clone -b "$INPUT_VENDOR_BRANCH" --depth="$INPUT_DEPTH" "$INPUT_VENDOR_URL" "kernel/$INPUT_VENDOR_DIR"
    if [ -d "kernel/$INPUT_VENDOR_DIR/vendor" ]; then
        cp -rv "kernel/$INPUT_VENDOR_DIR/vendor" kernel
        cp -rv "kernel/$INPUT_VENDOR_DIR/vendor" ./
    fi
    echo "::endgroup::"
fi

pushd "kernel/$INPUT_KERNEL_DIR"

if [ -d "$HOME/gcc-64/bin" ] || [ -d "$HOME/gcc-32/bin" ]; then
    for GCC_DIR in "$HOME/gcc-64" "$HOME/gcc-32"; do
        find "$GCC_DIR"/*/*/bin -type d -exec sh -c 'mv "$(dirname "$1")"/* "$2"/' _ {} "$GCC_DIR" \; -quit >/dev/null 2>&1 || true
        if [ -d "$GCC_DIR/bin" ]; then
            for FILE in "$GCC_DIR/bin"/*; do
                [ ! -e "$FILE" ] && continue
                FILE_NAME=$(basename "$FILE")
                MATCHED_DIR=""
                while IFS= read -r FOLDER; do
                    FOLDER_NAME=$(basename "$FOLDER")
                    if [[ "$FILE_NAME" == "$FOLDER_NAME"* ]]; then
                        MATCHED_DIR="$FOLDER_NAME"
                        break
                    fi
                done < <(find "$GCC_DIR" -mindepth 1 -maxdepth 1 -type d | sort -r)
                if [ -n "$MATCHED_DIR" ]; then
                    case "$GCC_DIR" in
                        "$HOME/gcc-64") GCC64="$MATCHED_DIR" ;;
                        "$HOME/gcc-32") GCC32="$MATCHED_DIR" ;;
                    esac
                    break
                fi
            done
        fi
    done
fi

VERSION=$(grep -E '^VERSION = ' Makefile | awk '{print $3}')
PATCHLEVEL=$(grep -E '^PATCHLEVEL = ' Makefile | awk '{print $3}')
SUBLEVEL=$(grep -E '^SUBLEVEL = ' Makefile | awk '{print $3}')

NONGKI=false
if [ "$VERSION" -lt 5 ] 2>/dev/null || { [ "$VERSION" -eq 5 ] 2>/dev/null && [ "$PATCHLEVEL" -lt 10 ] 2>/dev/null; }; then
    NONGKI=true
fi

CONFIG_FILE="arch/$INPUT_ARCH/configs/$INPUT_CONFIG"

if [ "$INPUT_KHACK" == "true" ]; then
    echo "::group::Integrating Kernel Driver Hack"
    KHACK_URL="$INPUT_KHACK_URL"
    if [ -z "$KHACK_URL" ]; then
        KHACK_URL="https://github.com/AdhanKadir/Kernel_driver_hack_dev.git"
    fi
    KHACK_BRANCH="$INPUT_KHACK_BRANCH"
    KHACK_DIR="$HOME/kernel_driver_hack"
    rm -rf "$KHACK_DIR"
    git clone --depth="$INPUT_DEPTH" -b "$KHACK_BRANCH" "$KHACK_URL" "$KHACK_DIR"

    if [ ! -d "$KHACK_DIR/kernel" ]; then
        error "Kernel driver hack repository is missing the kernel directory"
    fi

    mkdir -p drivers
    rm -rf drivers/khack
    cp -r "$KHACK_DIR/kernel" drivers/khack

    if [ -d "$KHACK_DIR/configs" ]; then
        CUSTOM_DEFCONFIG_APPLIED=false
        for candidate in "$KHACK_DIR/configs/$INPUT_CONFIG" "$KHACK_DIR/configs/config"; do
            if [ -f "$candidate" ]; then
                echo "Applying custom defconfig from $candidate"
                cp "$candidate" "$CONFIG_FILE"
                CUSTOM_DEFCONFIG_APPLIED=true
                break
            fi
        done
        if [ "$CUSTOM_DEFCONFIG_APPLIED" = false ]; then
            echo "Warning: Custom defconfig not found in $KHACK_DIR/configs"
        fi
    fi

    ABI_WHITELIST_FILE="abi_symbollist.raw"
    if [ -f "$KHACK_DIR/$ABI_WHITELIST_FILE" ]; then
        if [ -f "$ABI_WHITELIST_FILE" ]; then
            echo "Existing $ABI_WHITELIST_FILE detected in kernel tree; skipping copy from khack repo"
        else
            echo "Copying $ABI_WHITELIST_FILE from khack repository"
            cp "$KHACK_DIR/$ABI_WHITELIST_FILE" "$ABI_WHITELIST_FILE"
        fi
    else
        echo "Warning: $ABI_WHITELIST_FILE not found in khack repository"
    fi

    DRIVER_MAKEFILE="drivers/Makefile"
    DRIVER_KCONFIG="drivers/Kconfig"

    if ! grep -q "khack" "$DRIVER_MAKEFILE" 2>/dev/null; then
        printf "\nobj-\$(CONFIG_KERNEL_HACK) += khack/\n" >> "$DRIVER_MAKEFILE"
    fi

    KHACK_WARNING_FLAG='subdir-ccflags-$(CONFIG_KERNEL_HACK) += -Wno-unused-variable'
    if ! grep -Fq "$KHACK_WARNING_FLAG" "$DRIVER_MAKEFILE" 2>/dev/null; then
        printf "%s\n" "$KHACK_WARNING_FLAG" >> "$DRIVER_MAKEFILE"
    fi

    if ! grep -q "drivers/khack/Kconfig" "$DRIVER_KCONFIG" 2>/dev/null; then
        printf "\nsource \"drivers/khack/Kconfig\"\n" >> "$DRIVER_KCONFIG"
    fi

    if [ -f "$CONFIG_FILE" ]; then
        if grep -q "^CONFIG_KERNEL_HACK=" "$CONFIG_FILE"; then
            sed -i "s/^CONFIG_KERNEL_HACK=.*/CONFIG_KERNEL_HACK=$INPUT_KHACK_CONFIG/" "$CONFIG_FILE"
        else
            echo "CONFIG_KERNEL_HACK=$INPUT_KHACK_CONFIG" >> "$CONFIG_FILE"
        fi
    else
        echo "Warning: CONFIG_FILE $CONFIG_FILE not found; skipping config update"
    fi

    KHACK_MEMORY_FILE="drivers/khack/memory.c"
    if [ -f "$KHACK_MEMORY_FILE" ]; then
        sed -i 's/^static struct kmem_cache \*my_vm_area_cachep/static __maybe_unused struct kmem_cache *my_vm_area_cachep/' "$KHACK_MEMORY_FILE"
        sed -i 's/^static int (\*insert_vm_struct_ptr/static __maybe_unused int (*insert_vm_struct_ptr/' "$KHACK_MEMORY_FILE"
        sed -i 's/^static bool ksyms_lookup_done/static __maybe_unused bool ksyms_lookup_done/' "$KHACK_MEMORY_FILE"
    fi

    echo "::endgroup::"
fi

if [ "$INPUT_KSU" == "true" ]; then
    echo "::group::Initializing KernelSU"
    if [ -f KernelSU/kernel/Kconfig ]; then
        echo "KernelSU has been initialized, skipping."
    else
        if [ "$INPUT_KSU_OTHER" == "true" ]; then
            if [ -z "$INPUT_KSU_URL" ]; then
                error "ksu-url input is required when ksu-other is set to true"
            fi
            curl -sSLf "$INPUT_KSU_URL/raw/$INPUT_KSU_VERSION/kernel/setup.sh" -o ksu_setup.sh || error "Failed to download KernelSU setup script from ${ksu_url}"
        else
            curl -sSLf "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" -o ksu_setup.sh || error "Failed to download KernelSU setup script from official repository"
        fi

        echo "Kernel version: $VERSION.$PATCHLEVEL.$SUBLEVEL"
        KVER="$INPUT_KSU_VERSION"
        if [ "$NONGKI" == "true" ] && [ "$INPUT_KSU_OTHER" == "false" ]; then
            echo "Warning: The KernelSU version you selected was detected to be $INPUT_KSU_VERSION, but KernelSU has dropped support for the non-gki kernel since 0.9.5."
            echo "This will force switch to v0.9.5."
            KVER=v0.9.5
        fi

        bash ksu_setup.sh "$KVER" || error "Failed to execute KernelSU setup script"
    fi

    if [ "$INPUT_KSU_LKM" == "true" ]; then
        if grep -q "CONFIG_KPROBES=y" "$CONFIG_FILE"; then
            sed -i 's/CONFIG_KSU=y/CONFIG_KSU=m/g' "$CONFIG_FILE"
        else
            sed -i '/config KSU/,/help/{s/default y/default m/}' drivers/kernelsu/Kconfig
        fi
    elif [ "$NONGKI" == "true" ]; then
        if grep -q "CONFIG_KPROBES=y" "$CONFIG_FILE" 2>/dev/null; then
            echo "CONFIG_KPROBES is enabled, skip patch."
        else
            opam init --disable-sandboxing --yes
            eval $(opam env)
            opam install --yes coccinelle
            python3 $GITHUB_ACTION_PATH/kernelsu/apply_cocci.py || echo "Warning: Failed to apply KernelSU patches"
        fi
    fi
    echo "::endgroup::"
fi

if [ "$INPUT_BBG" == "true" ]; then
    echo "::group::Initializing BBG"
    curl -Ss https://github.com/vc-teahouse/Baseband-guard/raw/main/setup.sh | bash
    sed -i '/^config LSM$/,/^help$/{ /^[[:space:]]*default/ { /baseband_guard/! s/lockdown/lockdown,baseband_guard/ } }' security/Kconfig
    echo "CONFIG_BBG=y" >> "$CONFIG_FILE"
    echo "::endgroup::"
fi

if [ "$INPUT_REKERNEL" == "true" ]; then
    echo "::group::Initializing Re-Kernel"
    python3 $GITHUB_ACTION_PATH/rekernel/patch.py || error "Failed to download or execute Re-Kernel patch script"
    echo "::endgroup::"
fi

if [ -f scripts/dtc/libfdt/mkdtboimg.py ]; then
    if grep -q python2 scripts/Makefile.lib 2>/dev/null; then
        echo "::group::Using mkdtboimg Python3 version instead of Python2 version"
        rm -f scripts/dtc/libfdt/mkdtboimg.py
        cp -v "$GITHUB_ACTION_PATH/mkdtboimg.py" scripts/dtc/libfdt/mkdtboimg.py
        echo "::endgroup::"
    elif grep -q scripts/ufdt scripts/Makefile.lib 2>/dev/null && [ ! -d scripts/ufdt ]; then
        mkdir -p ufdt/libufdt/utils/src
        cp -v "$GITHUB_ACTION_PATH/mkdtboimg.py" ufdt/libufdt/utils/src/mkdtboimg.py
    fi
    if [ ! -f /usr/bin/python2 ]; then
        SU ln -sf /usr/bin/python3 /usr/bin/python2
    fi
else
    echo "::group::Downloading mkdtboimg to /usr/local/bin"
    SU cp -v "$GITHUB_ACTION_PATH/mkdtboimg.py" /usr/local/bin/mkdtboimg
    SU chmod +x /usr/local/bin/mkdtboimg
    echo "::endgroup::"
fi

if [ "$INPUT_NETHUNTER" == "true" ]; then
    echo "::group::Initializing Kali NetHunter"
    python3 $GITHUB_ACTION_PATH/nethunter/config.py "$CONFIG_FILE" -w
    if [ "$INPUT_NETHUNTER_PATCH" == "true" ]; then
        python3 "$GITHUB_ACTION_PATH/nethunter/patch.py"
    fi
    echo "::endgroup::"
fi

if [ "$INPUT_DISABLE_LTO" == "true" ]; then
    if grep -q "LTO" "$CONFIG_FILE"; then
        sed -i 's/CONFIG_LTO=y/CONFIG_LTO=n/' "$CONFIG_FILE"
        sed -i 's/CONFIG_LTO_CLANG=y/CONFIG_LTO_CLANG=n/' "$CONFIG_FILE"
        sed -i 's/CONFIG_THINLTO=y/CONFIG_THINLTO=n/' "$CONFIG_FILE"
        echo "CONFIG_LTO_NONE=y" >> "$CONFIG_FILE"
    fi
fi

if [ "$INPUT_KVM" == "true" ]; then
    echo "CONFIG_VIRTUALIZATION=y" >> "$CONFIG_FILE"
    echo "CONFIG_KVM=y" >> "$CONFIG_FILE"
    echo "CONFIG_KVM_MMIO=y" >> "$CONFIG_FILE"
    echo "CONFIG_KVM_ARM_HOST=y" >> "$CONFIG_FILE"
fi

if [ "$INPUT_LXC" == "true" ]; then
    echo "::group::Enabling LXC"
    python3 $GITHUB_ACTION_PATH/lxc/config.py "$CONFIG_FILE" -w
    if [ "$INPUT_LXC_PATCH" == "true" ]; then
        python3 "$GITHUB_ACTION_PATH/lxc/patch_cocci.py"
    fi
    echo "::endgroup::"
fi

echo "::group:: Building Kernel with selected cross compiler"

if [[ "$INPUT_EXTRA_MAKE_ARGS" != "[]" ]]; then
    readarray -t EXTRA_ARGS < <(jq -r '.[]' <<< "$INPUT_EXTRA_MAKE_ARGS")
else
    EXTRA_ARGS=()
fi

SAFE_EXTRA_ARGS=()
for arg in "${EXTRA_ARGS[@]}"; do
    case "$arg" in
        CC=*|CXX=*|LD=*|AS=*|AR=*|NM=*|STRIP=*|OBJCOPY=*|OBJDUMP=*|\
        HOSTCC=*|KBUILD_HOSTCC=*|SHELL=*|MAKEFLAGS=*|MAKE=*|\
        CROSS_COMPILE=*|CLANG_TRIPLE=*|LLVM=*|CLVM=*|O=*|ARCH=*)
            echo "::warning::Ignoring override of critical variable: $arg"
            ;;
        *)
            SAFE_EXTRA_ARGS+=("$arg")
            ;;
    esac
done

mkdir -p -v out

if [[ -d "$HOME/clang/bin" ]]; then
    CMD_PATH="$HOME/clang/bin"
    CMD_CC="clang"
    if [[ -n "${NDK_HOME:-}" ]]; then
        CMD_CROSS_COMPILE="aarch64-linux-android-"
        CMD_CROSS_COMPILE_ARM32="arm-linux-androideabi-"
    elif [[ -d "$HOME/gcc-64/bin" ]] || [[ -d "$HOME/gcc-32/bin" ]]; then
        CMD_CROSS_COMPILE="$HOME/gcc-64/bin/${GCC64}-"
        CMD_CROSS_COMPILE_ARM32="$HOME/gcc-32/bin/${GCC32}-"
    fi
elif [[ -d "$HOME/gcc-64/bin" ]] || [[ -d "$HOME/gcc-32/bin" ]]; then
    CMD_PATH="$HOME/gcc-64/bin:$HOME/gcc-32/bin"
    if [[ -n "${GCC64:-}" ]]; then
        CMD_CC="$HOME/gcc-64/bin/${GCC64}-gcc"
        CMD_CROSS_COMPILE="${GCC64}-"
    else
        CMD_CC="$HOME/gcc-32/bin/${GCC32}-gcc"
        CMD_CROSS_COMPILE="${GCC32}-"
    fi
    CMD_CROSS_COMPILE_ARM32="${GCC32}-"
else
    CMD_CC="/usr/bin/clang"
    CMD_CROSS_COMPILE="/usr/bin/aarch64-linux-gnu-"
    CMD_CROSS_COMPILE_ARM32="arm-linux-gnueabihf-"
fi

if [[ "$INPUT_CCACHE" == "true" ]]; then
    export USE_CCACHE=1
    export PATH="/usr/lib/ccache:/usr/local/opt/ccache/libexec:$PATH"
    CMD_PATH="/usr/lib/ccache:$CMD_PATH"
fi

make_args=(
    -j"$(nproc --all)"
    "$INPUT_CONFIG"
    "ARCH=$INPUT_ARCH"
    "O=out"
    all
    "${SAFE_EXTRA_ARGS[@]}"
)

if [[ "$INPUT_ARCH" == "arm" ]]; then
    CMD_CLANG_TRIPLE="${CMD_CROSS_COMPILE_ARM32}"
else
    if [[ -n "${NDK_HOME:-}" ]]; then
        CMD_CLANG_TRIPLE="aarch64-linux-android-"
    else
        CMD_CLANG_TRIPLE="aarch64-linux-gnu-"
    fi
fi

export PATH="$CMD_PATH:$PATH"
make \
    CC="$CMD_CC" \
    CROSS_COMPILE="$CMD_CROSS_COMPILE" \
    CROSS_COMPILE_ARM32="$CMD_CROSS_COMPILE_ARM32" \
    CLANG_TRIPLE="$CMD_CLANG_TRIPLE" \
    KBUILD_DTB_WERROR=0 \
   "${make_args[@]}" | tee -a out/build.log

echo "::endgroup::"

if [ "$INPUT_ANYKERNEL3" == "false" ]; then
    echo "::group::Packaging boot.img"

    if [ -z "$INPUT_BOOTIMG_URL" ]; then
        error "bootimg-url input is required when anykernel3 is set to false"
    fi

    mkdir split
    pushd split
    # Detect architecture (works on both Debian and Arch)
    if [ -f /bin/dpkg ]; then
        HOST_ARCH=$(dpkg --print-architecture)
    else
        HOST_ARCH=$(uname -m)
    fi
    case "${HOST_ARCH}" in
        armv7*|armv8l|arm64|aarch64|armhf|arm) aria2c https://github.com/Shubhamvis98/AIK/raw/4ac321dfd48e16344e6146c505708aa720ff0bb3/bin/magiskboot_arm -o magiskboot && chmod +x magiskboot ;;
        i*86|x86|amd64|x86_64) aria2c https://github.com/Shubhamvis98/AIK/raw/4ac321dfd48e16344e6146c505708aa720ff0bb3/bin/magiskboot_x86 -o magiskboot && chmod +x magiskboot ;;
        *) error "Unknown CPU architecture for this device!" ;;
    esac
    aria2c "$INPUT_BOOTIMG_URL" -o boot.img || error "Failed to download boot.img"
    ./magiskboot unpack boot.img > nohup.out 2>&1 # nohup is not working in github ci!
    export FMT=$(cat nohup.out | grep "KERNEL_FMT" | awk '{gsub("\\[", "", $2); gsub("\\]", "", $2); print $2}')
    rm -rf kernel

    find_kernel_image() {
        local pattern=$1
        local description=$2
        mapfile -t images < <(find ../out/arch/$INPUT_ARCH/boot -name "$pattern" ! -name "*-*" 2>/dev/null)

        if [ ${#images[@]} -eq 0 ]; then
            error "Failed to find $description"
        elif [ ${#images[@]} -gt 1 ]; then
            error "Multiple $description found: ${images[*]}"
        fi

        cp -v "${images[0]}" kernel
    }

    if [ "$FMT" == "raw" ]; then
        find_kernel_image "Image" "raw kernel Image"
    else
        if [ -f dtb ]; then
            find_kernel_image "Image.*-dtb" "kernel Image with dtb"
        else
            find_kernel_image "Image.*" "compressed kernel Image"
        fi
    fi
    ./magiskboot repack boot.img
    rm -f boot.img
    mkdir -p ../../../build
    find . -name "*.img" -exec mv -v {} ../../../build/boot.img \;
    pushd ..
    echo "::endgroup::"
else
    echo "::group:: Packaging Anykernel3 flasher"
    if [ -n "$INPUT_ANYKERNEL3_URL" ]; then
        git clone "$INPUT_ANYKERNEL3_URL" AnyKernel3
    else
        git clone https://github.com/osm0sis/AnyKernel3
        sed -i 's!BLOCK=/dev/block/platform/omap/omap_hsmmc.0/by-name/boot;!BLOCK=auto;!g' AnyKernel3/anykernel.sh
        sed -i 's/do.devicecheck=1/do.devicecheck=0/g' AnyKernel3/anykernel.sh
        sed -i 's/IS_SLOT_DEVICE=0;/IS_SLOT_DEVICE=auto;/g' AnyKernel3/anykernel.sh
    fi

    copy_kernel_image() {
        local pattern=$1
        local description=$2
        mapfile -t images < <(find out/arch/$INPUT_ARCH/boot -name "$pattern" ! -name "*-*" 2>/dev/null)

        if [ ${#images[@]} -eq 0 ]; then
            return 1
        elif [ ${#images[@]} -gt 1 ]; then
            error "Multiple $description found: ${images[*]}"
        fi

        cp -rv "${images[0]}" AnyKernel3/
        return 0
    }

    if ! copy_kernel_image "Image.*-dtb" "kernel Image with dtb"; then
        if ! copy_kernel_image "Image.*" "compressed kernel Image"; then
            if [ ! -f out/arch/$INPUT_ARCH/boot/Image ]; then
                error "Kernel Image not found in out/arch/$INPUT_ARCH/boot/"
            fi
            cp out/arch/$INPUT_ARCH/boot/Image AnyKernel3/ -rv
        fi
    fi

    if [ -f out/arch/$INPUT_ARCH/boot/dtbo.img ]; then
        cp out/arch/$INPUT_ARCH/boot/dtbo.img AnyKernel3/ -rv
    else
        echo "Failed to copy DTBO image. File not found."
    fi

    if [ -f out/arch/$INPUT_ARCH/boot/dtb.img ]; then
        cp out/arch/$INPUT_ARCH/boot/dtb.img AnyKernel3/ -rv
    elif [ -f out/arch/$INPUT_ARCH/boot/dtb ]; then
        cp out/arch/$INPUT_ARCH/boot/dtb AnyKernel3/ -rv
    else
        echo "Failed to copy dtb. File not found."
    fi

    rm -rf -v AnyKernel3/.git* AnyKernel3/README.md
    mkdir -p -v ../../build
    if [ "$INPUT_RELEASE" = "false" ]; then
        cp -r -v AnyKernel3/* ../../build
    else
        pushd AnyKernel3 && zip -r Anykernel3-flasher.zip ./* && mv -v Anykernel3-flasher.zip .. && pushd .. && mv -v Anykernel3-flasher.zip ../../build/
    fi
    echo "::endgroup::"
fi

echo "::group:: Cleaning up"
python3 $GITHUB_ACTION_PATH/clean.py
eval "$(python3 $GITHUB_ACTION_PATH/clean.py --env)"
echo "::endgroup::"
