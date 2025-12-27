Вариант 1: Клонировать весь репозиторий
git clone https://github.com/miviolinuxsecdeveloper/Mivio-Script-install-FIX.git
cd Mivio-Script-install-FIX
chmod +x install.sh
sudo ./install.sh

Вариант 2: Скачать только скрипт (без git)
curl -L -o install.sh https://raw.githubusercontent.com/miviolinuxsecdeveloper/Mivio-Script-install-FIX/install.sh
# или
wget https://raw.githubusercontent.com/miviolinuxsecdeveloper/Mivio-Script-install-FIX/install.sh
chmod +x install.sh
sudo ./install.sh

Вариант 3: Запустить напрямую
bash <(curl -s https://raw.githubusercontent.com/miviolinuxsecdeveloper/Mivio-Script-install-FIX/main/install.sh)
# или
curl -s https://raw.githubusercontent.com/miviolinuxsecdeveloper/Mivio-Script-install-FIX/main/install.sh | sudo bash
