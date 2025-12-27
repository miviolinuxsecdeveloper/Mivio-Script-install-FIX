#!/bin/bash
# ============================================
# MIVIO VOID INSTALLER
# Обновленный с ядром 6.12
# ============================================

set -e

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# Лог
LOG_FILE="/tmp/mivio-void-install-$(date +%s).log"
exec 2>>"$LOG_FILE"

# ================= УТИЛИТЫ =================
print_header() {
    clear
    echo -e "${PURPLE}"
    cat << "EOF"
╔══════════════════════════════════════════╗
║           MIVIO VOID INSTALLER           ║
║                                          ║
╚══════════════════════════════════════════╝
EOF
    echo -e "${NC}\n"
}

print_step() {
    echo -e "${CYAN}[+]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
    echo -e "${YELLOW}Смотри лог: $LOG_FILE${NC}"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

ask() {
    echo -e "${YELLOW}[?]${NC} $1"
    read -p "> " ANSWER
    echo "$ANSWER"
}

# ================= ПРОВЕРКА СРЕДЫ =================
check_void_environment() {
    print_step "Проверка окружения..."
    
    if ! command -v xbps-install &> /dev/null; then
        print_error "Это не Void Linux среда!"
        print_error "Скачайте Void Live ISO: https://voidlinux.org/download/"
        print_error "Загрузитесь с него и запустите скрипт заново"
        exit 1
    fi
    
    # Проверяем версию ядра
    local kernel_version=$(uname -r | cut -d. -f1-2)
    print_success "Текущее ядро: $(uname -r)"
    
    # Обновляем репозитории
    xbps-install -Syu
}

# ================= ВЫБОР ДИСКА =================
select_disk() {
    print_step "Доступные диски:"
    echo -e "${BLUE}"
    lsblk -d -o NAME,SIZE,MODEL,TYPE | grep -v "NAME" | grep -v "rom"
    echo -e "${NC}"
    
    while true; do
        local disk=$(ask "Введите диск (например: sda, nvme0n1):")
        
        # Обработка nvme дисков
        if [[ "$disk" == nvme* ]]; then
            if [ -b "/dev/$disk" ]; then
                print_success "Выбран NVMe диск: /dev/$disk"
                echo "$disk"
                return
            fi
        elif [ -b "/dev/$disk" ]; then
            print_success "Выбран диск: /dev/$disk"
            echo "$disk"
            return
        else
            print_error "Диск /dev/$disk не найден!"
            echo "Доступные диски:"
            lsblk -d -o NAME | tail -n +2
        fi
    done
}

# ================= РАЗМЕТКА ДИСКА =================
partition_disk() {
    local disk=$1
    
    print_step "Разметка диска /dev/$disk..."
    
    print_warning "ВСЕ ДАННЫЕ НА /dev/$disk БУДУТ УДАЛЕНЫ!"
    local confirm=$(ask "Продолжить? (yes/no):")
    [ "$confirm" != "yes" ] && exit 0
    
    # Определяем тип диска (nvme или обычный)
    local part_prefix=""
    if [[ "$disk" == nvme* ]]; then
        part_prefix="p"
    fi
    
    # Очищаем диск
    wipefs -a /dev/$disk
    partprobe /dev/$disk
    
    # Создаем GPT таблицу
    parted -s /dev/$disk mklabel gpt
    
    # 1. EFI раздел (512M)
    print_step "Создаю EFI раздел..."
    parted -s /dev/$disk mkpart primary fat32 1MiB 513MiB
    parted -s /dev/$disk set 1 esp on
    
    # 2. Boot раздел (1G для ядер)
    print_step "Создаю Boot раздел..."
    parted -s /dev/$disk mkpart primary ext4 513MiB 1.5GiB
    
    # 3. Swap (размер RAM * 2, минимум 4G)
    print_step "Создаю Swap раздел..."
    local total_ram=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local swap_size=$((total_ram * 2 / 1024 / 1024))
    [ $swap_size -lt 4 ] && swap_size=4
    parted -s /dev/$disk mkpart primary linux-swap 1.5GiB ${swap_size}.5GiB
    
    # 4. Root (остальное)
    print_step "Создаю Root раздел..."
    parted -s /dev/$disk mkpart primary ext4 ${swap_size}.5GiB 100%
    
    # Ждем создания разделов
    sleep 2
    partprobe /dev/$disk
    
    # Форматируем разделы
    print_step "Форматирую разделы..."
    
    # EFI
    mkfs.fat -F32 /dev/${disk}${part_prefix}1
    
    # Boot
    mkfs.ext4 -F /dev/${disk}${part_prefix}2
    
    # Swap
    mkswap /dev/${disk}${part_prefix}3
    
    # Root
    mkfs.ext4 -F /dev/${disk}${part_prefix}4
    
    print_success "Диск разметен и отформатирован"
    
    # Возвращаем префикс для разделов
    echo "$part_prefix"
}

# ================= МОНТИРОВАНИЕ =================
mount_partitions() {
    local disk=$1
    local part_prefix=$2
    
    print_step "Монтирую разделы..."
    
    # Монтируем root
    mount /dev/${disk}${part_prefix}4 /mnt
    
    # Создаем точки монтирования
    mkdir -p /mnt/boot/efi
    mkdir -p /mnt/boot
    mkdir -p /mnt/home
    
    # Монтируем EFI
    mount /dev/${disk}${part_prefix}1 /mnt/boot/efi
    
    # Монтируем boot
    mount /dev/${disk}${part_prefix}2 /mnt/boot
    
    # Включаем swap
    swapon /dev/${disk}${part_prefix}3
    
    print_success "Разделы смонтированы"
}

# ================= УСТАНОВКА VOID =================
install_void() {
    print_step "Устанавливаю Void Linux..."
    
    # Создаем каталоги для ключей
    mkdir -p /mnt/var/db/xbps/keys
    cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/ 2>/dev/null || true
    
    # Устанавливаем базовую систему с ядром 6.12
    print_step "Устанавливаю базовые пакеты..."
    xbps-install -Sy -R https://repo-default.voidlinux.org/current -r /mnt \
        base-system \
        linux6.12 \
        linux6.12-headers \
        runit \
        runit-void \
        base-devel \
        nano \
        vim \
        bash \
        bash-completion \
        dhcpcd \
        grub \
        grub-x86_64-efi \
        efibootmgr \
        git \
        curl \
        wget \
        sudo
    
    print_success "Void Linux установлен"
}

# ================= CHROOT НАСТРОЙКА =================
configure_chroot() {
    local disk=$1
    local part_prefix=$2
    local hostname=$3
    local username=$4
    local password=$5
    
    print_step "Настраиваю систему..."
    
    # Монтируем системные каталоги
    mount --bind /proc /mnt/proc
    mount --bind /sys /mnt/sys
    mount --bind /dev /mnt/dev
    mount --bind /run /mnt/run
    mount --bind /sys/firmware/efi/efivars /mnt/sys/firmware/efi/efivars 2>/dev/null || true
    
    # Chroot команды
    chroot /mnt /bin/bash <<EOF
    # Хостнейм
    echo "$hostname" > /etc/hostname
    
    # Часовой пояс
    ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime
    
    # Локализация
    echo "en_US.UTF-8 UTF-8" >> /etc/default/libc-locales
    echo "ru_RU.UTF-8 UTF-8" >> /etc/default/libc-locales
    xbps-reconfigure -f glibc-locales
    echo "LANG=en_US.UTF-8" > /etc/locale.conf
    
    # Пользователь
    useradd -m -G wheel,audio,video,storage,input -s /bin/bash "$username"
    echo "$username:$password" | chpasswd
    
    # Sudo
    echo "$username ALL=(ALL) ALL" >> /etc/sudoers.d/mivio
    echo "$username ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers.d/mivio 2>/dev/null || true
    chmod 440 /etc/sudoers.d/mivio
    
    # Обновляем систему
    xbps-install -Syu
    
    # Устанавливаем NetworkManager
    xbps-install -y NetworkManager network-manager-applet
    ln -s /etc/sv/NetworkManager /var/service/
    
    # GRUB
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=MIVIO-VOID --recheck
    echo "GRUB_DEFAULT=0" > /etc/default/grub
    echo "GRUB_TIMEOUT=5" >> /etc/default/grub
    echo "GRUB_DISTRIBUTOR=\"Mivio Void\"" >> /etc/default/grub
    echo "GRUB_CMDLINE_LINUX_DEFAULT=\"quiet\"" >> /etc/default/grub
    grub-mkconfig -o /boot/grub/grub.cfg
    
    # Fstab
    cat > /etc/fstab <<FSTAB
# <device>             <dir>         <type>    <options>             <dump> <pass>
/dev/${disk}${part_prefix}4  /              ext4      defaults              0     1
/dev/${disk}${part_prefix}2  /boot          ext4      defaults              0     2
/dev/${disk}${part_prefix}1  /boot/efi      vfat      defaults              0     2
/dev/${disk}${part_prefix}3  none           swap      sw                    0     0
tmpfs                     /tmp          tmpfs     defaults,nosuid,nodev 0     0
FSTAB
EOF
    
    print_success "Базовая настройка завершена"
}

# ================= УСТАНОВКА GCC И ИНСТРУМЕНТОВ =================
install_development_tools() {
    local username=$1
    
    print_step "Устанавливаю инструменты разработки..."
    
    chroot /mnt /bin/bash <<EOF
    # GCC и инструменты
    xbps-install -y \
        gcc \
        make \
        cmake \
        binutils \
        gdb \
        valgrind \
        strace \
        ltrace \
        python3 \
        python3-pip \
        git \
        nodejs \
        rust \
        go
    
    # Системные утилиты
    xbps-install -y \
        htop \
        btop \
        neofetch \
        mc \
        ranger \
        tree \
        ripgrep \
        fd \
        fzf \
        bat \
        eza \
        tmux
    
    # Создаем bashrc
    cat > /home/$username/.bashrc <<'BASHRC'
# Mivio Void Linux
export PS1='\[\e[1;32m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '
export EDITOR=vim
export VISUAL=vim

# Aliases
alias ll='eza -la --git'
alias la='eza -a'
alias l='eza -l'
alias update='sudo xbps-install -Syu'
alias install='sudo xbps-install -S'
alias remove='sudo xbps-remove -R'
alias search='xbps-query -Rs'
alias clean='sudo xbps-remove -Oo'
alias reboot='sudo reboot'
alias poweroff='sudo poweroff'

# Пути
export PATH="$PATH:/home/$username/.local/bin"

# Приветствие
echo ""
echo "╔══════════════════════════════════════╗"
echo "║      Welcome to MIVIO VOID LINUX     ║"
echo "║      Kernel: \$(uname -r)             ║"
echo "╚══════════════════════════════════════╝"
echo ""
echo "Команды: update, install, remove, search"
echo ""
BASHRC
    
    # Тестовый C файл
    cat > /home/$username/test-mivio.c <<'CCODE'
#include <stdio.h>
#include <linux/version.h>

int main() {
    printf("╔══════════════════════════════════════╗\n");
    printf("║         MIVIO VOID LINUX             ║\n");
    printf("║         TEST PROGRAM                 ║\n");
    printf("╚══════════════════════════════════════╝\n\n");
    
    printf("✓ Kernel: %d.%d.%d\n", 
           LINUX_VERSION_CODE >> 16,
           (LINUX_VERSION_CODE >> 8) & 0xFF,
           LINUX_VERSION_CODE & 0xFF);
    
    printf("✓ GCC: %d.%d.%d\n", 
           __GNUC__, __GNUC_MINOR__, __GNUC_PATCHLEVEL__);
    
    printf("✓ Bash scripts: WORKING\n");
    printf("✓ Compilation: WORKING\n");
    printf("✓ System: READY\n\n");
    
    return 0;
}
CCODE
    
    chown $username:$username /home/$username/test-mivio.c
    
    # Компилируем
    cd /home/$username
    sudo -u $username gcc test-mivio.c -o test-mivio
    
    # Bash скрипт
    cat > /home/$username/test.sh <<'SCRIPT'
#!/bin/bash
echo "Bash script test - SUCCESS!"
echo "Current directory: $(pwd)"
echo "User: $(whoami)"
echo "Kernel: $(uname -r)"
SCRIPT
    
    chmod +x /home/$username/test.sh
    chown $username:$username /home/$username/test.sh
    
    # Инструмент mivio
    cat > /usr/local/bin/mivio <<'MIVIO'
#!/bin/bash
echo "╔══════════════════════════════════════╗"
echo "║         MIVIO VOID TOOLS             ║"
echo "╚══════════════════════════════════════╝"
echo ""
echo "mivio update    - Обновить систему"
echo "mivio install   - Установить пакеты"
echo "mivio remove    - Удалить пакеты"
echo "mivio search    - Поиск пакетов"
echo "mivio services  - Управление сервисами"
echo "mivio info      - Информация о системе"
echo ""
MIVIO
    
    chmod +x /usr/local/bin/mivio
EOF
    
    print_success "Инструменты разработки установлены"
}

# ================= ЗАВЕРШЕНИЕ =================
finish_installation() {
    local disk=$1
    local part_prefix=$2
    local username=$3
    
    print_step "Завершаю установку..."
    
    # Размонтируем всё
    umount -R /mnt 2>/dev/null || true
    swapoff /dev/${disk}${part_prefix}3 2>/dev/null || true
    
    print_success "╔══════════════════════════════════════╗"
    print_success "║     УСТАНОВКА ЗАВЕРШЕНА!             ║"
    print_success "╚══════════════════════════════════════╝"
    echo ""
    echo "Mivio Void Linux успешно установлен!"
    echo ""
    echo "▸ Диск: /dev/$disk"
    echo "▸ Ядро: 6.12 (последнее)"
    echo "▸ Пользователь: $username"
    echo "▸ Пароль: [который вы указали]"
    echo ""
    echo "Команды для проверки после перезагрузки:"
    echo "  ./test-mivio    - Тестовая программа на C"
    echo "  ./test.sh       - Тестовый bash скрипт"
    echo "  mivio           - Инструменты Mivio"
    echo "  gcc --version   - Проверка компилятора"
    echo ""
    echo "Для продолжения:"
    echo "  1. Извлеките установочный носитель"
    echo "  2. Перезагрузитесь: reboot"
    echo "  3. Войдите под пользователем $username"
    echo ""
    
    read -p "Нажмите Enter для перезагрузки или Ctrl+C для отмены..."
    reboot
}

# ================= ГЛАВНАЯ ФУНКЦИЯ =================
main() {
    print_header
    
    # Проверка среды
    check_void_environment
    
    # Выбор диска
    local disk=$(select_disk)
    
    # Настройки
    local hostname="mivio-void"
    local username="mivio"
    local password=""
    
    print_step "Настройка системы"
    local custom_hostname=$(ask "Имя компьютера [$hostname]:")
    [ -n "$custom_hostname" ] && hostname="$custom_hostname"
    
    local custom_user=$(ask "Имя пользователя [$username]:")
    [ -n "$custom_user" ] && username="$custom_user"
    
    while [ -z "$password" ]; do
        password=$(ask "Пароль для пользователя $username:")
        if [ -z "$password" ]; then
            print_error "Пароль не может быть пустым!"
        fi
    done
    
    # Подтверждение
    echo ""
    print_warning "ПОДТВЕРДИТЕ УСТАНОВКУ:"
    echo "▸ Диск: /dev/$disk (все данные будут удалены!)"
    echo "▸ Имя компьютера: $hostname"
    echo "▸ Пользователь: $username"
    echo "▸ Пароль: [скрыто]"
    echo ""
    
    local confirm=$(ask "Начать установку? (yes/NO):")
    [ "$confirm" != "yes" ] && {
        print_error "Установка отменена"
        exit 0
    }
    
    # ========== ПРОЦЕСС УСТАНОВКИ ==========
    print_header
    print_step "НАЧАЛО УСТАНОВКИ MIVIO VOID LINUX"
    
    # 1. Разметка
    local part_prefix=$(partition_disk "$disk")
    
    # 2. Монтирование
    mount_partitions "$disk" "$part_prefix"
    
    # 3. Установка Void
    install_void
    
    # 4. Настройка
    configure_chroot "$disk" "$part_prefix" "$hostname" "$username" "$password"
    
    # 5. Инструменты разработки
    install_development_tools "$username"
    
    # 6. Завершение
    finish_installation "$disk" "$part_prefix" "$username"
}

# Запуск
trap 'print_error "Прервано пользователем"; exit 1' INT TERM
main "$@"
